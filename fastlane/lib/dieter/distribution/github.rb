# frozen_string_literal: true

require "time"
require "uri"
require_relative "../pipeline/identity"
require_relative "../pipeline/artifacts"
require_relative "../config"

module Dieter
  class GitHubDestination
    attr_reader :repository
    def initialize(context)
      @context = context
      @repository = context.config.policy.fetch("repository")
      @context.secrets << ENV["GH_TOKEN"] if ENV["GH_TOKEN"]
    end

    def api(path, method: "GET", body: nil)
      argv = ["gh", "api", "repos/#{repository}/#{path}", "--method", method, "-H", "Accept: application/vnd.github+json"]
      argv += ["--input", "-"] if body
      output = @context.command(argv, input: body && JSON.generate(body), timeout: 120, binary: true)
      output.empty? ? nil : JSON.parse(output, allow_duplicate_key: false)
    end

    def reserve(source)
      raise PipelineError, "Reservation requires trusted CI main checkout" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main" && ENV["GITHUB_REPOSITORY"] == repository && source == ENV["GITHUB_SHA"]
      actual = @context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip
      raise PipelineError, "Release checkout differs from event" unless actual == source
      policy = @context.config.policy
      prefix = "v#{policy.fetch('release_line')}."
      12.times do
        refs = api("git/matching-refs/tags/#{prefix}")
        refs.each do |ref|
          next unless ref.dig("object", "type") == "tag"
          object = api("git/tags/#{ref.fetch('object').fetch('sha')}")
          next unless object.dig("object", "sha") == source && object.fetch("message").start_with?("Dieter pipeline identity\n")
          identity = ReleaseIdentity.new(JSON.parse(object.fetch("message").delete_prefix("Dieter pipeline identity\n"), allow_duplicate_key: false), policy: policy)
          ensure_draft(identity)
          return identity
        end
        counters = refs.filter_map { |ref| match = /\Arefs\/tags\/v#{Regexp.escape(policy.fetch('release_line'))}\.(\d+)\z/.match(ref.fetch("ref")); match && match[1].to_i }
        counter = (counters.max || 0) + 1
        identity = ReleaseIdentity.new({"schema_version" => 1, "repository" => repository, "source_revision" => source, "version" => "#{policy.fetch('release_line')}.#{counter}", "tag" => "#{prefix}#{counter}", "native_build" => counter, "reserved_at" => Time.now.utc.iso8601, "policy_sha256" => Digest::SHA256.hexdigest(JSON.generate(policy))}, policy: policy)
        tag = api("git/tags", method: "POST", body: {tag: identity.tag, message: "Dieter pipeline identity\n" + JSON.generate(identity.data), object: source, type: "commit"})
        begin
          api("git/refs", method: "POST", body: {ref: "refs/tags/#{identity.tag}", sha: tag.fetch("sha")})
        rescue PipelineError => error
          raise unless error.message.include?("422") && api("git/matching-refs/tags/#{identity.tag}").any? { |entry| entry["ref"] == "refs/tags/#{identity.tag}" }
          next
        end
        ensure_draft(identity)
        return identity
      end
      raise PipelineError, "Concurrent identity reservation did not settle; retry without rebuilding"
    end

    def release(tag)
      api("releases/tags/#{URI.encode_www_form_component(tag)}")
    rescue PipelineError => error
      raise unless error.message.include?("404")
      # The by-tag endpoint omits drafts, even for the token that created them.
      # Authenticated release listings include drafts; keep the lookup bounded.
      100.times do |page|
        releases = api("releases?per_page=100&page=#{page + 1}")
        matches = releases.select { |value| value.fetch("tag_name") == tag }
        raise PipelineError, "Duplicate release identity #{tag}" if matches.length > 1
        return matches.first unless matches.empty?
        raise error if releases.length < 100
      end
      raise PipelineError, "Draft release lookup exceeded 10,000 releases"
    end

    def ensure_draft(identity)
      begin
        value = release(identity.tag)
      rescue PipelineError => error
        raise unless error.message.include?("404")
        begin
          value = api("releases", method: "POST", body: {tag_name: identity.tag, target_commitish: identity.source, name: "Dieter #{identity.version} · dev (preparing)", body: "Immutable candidate for #{identity.source}. Required component checks are still running.", draft: true, prerelease: true, make_latest: "false"})
        rescue PipelineError => error
          raise unless error.message.include?("422")
          value = release(identity.tag)
        end
      end
      local = File.join(@context.output, "identity.json")
      identity.write(local)
      upload_immutable(identity, local)
      value
    end

    def download(identity, name, output)
      raise PipelineError, "Unsafe release asset name" unless name.match?(/\A[A-Za-z0-9_.-]+\z/)
      assets = release(identity.tag).fetch("assets").select { |asset| asset.fetch("name") == name }
      raise Unavailable, "Missing or duplicate retained release asset #{name}" unless assets.length == 1
      asset = assets.first
      @context.command(["gh", "release", "download", identity.tag, "--repo", repository, "--pattern", name, "--dir", File.dirname(output)], timeout: 600)
      raise PipelineError, "Downloaded artifact has wrong name" unless File.basename(output) == name
      digest = asset["digest"]
      raise PipelineError, "GitHub release asset digest mismatch" if digest && digest != "sha256:#{ArtifactSet.sha256(output)}"
      output
    end

    def upload_immutable(identity, path)
      name = File.basename(path)
      assets = release(identity.tag).fetch("assets").select { |asset| asset["name"] == name }
      if assets.length == 1
        expected = "sha256:#{ArtifactSet.sha256(path)}"
        digest = assets.first["digest"]
        if digest.nil?
          directory = Dir.mktmpdir("verify-release-asset-", @context.private_dir)
          existing = download(identity, name, File.join(directory, name))
          digest = "sha256:#{ArtifactSet.sha256(existing)}"
        end
        raise PipelineError, "Reserved asset #{name} already has different bytes; allocate a new identity" unless digest == expected
        return
      end
      raise PipelineError, "Duplicate immutable release asset #{name}" unless assets.empty?
      @context.command(["gh", "release", "upload", identity.tag, path, "--repo", repository], timeout: 600)
    end

    def receipt(identity, destination, value)
      data = {"schema_version" => 1, "identity_sha256" => identity.digest, "destination" => destination, "recorded_at" => Time.now.utc.iso8601, "value" => value}
      path = File.join(@context.output, "receipt-#{destination}-#{Digest::SHA256.hexdigest(JSON.generate(data))}.json")
      Atomic.json(path, data)
      upload_immutable(identity, path)
      data
    end

    def receipts(identity, destination)
      release(identity.tag).fetch("assets").select { |asset| asset["name"].start_with?("receipt-#{destination}-") && asset["name"].end_with?(".json") }.sort_by { |asset| asset.fetch("id") }.map do |asset|
        directory = Dir.mktmpdir("receipt-", @context.private_dir)
        path = download(identity, asset.fetch("name"), File.join(directory, asset.fetch("name")))
        raise PipelineError, "Oversized distribution receipt" if File.size(path) > 128 * 1024
        data = JSON.parse(File.read(path), allow_duplicate_key: false)
        raise PipelineError, "Receipt identity mismatch" unless data["identity_sha256"] == identity.digest && data["destination"] == destination
        data.fetch("value")
      end
    end

    # Git's force-with-lease provides compare-and-swap admission across callers
    # and workflow files. A completed owner's lease is recoverable; an active
    # owner is never displaced. Receipts reconcile uncertain external effects.
    def with_claim(identity, destination, key: identity.tag)
      run = Integer(ENV.fetch("GITHUB_RUN_ID"))
      attempt = Integer(ENV.fetch("GITHUB_RUN_ATTEMPT"))
      raise PipelineError, "Invalid distribution claim" unless destination.match?(/\A[a-z][a-z0-9-]+\z/) && run.positive? && attempt.positive?
      raise PipelineError, "Invalid distribution claim key" unless key.match?(/\A[A-Za-z0-9.-]+\z/)
      ref = "refs/tags/pipeline-claims/#{destination}/#{key}"
      old = ""
      begin
        existing = api("git/ref/#{ref.delete_prefix('refs/')}")
        old = existing.fetch("object").fetch("sha")
        object = api("git/tags/#{old}")
        owner = JSON.parse(object.fetch("message"), object_class: UniqueObject, allow_duplicate_key: false)
        raise PipelineError, "Invalid distribution claim identity" unless owner["identity"].is_a?(String) && owner["identity"].match?(/\A[0-9a-f]{64}\z/)
        status = api("actions/runs/#{Integer(owner.fetch('run'))}/attempts/#{Integer(owner.fetch('attempt'))}")
        raise Unavailable, "Distribution is owned by active run #{owner.fetch('run')} attempt #{owner.fetch('attempt')}" unless status["status"] == "completed"
      rescue PipelineError => error
        raise unless error.message.include?("404") && old.empty?
      end
      owner = JSON.generate({identity: identity.digest, run: run, attempt: attempt})
      tag = "object #{identity.source}\ntype commit\ntag pipeline-claim\ntagger Dieter Pipeline <pipeline@dieter.tools> #{Time.now.to_i} +0000\n\n#{owner}\n"
      sha = @context.command(["git", "mktag"], input: tag, timeout: 30).strip
      raise PipelineError, "Invalid claim object" unless sha.match?(/\A[0-9a-f]{40}\z/)
      remote = claim_remote
      git = ["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "--force-with-lease=#{ref}:#{old}", remote, "#{sha}:#{ref}"]
      @context.command(git, timeout: 120, label: "Acquire exact distribution claim")
      begin
        yield
      ensure
        @context.during_cleanup do
          @context.command(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "--force-with-lease=#{ref}:#{sha}", remote, ":#{ref}"], timeout: 120, label: "Release exact distribution claim")
        end
      end
    end

    def claim_remote = "https://github.com/#{repository}.git"
  end
end
