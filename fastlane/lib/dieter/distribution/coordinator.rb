# frozen_string_literal: true

require_relative "github"
require_relative "../pipeline/candidate"
require_relative "homebrew"

module Dieter
  class ReleaseCoordinator
    def initialize(context, identity)
      @context, @identity = context, identity
      @github = GitHubDestination.new(context)
    end

    def assemble
      trusted_main!
      @github.with_claim(@identity, "assembly") { assemble_retained }
    end

    def assemble_retained
      # A rerun verifies the signed assembly already committed to the release.
      # Signing the same bytes again would produce a different immutable bundle.
      if @github.release(@identity.tag).fetch("assets").any? { |asset| asset["name"] == "SHA256SUMS.sigstore.json" }
        return verify_retained.first
      end
      policy = @context.config.policy
      manifest = {"schema_version" => 1, "identity" => @identity.data, "policy" => policy, "channel" => "dev", "qualification" => "passed", "components" => []}
      names = []
      policy.fetch("required_components").each do |component|
        file = "candidate-#{component}.json"
        path = @github.download(@identity, file, File.join(@context.output, file))
        raise PipelineError, "Oversized candidate manifest" if File.size(path) > 128 * 1024
        value = JSON.parse(File.read(path), allow_duplicate_key: false)
        value.fetch("artifacts").each do |artifact|
          name = artifact.fetch("name")
          raise PipelineError, "Artifact shared by more than one component: #{name}" if names.include?(name)
          names << name
          @github.download(@identity, name, File.join(@context.output, name))
        end
        CandidatePipeline.validate(value, @identity, @context.output, expected: component)
        manifest["components"] << value
      end
      @identity.write(File.join(@context.output, "identity.json"))
      Atomic.json(File.join(@context.output, "release.json"), manifest)
      FileUtils.cp(File.join(@context.root, "scripts/install.sh"), File.join(@context.output, "install.sh"))
      files = names + %w[identity.json release.json install.sh] + policy.fetch("required_components").map { |name| "candidate-#{name}.json" }
      sums = files.sort.map { |name| "#{ArtifactSet.sha256(File.join(@context.output, name))}  #{name}\n" }.join
      Atomic.write(File.join(@context.output, "SHA256SUMS"), sums, mode: 0o644)
      @context.command(["cosign", "sign-blob", "--yes", "--bundle", File.join(@context.output, "SHA256SUMS.sigstore.json"), File.join(@context.output, "SHA256SUMS")], timeout: 300)
      files.concat(%w[SHA256SUMS SHA256SUMS.sigstore.json]).each { |name| @github.upload_immutable(@identity, File.join(@context.output, name)) }
      @github.receipt(@identity, "github", {"state" => "assembled", "manifest_sha256" => ArtifactSet.sha256(File.join(@context.output, "release.json"))})
      manifest
    end

    def publish(channel: "dev")
      trusted_main!
      @github.with_claim(@identity, "publication") { publish_retained(channel: channel) }
    end

    def publish_retained(channel:)
      raise PipelineError, "Main publication supports dev or draft" unless %w[dev draft].include?(channel)
      verify_retained
      return if channel == "draft"
      publish_gateway
      release = @github.release(@identity.tag)
      raise PipelineError, "Cannot demote an already stable release" unless release["prerelease"]
      value = @github.api("releases/#{release.fetch('id')}", method: "PATCH", body: {draft: false, prerelease: true, name: "Dieter #{@identity.version} · dev", body: "Development build from #{@identity.source}. All required component candidates passed their release gates.\n\nTestFlight delivery is tracked in the retained distribution receipts.", make_latest: "false"})
      @github.receipt(@identity, "github", {"state" => "published", "release_id" => value.fetch("id"), "channel" => "dev"})
      value
    end

    def verify_retained(require_assets: true)
      ref = @github.api("git/ref/tags/#{@identity.tag}")
      raise PipelineError, "Reserved release tag was replaced" unless ref.dig("object", "type") == "tag"
      tag = @github.api("git/tags/#{ref.fetch('object').fetch('sha')}")
      raise PipelineError, "Reserved release source or identity changed" unless tag.dig("object", "sha") == @identity.source && tag.fetch("message").start_with?("Dieter pipeline identity\n") && JSON.parse(tag.fetch("message").delete_prefix("Dieter pipeline identity\n"), object_class: UniqueObject, allow_duplicate_key: false) == @identity.data
      @context.command(["git", "merge-base", "--is-ancestor", @identity.source, "origin/main"], timeout: 30, label: "Verify release ancestry")
      %w[SHA256SUMS SHA256SUMS.sigstore.json release.json].each do |name|
        path = File.join(@context.output, name)
        @github.download(@identity, name, path) unless File.exist?(path)
      end
      @context.command(["cosign", "verify-blob", "--bundle", File.join(@context.output, "SHA256SUMS.sigstore.json"), "--certificate-identity", "https://github.com/#{@github.repository}/.github/workflows/release-coordinate.yml@refs/heads/main", "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com", File.join(@context.output, "SHA256SUMS")], timeout: 120)
      sums = {}
      File.foreach(File.join(@context.output, "SHA256SUMS")) do |line|
        match = /\A([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9_.-]+)\n\z/.match(line)
        raise PipelineError, "Invalid/duplicate signed checksum entry" unless match && !sums.key?(match[2])
        sums[match[2]] = match[1]
      end
      raise PipelineError, "Release metadata is not signed" unless sums["release.json"] == ArtifactSet.sha256(File.join(@context.output, "release.json"))
      value = JSON.parse(File.read(File.join(@context.output, "release.json")), object_class: UniqueObject, allow_duplicate_key: false, max_nesting: 32)
      ReleaseIdentity.new(value.fetch("identity"), policy: value.fetch("policy"))
      raise PipelineError, "Release identity mismatch" unless value["identity"] == @identity.data && value["qualification"] == "passed"
      required = value.fetch("policy").fetch("required_components")
      actual = value.fetch("components").map { |candidate| candidate.fetch("component") }
      raise PipelineError, "Incomplete or duplicate release component set" unless actual.sort == required.sort && actual.uniq == actual
      value.fetch("components").each do |candidate|
        candidate.fetch("artifacts").each do |item|
          raise PipelineError, "Candidate artifact is not bound by signed release" unless sums[item.fetch("name")] == item.fetch("sha256")
        end
      end
      assets = @github.release(@identity.tag).fetch("assets")
      (require_assets ? sums : {}).each do |name, expected|
        matches = assets.select { |asset| asset["name"] == name }
        raise Unavailable, "Required retained release asset is missing or duplicated: #{name}" unless matches.length == 1
        digest = matches.first["digest"]
        raise PipelineError, "Retained release asset digest changed: #{name}" if digest && digest != "sha256:#{expected}"
      end
      [value, sums]
    end

    def promote
      raise PipelineError, "Stable promotion requires protected main CI" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main" && ENV["GITHUB_REPOSITORY"] == @github.repository
      @github.with_claim(@identity, "stable", key: "stable") do
        @github.with_claim(@identity, "retention") { @github.receipt(@identity, "retention", {"pinned" => true}) }
        manifest, sums = verify_retained
        release = @github.release(@identity.tag)
        raise PipelineError, "Stable promotion requires a published complete candidate" if release.fetch("draft")
        latest = @github.api("releases/latest")
        if latest.fetch("tag_name") != @identity.tag
          previous = latest.fetch("tag_name").delete_prefix("v").split(".").map { |part| Integer(part, 10) }
          selected = @identity.version.split(".").map { |part| Integer(part, 10) }
          raise PipelineError, "Stable promotion cannot move Latest backwards" unless (selected <=> previous) == 1
        end
        if manifest.fetch("policy").fetch("channels").fetch("stable").fetch("testflight")
          delivered = @github.receipts(@identity, "testflight").any? { |record| record["state"] == "completed" && record["ipa_sha256"] == sums.fetch("Dieter-iOS.ipa") }
          raise Unavailable, "Complete this candidate's TestFlight delivery before stable promotion" unless delivered
          TestFlightDestination.new(@context, @identity, actions: nil).verify_live_delivery!(sums.fetch("Dieter-iOS.ipa"))
        end
        homebrew = HomebrewDestination.new(@context, @identity, sums).publish
        @github.receipt(@identity, "homebrew", homebrew)
        promotion = {schema_version: 1, identity_sha256: @identity.digest, manifest_sha256: sums.fetch("release.json"), release_id: release.fetch("id"), channel: "stable", homebrew_commit: homebrew.fetch("commit")}
        path = File.join(@context.output, "promotion-stable.json")
        if @github.release(@identity.tag).fetch("assets").any? { |asset| asset["name"] == File.basename(path) }
          @github.download(@identity, File.basename(path), path)
          retained = JSON.parse(File.read(path), object_class: UniqueObject, allow_duplicate_key: false)
          raise PipelineError, "Stable promotion receipt conflicts with the candidate" unless retained.slice("identity_sha256", "manifest_sha256", "release_id", "channel") == JSON.parse(JSON.generate(promotion)).slice("identity_sha256", "manifest_sha256", "release_id", "channel")
        else
          Atomic.json(path, promotion)
          @github.upload_immutable(@identity, path)
        end
        signature = path + ".sigstore.json"
        if @github.release(@identity.tag).fetch("assets").any? { |asset| asset["name"] == File.basename(signature) }
          @github.download(@identity, File.basename(signature), signature)
          @context.command(["cosign", "verify-blob", "--bundle", signature, "--certificate-identity", "https://github.com/#{@github.repository}/.github/workflows/release-promote.yml@refs/heads/main", "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com", path], timeout: 120)
        else
          @context.command(["cosign", "sign-blob", "--yes", "--bundle", signature, path], timeout: 300)
          @github.upload_immutable(@identity, signature)
        end
        result = @github.api("releases/#{release.fetch('id')}", method: "PATCH", body: {draft: false, prerelease: false, name: "Dieter #{@identity.version}", make_latest: "true"})
        @github.receipt(@identity, "stable", {"state" => "completed", "release_id" => result.fetch("id"), "promotion_sha256" => ArtifactSet.sha256(path)})
        result
      end
    end

    def prepare_gateway
      _manifest, sums = verify_retained
      release = @github.release(@identity.tag)
      raise PipelineError, "Production preparation requires a published stable release" if release["draft"] || release["prerelease"]
      %w[promotion-stable.json promotion-stable.json.sigstore.json].each do |name|
        @github.download(@identity, name, File.join(@context.output, name))
      end
      promotion_path = File.join(@context.output, "promotion-stable.json")
      @context.command(["cosign", "verify-blob", "--bundle", promotion_path + ".sigstore.json", "--certificate-identity", "https://github.com/#{@github.repository}/.github/workflows/release-promote.yml@refs/heads/main", "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com", promotion_path], timeout: 120)
      promotion = JSON.parse(File.read(promotion_path), object_class: UniqueObject, allow_duplicate_key: false)
      raise PipelineError, "Gateway preparation requires this candidate's signed stable promotion" unless promotion["identity_sha256"] == @identity.digest && promotion["manifest_sha256"] == sums.fetch("release.json") && promotion["release_id"] == release.fetch("id") && promotion["channel"] == "stable"
      @github.with_claim(@identity, "retention") { @github.receipt(@identity, "retention", {"pinned" => true}) }
      %w[dieter-gateway-deploy.tar.gz gateway-manifest.json gateway-manifest.sigstore.json gateway-release.lock.json].each do |name|
        path = File.join(@context.output, name)
        @github.download(@identity, name, path) unless File.exist?(path)
        raise PipelineError, "Retained gateway hash mismatch" unless sums.fetch(name) == ArtifactSet.sha256(path)
      end
      lock = JSON.parse(File.read(File.join(@context.output, "gateway-release.lock.json")), object_class: UniqueObject, allow_duplicate_key: false)
      raise PipelineError, "Gateway deployment identity differs from retained release" unless lock["sourceRevision"] == @identity.source && lock["releaseVersion"] == @identity.version && lock["bundleSHA256"] == sums.fetch("dieter-gateway-deploy.tar.gz")
      @context.command(["python3", "deploy/gateway/scripts/bundle.py", "verify", @context.output, "--revision", @identity.source, "--image", lock.fetch("image")], timeout: 300)
      gateway = JSON.parse(File.read(File.join(@context.output, "gateway-manifest.json")), object_class: UniqueObject, allow_duplicate_key: false)
      plan = {schema_version: 1, release_tag: @identity.tag, source_revision: @identity.source, release_manifest_sha256: sums.fetch("release.json"), image: lock.fetch("image"), artifact: lock.fetch("artifact"), bundle_sha256: lock.fetch("bundleSHA256"), compatibility_policy: gateway.fetch("compatibilityPolicy"), state: "verified-awaiting-operator-admission"}
      Atomic.json(File.join(@context.output, "gateway-deployment-plan.json"), plan)
      puts "Verified retained gateway distribution; admit through the restricted host controller and supply authenticated readiness before its rollback deadline."
      plan
    end

    private

    def publish_gateway
      _manifest, sums = verify_retained
      %w[dieter-gateway-deploy.tar.gz gateway-manifest.json gateway-manifest.sigstore.json gateway-release.lock.json].each do |name|
        path = File.join(@context.output, name)
        @github.download(@identity, name, path) unless File.exist?(path)
        raise PipelineError, "Gateway distribution hash mismatch" unless sums.fetch(name) == ArtifactSet.sha256(path)
      end
      @github.receipt(@identity, "gateway", GatewayOCI.new(@context, @identity).publish)
    end

    def trusted_main!
      raise PipelineError, "Release mutation requires trusted main CI" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main" && ENV["GITHUB_REPOSITORY"] == @github.repository && ENV["GITHUB_SHA"] == @identity.source
    end
  end
end
