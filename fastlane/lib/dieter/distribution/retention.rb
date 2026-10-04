# frozen_string_literal: true

require "time"
require_relative "coordinator"

module Dieter
  class ReleaseRetention
    def initialize(context)
      @context = context
      @github = GitHubDestination.new(context)
    end

    def self.eligible(releases, policy, now: Time.now.utc)
      devs = releases.select { |release| release["prerelease"] && !release["draft"] && release["published_at"] }.sort_by { |release| Time.iso8601(release.fetch("published_at")) }.reverse
      cutoff = now - policy.fetch("dev_days") * 86_400
      devs.drop(policy.fetch("dev_count")).select { |release| Time.iso8601(release.fetch("published_at")) < cutoff }
    end

    def prune
      raise PipelineError, "Retention requires trusted main CI" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main" && ENV["GITHUB_REPOSITORY"] == @github.repository
      releases = []
      1.upto(10) do |page|
        values = @github.api("releases?per_page=100&page=#{page}")
        releases.concat(values)
        break if values.length < 100
        raise Unavailable, "Release inventory exceeds bounded retention scan" if page == 10
      end
      self.class.eligible(releases, @context.config.policy.fetch("retention")).each do |release|
        # Only pipeline reservations can be pruned. Stable releases, drafts,
        # allocation tags, manifests, signatures and receipts are retained.
        ref = @github.api("git/ref/tags/#{URI.encode_www_form_component(release.fetch('tag_name'))}")
        next unless ref.dig("object", "type") == "tag"
        tag = @github.api("git/tags/#{ref.fetch('object').fetch('sha')}")
        next unless tag.fetch("message").start_with?("Dieter pipeline identity\n")
        identity = ReleaseIdentity.new(JSON.parse(tag.fetch("message").delete_prefix("Dieter pipeline identity\n"), object_class: UniqueObject, allow_duplicate_key: false))
        receipts = @github.receipts(identity, "retention")
        next if receipts.last && receipts.last["pinned"]
        next if @github.release(identity.tag).fetch("assets").any? { |asset| asset["name"].start_with?("promotion-") }
        child = RunContext.new(@context.config)
        begin
          manifest, sums = ReleaseCoordinator.new(child, identity).verify_retained(require_assets: false)
          delivered = @github.receipts(identity, "testflight").any? { |receipt| receipt["state"] == "completed" && receipt["ipa_sha256"] == sums.fetch("Dieter-iOS.ipa") }
          next unless delivered
          @github.with_claim(identity, "testflight") do
          @github.with_claim(identity, "retention") do
            current = @github.release(identity.tag)
            next if current["draft"] || !current["prerelease"] || @github.receipts(identity, "retention").last&.fetch("pinned", false)
            # OCI and deployment bundles are never pruned here: deployed and
            # rollback references can exist outside GitHub's release ledger.
            names = manifest.fetch("components").flat_map { |candidate| candidate.fetch("artifacts").map { |item| item.fetch("name") } }.reject { |name| name.start_with?("gateway-", "dieter-gateway-") }
            @github.receipt(identity, "retention", {"state" => "pruning", "assets" => names})
            current.fetch("assets").select { |asset| names.include?(asset.fetch("name")) }.each { |asset| @github.api("releases/assets/#{asset.fetch('id')}", method: "DELETE") }
            @github.receipt(identity, "retention", {"state" => "expired", "assets" => names})
          end
          end
        rescue Unavailable
          # Already expired or partially pruned releases preserve their ledger.
          next
        ensure
          child.close
        end
      end
    end
  end
end
