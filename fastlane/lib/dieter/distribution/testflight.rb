# frozen_string_literal: true

require "spaceship"
require_relative "coordinator"
require_relative "apple"

module Dieter
  class TestFlightDestination
    def initialize(
      context,
      identity,
      actions:,
      store: nil,
      github: nil,
      coordinator: nil,
      app_model: nil,
      build_model: nil,
      token_factory: nil
    )
      @context, @identity, @actions = context, identity, actions
      @github = github || GitHubDestination.new(context)
      @store = store || Spaceship::ConnectAPI
      @coordinator = coordinator || ReleaseCoordinator.new(context, identity)
      @app_model = app_model || Spaceship::ConnectAPI::App
      @build_model = build_model || Spaceship::ConnectAPI::Build
      @token_factory =
        token_factory || ->(**options) { Spaceship::ConnectAPI::Token.create(**options) }
    end

    def deliver
      @github.with_claim(@identity, "testflight") { reconcile }
    end

    def verify_live_delivery!(ipa_hash)
      manifest, = @coordinator.verify_retained
      verify_account!(manifest.fetch("policy"))
      signer = AppleSigning.new(@context)
      key = Base64.strict_decode64(signer.secret("IOS_APP_STORE_CONNECT_KEY_BASE64"))
      @context.secrets << key
      @store.token =
        @token_factory.call(
          key_id: signer.secret("IOS_APP_STORE_CONNECT_KEY_ID"),
          issuer_id: signer.secret("IOS_APP_STORE_CONNECT_ISSUER_ID"),
          key: key
        )
      app = @app_model.find(signer.secret("IOS_BUNDLE_ID"), client: @store)
      raise Unavailable, "App Store Connect app is unavailable" unless app
      receipts =
        @github
          .receipts(@identity, "testflight")
          .select { |receipt| receipt["state"] == "completed" && receipt["ipa_sha256"] == ipa_hash }
      builds = find_build(app.id)
      unless builds.length == 1 && builds.first.processing_state == "VALID" &&
               !builds.first.expired && internally_testable?(builds.first) &&
               receipts.any? { |receipt| receipt["build_id"] == builds.first.id }
        raise Unavailable, "Exact TestFlight build must still be valid, unexpired and ready"
      end
      receipt = receipts.last
      names = receipt.fetch("groups")
      groups = app.get_beta_groups(client: @store).select { |group| names.include?(group.name) }
      unless !names.empty? && groups.map(&:name).sort == names.sort &&
               groups.all? { |group|
                 group.is_internal_group &&
                   group.fetch_builds.any? { |build| build.id == builds.first.id }
               }
        raise Unavailable, "Retained internal TestFlight delivery is no longer complete"
      end
      builds.first
    end

    def reconcile
      manifest, sums = @coordinator.verify_retained
      release = @github.release(@identity.tag)
      raise PipelineError, "Distribution requires a published release" if release["draft"]
      channel = release["prerelease"] ? "dev" : "stable"
      policy = manifest.fetch("policy").fetch("channels").fetch(channel)
      return unless policy.fetch("testflight")
      groups = policy.fetch("testflight_groups")
      verify_account!(manifest.fetch("policy"))
      signer = AppleSigning.new(@context)
      key = Base64.strict_decode64(signer.secret("IOS_APP_STORE_CONNECT_KEY_BASE64"))
      @context.secrets << key
      key_id, issuer =
        signer.secret("IOS_APP_STORE_CONNECT_KEY_ID"),
        signer.secret("IOS_APP_STORE_CONNECT_ISSUER_ID")
      @store.token = @token_factory.call(key_id: key_id, issuer_id: issuer, key: key)
      app = @app_model.find(signer.secret("IOS_BUNDLE_ID"), client: @store)
      raise Unavailable, "App Store Connect app is unavailable" unless app
      all_groups = app.get_beta_groups(client: @store)
      # An unconfigured personal account is unambiguous only when it has one
      # existing internal group. Multiple groups require tracked selection.
      groups = all_groups.select(&:is_internal_group).map(&:name) if groups.empty? &&
        all_groups.count(&:is_internal_group) == 1
      if groups.empty?
        raise Unavailable,
              "Select internal TestFlight groups in tracked release policy; no unique internal group exists"
      end
      remote_groups = all_groups.select { |group| groups.include?(group.name) }
      unless remote_groups.map(&:name).sort == groups.sort &&
               remote_groups.all?(&:is_internal_group)
        raise Unavailable, "TestFlight groups must resolve uniquely and all be internal"
      end
      previous = @github.receipts(@identity, "testflight")
      completed = previous.find { |value| value["state"] == "completed" }
      builds = find_build(app.id)
      raise PipelineError, "Duplicate exact App Store Connect build identity" if builds.length > 1
      build = builds.first
      if build &&
           previous.none? { |value|
             %w[uploading accepted processing group-delivered completed].include?(value["state"])
           }
        raise PipelineError,
              "Existing App Store build has no receipt binding it to this candidate; preserve identity and investigate"
      end
      previous.each do |value|
        next unless value["ipa_sha256"]
        unless value["ipa_sha256"] == sums.fetch("Dieter-iOS.ipa")
          raise PipelineError, "TestFlight receipt binds different IPA bytes"
        end
      end
      if completed
        unless build && completed["build_id"] == build.id
          raise PipelineError, "Previously delivered build disappeared or changed"
        end
      end
      unless build
        # A prior accepted upload may take time to appear in ASC. Never blindly
        # upload again after an uncertain/accepted boundary.
        accepted =
          previous.any? { |value| %w[uploading accepted processing].include?(value["state"]) }
        if accepted
          build = await_build(app.id, seconds: 1800)
          unless build
            raise Unavailable,
                  "Prior upload remains unconfirmed; inspect ASC and resume this release, preserving its identity"
          end
        else
          path =
            @github.download(
              @identity,
              "Dieter-iOS.ipa",
              File.join(@context.output, "Dieter-iOS.ipa")
            )
          unless ArtifactSet.sha256(path) == sums.fetch("Dieter-iOS.ipa")
            raise PipelineError, "Retained IPA hash mismatch"
          end
          @context.command(
            [
              "python3",
              "-c",
              "from pathlib import Path; import sys; from fastlane.lib.dieter.native.ios_metadata import validate_ipa; validate_ipa(Path(sys.argv[1]),sys.argv[2],sys.argv[3],sys.argv[4])",
              @context.output,
              @identity.version,
              @identity.apple_build,
              app.bundle_id
            ],
            timeout: 120
          )
          @github.receipt(
            @identity,
            "testflight",
            { "state" => "uploading", "ipa_sha256" => sums.fetch("Dieter-iOS.ipa") }
          )
          @actions.upload_to_testflight(
            api_key: {
              key_id: key_id,
              issuer_id: issuer,
              key: key,
              in_house: false
            },
            ipa: path,
            app_identifier: app.bundle_id,
            skip_submission: true,
            skip_waiting_for_build_processing: true,
            distribute_external: false
          )
          @github.receipt(
            @identity,
            "testflight",
            { "state" => "accepted", "ipa_sha256" => sums.fetch("Dieter-iOS.ipa") }
          )
          build = await_build(app.id, seconds: 1800)
          unless build
            raise Unavailable, "Accepted upload has not appeared; resume distribution by release ID"
          end
        end
      end
      @github.receipt(
        @identity,
        "testflight",
        {
          "state" => "processing",
          "build_id" => build.id,
          "processing_state" => build.processing_state
        }
      )
      deadline = monotonic + 1800
      while build.processing_state == "PROCESSING"
        if monotonic >= deadline
          raise Unavailable, "TestFlight processing is pending; resume retained release"
        end
        puts "TestFlight #{@identity.version} (#{@identity.apple_build}) processing; checking in 30s"
        sleep 30
        build = find_build(app.id).first || raise(PipelineError, "Processing build disappeared")
      end
      unless build.processing_state == "VALID" && !build.expired && internally_testable?(build)
        raise PipelineError, "App Store Connect rejected the build: #{build.processing_state}"
      end
      remote_groups.each do |group|
        existing = group.fetch_builds.map(&:id)
        unless existing.include?(build.id)
          build.add_beta_groups(client: @store, beta_groups: [group])
        end
        unless group.fetch_builds.any? { |item| item.id == build.id }
          raise PipelineError, "TestFlight group delivery was not confirmed: #{group.name}"
        end
        @github.receipt(
          @identity,
          "testflight",
          {
            "state" => "group-delivered",
            "build_id" => build.id,
            "group" => group.name,
            "group_id" => group.id
          }
        )
      end
      @github.receipt(
        @identity,
        "testflight",
        {
          "state" => "completed",
          "build_id" => build.id,
          "groups" => groups,
          "ipa_sha256" => sums.fetch("Dieter-iOS.ipa")
        }
      )
    end

    private

    def verify_account!(policy)
      expected = @context.config.policy.fetch("ios")
      unless policy["ios"] == expected && ENV["IOS_BUNDLE_ID"] == expected.fetch("bundle_id")
        raise PipelineError,
              "TestFlight credentials and retained candidate must match the tracked iOS release account"
      end
    end

    def internally_testable?(build)
      # Fastlane's readiness helper covers admission only. Once a group has the
      # build, ASC moves it to IN_BETA_TESTING; it remains valid for delivery
      # reconciliation and stable promotion. Keep every other state rejected.
      build.ready_for_internal_testing? ||
        build.build_beta_detail&.internal_build_state ==
          Spaceship::ConnectAPI::BuildBetaDetail::InternalState::IN_BETA_TESTING
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def find_build(app_id) =
      @build_model.all(
        client: @store,
        app_id: app_id,
        version: @identity.version,
        build_number: @identity.apple_build,
        platform: "IOS",
        limit: 100
      )
    def await_build(app_id, seconds:)
      deadline = monotonic + seconds
      loop do
        builds = find_build(app_id)
        raise PipelineError, "Duplicate App Store build" if builds.length > 1
        return builds.first unless builds.empty?
        return nil if monotonic >= deadline
        puts "Waiting for accepted exact IPA to appear in App Store Connect"
        sleep 30
      end
    end
  end
end
