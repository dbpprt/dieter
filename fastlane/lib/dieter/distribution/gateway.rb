# frozen_string_literal: true

module Dieter
  class GatewayOCI
    IMAGE = "ghcr.io/dbpprt/dieter-gateway"
    BUNDLE = "ghcr.io/dbpprt/dieter-gateway-deploy"

    def initialize(context, identity)
      @context, @identity = context, identity
    end

    def candidate
      raise PipelineError, "Gateway image preparation requires trusted CI main" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main" && ENV["GITHUB_SHA"] == @identity.source
      @context.command(["python3", "deploy/gateway/tests/integration.py"], timeout: 1200, log: File.join(@context.output, "gateway-transports.log"))
      built_at = @context.command(["git", "show", "-s", "--format=%cI", "HEAD"], timeout: 30).strip
      metadata = File.join(@context.output, "gateway-build.json")
      tag = "#{IMAGE}:candidate-#{@identity.version}"
      @context.command(["docker", "buildx", "build", "--file", "Dockerfile.gateway", "--platform", "linux/amd64,linux/arm64", "--push", "--provenance=mode=max", "--sbom=true", "--metadata-file", metadata, "--build-arg", "RELEASE_VERSION=#{@identity.version}", "--build-arg", "SOURCE_REVISION=#{@identity.source}", "--build-arg", "BUILT_AT=#{built_at}", "--tag", tag, "--label", "org.opencontainers.image.revision=#{@identity.source}", "."], timeout: 3600, log: File.join(@context.output, "image.log"))
      digest = JSON.parse(File.read(metadata)).fetch("containerimage.digest")
      raise PipelineError, "Invalid OCI digest" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
      image = "#{IMAGE}@#{digest}"
      @context.command(["oras", "tag", image, "digest-#{digest.delete_prefix('sha256:')}"], timeout: 180)
      probes = {}
      %w[linux-amd64 linux-arm64 darwin-arm64].each do |target|
        os, arch = target.split("-")
        name = "gateway-turn-probe-#{target}"
        path = File.join(@context.private_dir, name)
        @context.command(["go", "build", "-trimpath", "-ldflags=-s -w", "-o", path, "./tools/fixtures/turn-probe"], environment: {"CGO_ENABLED" => "0", "GOOS" => os, "GOARCH" => arch}, timeout: 300)
        probes[name] = path
      end
      code = "import sys,json; sys.path.insert(0,'deploy/gateway/scripts'); import bundle; r=json.load(sys.stdin); bundle.pack(r['output'],r['source'],r['version'],r['image'],r['built_at'],r['probes'])"
      @context.command(["python3", "-c", code], input: JSON.generate({output: @context.output, source: @identity.source, version: @identity.version, image: image, built_at: built_at, probes: probes}), timeout: 120)
      manifest = File.join(@context.output, "gateway-manifest.json")
      signature = File.join(@context.output, "gateway-manifest.sigstore.json")
      @context.command(["cosign", "sign", "--yes", "-a", "sourceRevision=#{@identity.source}", image], timeout: 300)
      @context.command(["cosign", "sign-blob", "--yes", "--bundle", signature, manifest], timeout: 300)
      @context.command(["python3", "deploy/gateway/scripts/bundle.py", "verify", @context.output, "--revision", @identity.source, "--image", image], timeout: 300)
      # Publication consumes these digest-pinned bytes. Numeric/floating stable
      # aliases are reserved for the separate stable promotion path.
      reference = "#{BUNDLE}:candidate-#{@identity.version}"
      push_bundle(reference)
      descriptor = JSON.parse(@context.command(["oras", "manifest", "fetch", "--descriptor", reference], timeout: 180, binary: true))
      artifact_digest = descriptor.fetch("digest")
      raise PipelineError, "Invalid deployment artifact digest" unless artifact_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
      @context.command(["oras", "tag", "#{BUNDLE}@#{artifact_digest}", "digest-#{artifact_digest.delete_prefix('sha256:')}"], timeout: 180)
      Atomic.json(File.join(@context.output, "gateway-release.lock.json"), {interfaceVersion: 1, artifact: "#{BUNDLE}@#{artifact_digest}", releaseVersion: @identity.version, sourceRevision: @identity.source, image: image, bundleSHA256: ArtifactSet.sha256(File.join(@context.output, "dieter-gateway-deploy.tar.gz"))})
      %w[dieter-gateway-deploy.tar.gz gateway-manifest.json gateway-manifest.sigstore.json gateway-release.lock.json].map { |name| File.join(@context.output, name) }
    end

    def publish
      archive = File.join(@context.output, "dieter-gateway-deploy.tar.gz")
      lock_path = File.join(@context.output, "gateway-release.lock.json")
      lock = JSON.parse(File.read(lock_path))
      raise PipelineError, "Gateway retained source/hash mismatch" unless lock["sourceRevision"] == @identity.source && lock["releaseVersion"] == @identity.version && lock["bundleSHA256"] == ArtifactSet.sha256(archive)
      @context.command(["python3", "deploy/gateway/scripts/bundle.py", "verify", @context.output, "--revision", @identity.source, "--image", lock.fetch("image")], timeout: 300)
      artifact = lock.fetch("artifact")
      raise PipelineError, "Invalid retained OCI artifact" unless artifact.match?(/\A#{Regexp.escape(BUNDLE)}@sha256:[0-9a-f]{64}\z/)
      immutable_alias(artifact)
      immutable_alias(lock.fetch("image"))
      {"state" => "published", "artifact" => artifact, "image" => lock.fetch("image"), "bundle_sha256" => lock.fetch("bundleSHA256")}
    end

    private

    def push_bundle(reference)
      # ORAS 1.3.4 reads relative files from its process directory; it has no
      # --workdir flag. Keep layer titles portable without changing Ruby's cwd.
      @context.command(["oras", "push", reference, "--artifact-type", "application/vnd.dieter.gateway.deployment.v1", "--annotation", "org.opencontainers.image.revision=#{@identity.source}", "dieter-gateway-deploy.tar.gz:application/gzip", "gateway-manifest.json:application/json", "gateway-manifest.sigstore.json:application/json"], timeout: 300, chdir: @context.output)
    end

    def immutable_alias(reference)
      repository, expected = reference.split("@", 2)
      raise PipelineError, "Distribution must use a digest-pinned OCI reference" unless expected&.match?(/\Asha256:[0-9a-f]{64}\z/)
      process = @context.start(["oras", "manifest", "fetch", "--descriptor", "#{repository}:#{@identity.version}"], binary: true)
      output = @context.wait(process, timeout: 180, check: false)
      if process.status.success?
        actual = JSON.parse(output, allow_duplicate_key: false).fetch("digest")
        raise PipelineError, "Numeric OCI release alias already points to different bytes" unless actual == expected
        return
      end
      raise PipelineError, "Cannot verify numeric OCI release alias: #{process.output}" unless process.stderr.match?(/MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown|not found/i)
      @context.command(["oras", "tag", reference, @identity.version], timeout: 180)
      descriptor = JSON.parse(@context.command(["oras", "manifest", "fetch", "--descriptor", "#{repository}:#{@identity.version}"], timeout: 180, binary: true), allow_duplicate_key: false)
      raise PipelineError, "Numeric OCI alias publication was not confirmed" unless descriptor["digest"] == expected
    end
  end
end
