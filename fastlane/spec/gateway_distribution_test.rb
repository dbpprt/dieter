# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require_relative "../lib/dieter/errors"
require_relative "../lib/dieter/distribution/gateway"
require_relative "../lib/dieter/distribution/coordinator"

class GatewayImmutableAliasTest < Minitest::Test
  def test_bundle_push_uses_the_owned_artifact_directory_and_portable_layer_names
    calls = []
    context = OpenStruct.new(output: "/artifact directory")
    context.define_singleton_method(:command) { |argv, **options| calls << [argv, options] }
    source = "a" * 40
    runner = Dieter::GatewayOCI.new(context, OpenStruct.new(source: source))
    before = Dir.pwd
    runner.send(:push_bundle, "ghcr.io/dbpprt/dieter-gateway-deploy:candidate-0.4.413")
    argv, options = calls.fetch(0)
    assert_equal before, Dir.pwd
    assert_equal "/artifact directory", options.fetch(:chdir)
    assert_equal ["dieter-gateway-deploy.tar.gz:application/gzip", "gateway-manifest.json:application/json", "gateway-manifest.sigstore.json:application/json"], argv.last(3)
    assert_includes argv, "org.opencontainers.image.revision=#{source}"
    refute_includes argv, "--workdir"
  end

  class Context
    attr_reader :commands
    attr_accessor :existing, :failure, :confirmed
    def initialize
      @commands = []
    end
    def start(argv, **)
      @commands << argv
      OpenStruct.new(status: OpenStruct.new(success?: !existing.nil?), stderr: failure || "MANIFEST_UNKNOWN", output: failure || "MANIFEST_UNKNOWN")
    end
    def wait(*) = JSON.generate(digest: existing)
    def command(argv, **)
      @commands << argv
      JSON.generate(digest: confirmed)
    end
  end

  def setup
    @context = Context.new
    @digest = "sha256:" + "a" * 64
    @context.confirmed = @digest
    @runner = Dieter::GatewayOCI.new(@context, OpenStruct.new(version: "0.4.413"))
    @reference = "#{Dieter::GatewayOCI::IMAGE}@#{@digest}"
  end

  def test_existing_matching_alias_has_no_mutation
    @context.existing = @digest
    @runner.send(:immutable_alias, @reference)
    assert_equal 1, @context.commands.length
  end

  def test_existing_different_alias_and_registry_failure_cannot_be_overwritten
    @context.existing = "sha256:" + "b" * 64
    assert_raises(Dieter::PipelineError) { @runner.send(:immutable_alias, @reference) }
    @context.existing = nil
    @context.failure = "unauthorized: access token denied"
    assert_raises(Dieter::PipelineError) { @runner.send(:immutable_alias, @reference) }
    assert_equal 2, @context.commands.length
  end

  def test_missing_alias_is_created_once_and_reread_to_confirm
    @runner.send(:immutable_alias, @reference)
    assert_equal ["oras", "tag", @reference, "0.4.413"], @context.commands[1]
    assert_equal 3, @context.commands.length
    @context.confirmed = "sha256:" + "b" * 64
    assert_raises(Dieter::PipelineError) { @runner.send(:immutable_alias, @reference) }
  end
end

class GatewayPreparationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("gateway-prepare-")
    @commands, @records, @downloads = [], [], []
    @identity = OpenStruct.new(tag: "v0.4.413", source: "a" * 40, version: "0.4.413", digest: "b" * 64)
    @release = {"id" => 413, "draft" => false, "prerelease" => false}
    @sums = {"release.json" => "c" * 64}
    @files = {
      "dieter-gateway-deploy.tar.gz" => "signed retained bundle",
      "gateway-manifest.json" => JSON.generate(compatibilityPolicy: {minimumClientRelease: "0.4.413"}),
      "gateway-manifest.sigstore.json" => "gateway signature fixture",
      "gateway-release.lock.json" => JSON.generate(sourceRevision: @identity.source, releaseVersion: @identity.version, bundleSHA256: Digest::SHA256.hexdigest("signed retained bundle"), image: "ghcr.io/dbpprt/dieter-gateway@sha256:" + "d" * 64, artifact: "ghcr.io/dbpprt/dieter-gateway-deploy@sha256:" + "e" * 64),
      "promotion-stable.json" => JSON.generate(identity_sha256: @identity.digest, manifest_sha256: @sums["release.json"], release_id: 413, channel: "stable"),
      "promotion-stable.json.sigstore.json" => "promotion signature fixture"
    }
    @files.each { |name, bytes| @sums[name] = Digest::SHA256.hexdigest(bytes) }
    commands, root = @commands, @root
    @context = Object.new
    @context.define_singleton_method(:output) { root }
    @context.define_singleton_method(:command) { |argv, **| commands << argv; "" }
    github = Object.new
    release, files, downloads, records = @release, @files, @downloads, @records
    github.define_singleton_method(:repository) { "dbpprt/dieter" }
    github.define_singleton_method(:release) { |_| release }
    github.define_singleton_method(:with_claim) { |*args, &block| block.call }
    github.define_singleton_method(:receipt) { |_, destination, value| records << [destination, value] }
    github.define_singleton_method(:download) { |_, name, path| downloads << name; File.write(path, files.fetch(name)); path }
    @runner = Dieter::ReleaseCoordinator.allocate
    @runner.instance_variable_set(:@context, @context)
    @runner.instance_variable_set(:@identity, @identity)
    @runner.instance_variable_set(:@github, github)
    sums = @sums
    @runner.define_singleton_method(:verify_retained) { [{}, sums] }
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def test_only_promoted_stable_bytes_are_prepared_without_activation
    plan = @runner.prepare_gateway
    assert_equal "verified-awaiting-operator-admission", plan.fetch(:state)
    assert_equal @identity.source, plan.fetch(:source_revision)
    assert_equal [["retention", {"pinned" => true}]], @records
    assert @commands.first.include?("https://github.com/dbpprt/dieter/.github/workflows/release-promote.yml@refs/heads/main")
    assert_equal ["python3", "deploy/gateway/scripts/bundle.py", "verify"], @commands.last.first(3)
    assert File.file?(File.join(@root, "gateway-deployment-plan.json"))
    refute @commands.flatten.any? { |arg| arg.match?(/ssh|activate|restart/) }
  end

  def test_dev_draft_unpromoted_and_corrupt_bytes_cannot_prepare_production
    @release["prerelease"] = true
    assert_raises(Dieter::PipelineError) { @runner.prepare_gateway }
    assert_empty @records
    @release["prerelease"] = false
    @release["draft"] = true
    assert_raises(Dieter::PipelineError) { @runner.prepare_gateway }
    @release["draft"] = false
    @files["promotion-stable.json"] = @files.fetch("promotion-stable.json").sub(@identity.digest, "f" * 64)
    assert_raises(Dieter::PipelineError) { @runner.prepare_gateway }
    assert_empty @records
    @files["promotion-stable.json"] = @files.fetch("promotion-stable.json").sub("f" * 64, @identity.digest)
    @files["dieter-gateway-deploy.tar.gz"] = "changed bytes"
    assert_raises(Dieter::PipelineError) { @runner.prepare_gateway }
    refute File.exist?(File.join(@root, "gateway-deployment-plan.json"))
  end
end
