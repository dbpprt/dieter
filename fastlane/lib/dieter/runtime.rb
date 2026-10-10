# frozen_string_literal: true

require_relative "config"
require_relative "pipeline/context"
require_relative "pipeline/engine"
require_relative "platforms/android"
require_relative "platforms/mac"
require_relative "platforms/ios"
require_relative "platforms/core"
require_relative "fixtures/screen"
require_relative "pipeline/source"
require_relative "platforms/server"
require_relative "pipeline/candidate"
require_relative "distribution/coordinator"
require_relative "distribution/testflight"
require_relative "distribution/retention"

module Dieter
  module Runtime
    def self.native_ci(options, actions: nil)
      unless ENV["GITHUB_ACTIONS"] == "true"
        raise PipelineError, "Native CI composition requires Actions"
      end
      values = options.transform_keys(&:to_s)
      unless (values.keys - %w[component cases suite profile profiles]).empty?
        raise PipelineError, "Unknown native CI options"
      end
      component = values.delete("component")
      unless %w[mac ios android].include?(component)
        raise PipelineError, "Invalid native CI component"
      end
      values.reject! { |_key, value| value == "" }
      if values["suite"] && !%w[smoke functional].include?(values["suite"])
        raise PipelineError, "Invalid native CI suite"
      end
      return ios_qualify(values, actions: actions) if component == "ios" && values["profiles"]
      invoke("e2e", component, values, actions: actions)
    end

    ROOT = File.expand_path("../../..", __dir__)

    def self.invoke(operation, component, options, actions: nil, parent: nil)
      request = PipelineRequest.new(operation, component, options)
      config = Config.new(ROOT)
      context = RunContext.new(config, output: request.options["output"], parent: parent)
      begin
        context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
        if %w[daemon gateway].include?(component)
          adapter = Server.new(context, component: component, actions: actions)
        else
          klass = { "android" => Android, "mac" => Mac, "ios" => IOS, "core" => Core }.fetch(
            component
          )
          adapter = component == "core" ? klass.new(context) : klass.new(context, actions: actions)
        end
      rescue Exception
        context.close
        raise
      end
      puts "Pipeline evidence: #{context.output}"
      Pipeline.new(context, request, adapter).run
    end

    def self.ios_qualify(options, actions: nil, parent: nil, prepared: nil)
      values = options.transform_keys(&:to_s).reject { |_key, value| value == "" }
      unless (values.keys - %w[profiles suite cases changed base output]).empty?
        raise PipelineError, "Unknown iOS qualification options"
      end
      profiles = values.fetch("profiles", "ios-iphone,ios-ipad").split(",")
      if profiles.empty? || profiles.uniq != profiles
        raise PipelineError, "Select one or more unique simulator profiles"
      end
      group = RunContext.new(Config.new(ROOT), output: values.delete("output"), parent: parent)
      puts "iOS qualification evidence: #{group.output}"
      begin
        group.environment["DIETER_RELEASE_VERSION"] ||= SourceIdentity.version(group)
        contract = Contract.new(group)
        build_adapter = IOS.new(group, actions: actions)
        selections =
          profiles.map do |name|
            request =
              PipelineRequest.new("e2e", "ios", values.except("profiles").merge("profile" => name))
            target = group.config.profile(name, component: "ios")
            unless target["kind"] == "simulator"
              raise PipelineError,
                    "iOS qualification requires simulator profiles; use ios e2e for an exact physical profile"
            end
            plan = request.plan(group.config, contract)
            build_adapter.admit(target, plan) unless plan.empty?
            [name, request, plan]
          end
        required = selections.any? { |_, _, plan| !plan.empty? }
        Atomic.json(
          File.join(group.output, "selection.json"),
          {
            status: required ? "required" : "not-required",
            profiles:
              selections.to_h do |name, _, plan|
                [name, plan.map { |test_case| test_case.fetch("id") }]
              end
          }
        )
        unless prepared || !required
          build_adapter.build({})
          prepared = File.join(group.output, "artifacts.json")
        end
        failures = []
        selections.each do |name, request, plan|
          context =
            RunContext.new(group.config, output: File.join(group.output, name), parent: group)
          adapter = IOS.new(context, actions: actions)
          adapter.prepared_products(prepared)
          begin
            Pipeline.new(context, request, adapter, planned_cases: plan).run
          rescue CleanupError, Interrupted
            raise
          rescue PipelineError => error
            failures << "#{name}: #{error.message}"
          end
        end
        raise PipelineError, failures.join("; ") unless failures.empty?
      ensure
        group.close
      end
      group.output
    end

    def self.catalog(options)
      unknown =
        options.keys.map(&:to_s) - %w[action platform suite cases device changed base output]
      raise PipelineError, "Unknown catalog options: #{unknown.join(", ")}" unless unknown.empty?
      context = RunContext.new(Config.new(ROOT), output: options[:output])
      begin
        action = options.fetch(:action, "lint")
        unless %w[lint list plan].include?(action)
          raise PipelineError, "catalog action must be lint, list or plan"
        end
        request = {
          platform: options.fetch(:platform, "android"),
          suite: options.fetch(:suite, ""),
          ids: options.fetch(:cases, "").split(","),
          device: options.fetch(:device, "iphone"),
          changed: options[:changed] == "true" || options[:changed] == true,
          base: options.fetch(:base, "")
        }
        result = Contract.new(context).call(action == "lint" ? "lint" : "plan", request)
        puts JSON.pretty_generate(result)
        Atomic.json(File.join(context.output, "catalog.json"), result)
        result
      ensure
        context.close
      end
    end

    def self.core_apple(options)
      request = PipelineRequest.new("test_unit", "core", options)
      context = RunContext.new(Config.new(ROOT), output: request.options["output"])
      begin
        Core.new(context).apple_test(request.options)
      ensure
        context.close
      end
    end

    def self.configure(options)
      path = File.join(ROOT, "fastlane/local.json")
      if File.exist?(path)
        raise PipelineError, "Local configuration already exists; edit it explicitly"
      end
      config = JSON.parse(File.read(File.join(ROOT, "fastlane/local.example.json")))
      context = RunContext.new(Config.new(ROOT, ci: true))
      begin
        runtime = options[:runtime]
        if RUBY_PLATFORM.include?("darwin")
          runtimes =
            JSON
              .parse(context.command(%w[xcrun simctl list runtimes -j], timeout: 30, binary: true))
              .fetch("runtimes")
              .select { |entry| entry["isAvailable"] && entry["platform"] == "iOS" }
          runtime ||= runtimes.first.fetch("identifier") if runtimes.length == 1
          unless runtime && runtimes.any? { |entry| entry["identifier"] == runtime }
            raise PipelineError, "Select runtime:IDENTIFIER from installed iOS runtimes"
          end
          %w[ios-iphone ios-ipad].each do |name|
            config.fetch("profiles").fetch(name)["runtime"] = runtime
          end
        end
        merged = Config.new(ROOT, ci: true).data
        merge =
          lambda do |base, override|
            base.merge(override) do |_key, a, b|
              a.is_a?(Hash) && b.is_a?(Hash) ? merge.call(a, b) : b
            end
          end
        JSON::Validator.validate!(
          File.join(ROOT, "fastlane/config.schema.json"),
          merge.call(merged, config)
        )
        Atomic.json(path, config)
        puts "Created ignored fastlane/local.json; physical profiles remain disabled until explicitly configured."
      ensure
        context.close
      end
    end

    def self.doctor(options = {})
      values = options.transform_keys(&:to_s)
      unless (values.keys - %w[profile]).empty?
        raise PipelineError, "doctor accepts only profile:NAME"
      end
      config = Config.new(ROOT)
      puts "Ruby #{RUBY_VERSION}; local configuration #{config.local_loaded ? "loaded" : "ignored/absent"}"
      profiles = config.data.fetch("profiles")
      if values["profile"]
        unless profiles.key?(values["profile"])
          raise PipelineError, "Unknown profile #{values["profile"]}"
        end
        profiles = profiles.slice(values["profile"])
      end
      profiles.each do |name, profile|
        begin
          config.profile(name)
          target = profile.slice("serial", "udid", "avd", "runtime", "device_type", "layout")
          puts "#{name}: configured (#{profile.fetch("kind")}) #{target.map { |key, value| "#{key}=#{value}" }.join(" ")}"
          if profile["signing"]
            signing = config.data.fetch("signing").fetch(profile.fetch("signing"))
            puts "  signing=#{profile.fetch("signing")} team=#{signing["team_id"] || "unconfigured"} app=#{signing["app_bundle_id"]}"
          end
        rescue Unavailable => error
          puts "#{name}: unavailable: #{error.message}"
        end
      end
      config.environment.each { |key, _value| puts "#{key}: configured" }
    end

    def self.candidate(component, options, actions: nil)
      context = RunContext.new(Config.new(ROOT), output: options[:output])
      begin
        pipeline = CandidatePipeline.new(context, component, options, actions: actions)
      rescue Exception
        context.close
        raise
      end
      pipeline.run
    end

    def self.release(options, actions: nil)
      unknown = options.keys.map(&:to_s) - %w[action identity output source channel tag release_id]
      raise PipelineError, "Unknown release options: #{unknown.join(", ")}" unless unknown.empty?
      context = RunContext.new(Config.new(ROOT), output: options[:output])
      begin
        github = GitHubDestination.new(context)
        action = options.fetch(:action, "reserve")
        return ReleaseRetention.new(context).prune if action == "prune"
        if action == "reserve"
          identity = github.reserve(options[:source] || ENV.fetch("GITHUB_SHA"))
          if ENV["GITHUB_OUTPUT"]
            File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
              file.puts(
                "tag=#{identity.tag}\nversion=#{identity.version}\nbuild=#{identity.build}\nsource=#{identity.source}"
              )
            end
          end
          puts "Reserved #{identity.tag} · dev from #{identity.source}"
          return identity
        end
        if options[:identity]
          identity = ReleaseIdentity.load(File.expand_path(options.fetch(:identity), context.root))
        else
          tag = options[:tag]
          tag ||= github.api("releases/#{Integer(options.fetch(:release_id))}").fetch("tag_name")
          ref = github.api("git/ref/tags/#{URI.encode_www_form_component(tag)}")
          unless ref.dig("object", "type") == "tag"
            raise PipelineError, "Release tag is not a pipeline reservation"
          end
          object = github.api("git/tags/#{ref.fetch("object").fetch("sha")}")
          unless object.fetch("message").start_with?("Dieter pipeline identity\n")
            raise PipelineError, "Release tag is not a pipeline identity"
          end
          identity =
            ReleaseIdentity.new(
              JSON.parse(object.fetch("message").delete_prefix("Dieter pipeline identity\n"))
            )
          unless identity.tag == tag && identity.source == object.dig("object", "sha") &&
                   identity.data["repository"] == github.repository
            raise PipelineError, "Reserved tag/source changed"
          end
          github.download(identity, "identity.json", File.join(context.output, "identity.json"))
          unless ReleaseIdentity.load(File.join(context.output, "identity.json")).data ==
                   identity.data
            raise PipelineError, "Retained identity changed"
          end
        end
        coordinator = ReleaseCoordinator.new(context, identity)
        case action
        when "assemble"
          coordinator.assemble
        when "publish"
          result = coordinator.publish(channel: options.fetch(:channel, "dev"))
          if ENV["GITHUB_OUTPUT"] && result
            File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
              file.puts("tag=#{identity.tag}\nrelease_id=#{result.fetch("id")}")
            end
          end
          result
        when "distribute"
          TestFlightDestination.new(context, identity, actions: actions).deliver
        when "promote"
          coordinator.promote
        when "gateway_prepare"
          coordinator.prepare_gateway
        when "pin"
          coordinator.verify_retained
          github.with_claim(identity, "retention") do
            github.receipt(identity, "retention", { "pinned" => true })
          end
        when "verify"
          coordinator.verify_retained
        else
          raise PipelineError, "Unknown release action #{action}"
        end
      ensure
        context.close
      end
    end
  end
end
