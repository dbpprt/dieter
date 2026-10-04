# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/pipeline/candidate"

class CandidateRecoveryTest < Minitest::Test
  class Context
    attr_reader :root, :output, :config, :environment, :commands
    attr_accessor :closed
    def initialize(root, output, policy, source)
      @root, @output, @config, @source = root, output, Struct.new(:policy).new(policy), source
      @environment, @commands = {}, []
    end
    def command(argv, **)
      @commands << argv
      return @source if argv == %w[git rev-parse HEAD]
      raise "Unexpected command: #{argv.inspect}"
    end
    def close = @closed = true
  end

  class Destination
    attr_reader :uploads, :records
    attr_accessor :assets, :producer, :fail_upload
    def initialize(identity)
      @identity, @assets, @uploads, @records, @producer = identity, [], [], [], nil
    end
    def release(*) = {"assets" => assets}
    def receipts(*) = records
    def with_claim(*) = yield
    def receipt(_identity, _name, value) = records << value
    def api(path, **)
      if path.start_with?("actions/artifacts?")
        {"artifacts" => []}
      else
        raise "Unexpected API: #{path}"
      end
    end
    def upload_immutable(_identity, path)
      uploads << [File.basename(path), File.binread(path)]
      raise Dieter::PipelineError, "upload failed" if fail_upload == File.basename(path)
    end
  end

  def setup
    @root = Dir.mktmpdir("candidate-recovery-")
    @policy = JSON.parse(File.read(File.expand_path("../release-policy.json", __dir__)))
    @identity = Dieter::ReleaseIdentity.new({"schema_version" => 1, "repository" => @policy.fetch("repository"), "source_revision" => "a" * 40, "version" => "0.4.413", "tag" => "v0.4.413", "native_build" => 413, "reserved_at" => "2026-10-03T21:00:00Z", "policy_sha256" => Digest::SHA256.hexdigest(JSON.generate(@policy))})
    @identity_path = File.join(@root, "identity.json")
    @identity.write(@identity_path)
    @producer = File.join(@root, "producer")
    Dir.mkdir(@producer)
    @payload = File.join(@producer, "Dieter-Android.apk")
    File.write(@payload, "original signed bytes")
    @manifest = {"schema_version" => 1, "component" => "android", "identity_sha256" => @identity.digest, "source_revision" => @identity.source, "release_version" => @identity.version, "native_build" => @identity.build, "qualification" => "passed", "artifacts" => [{"name" => File.basename(@payload), "sha256" => Dieter::ArtifactSet.sha256(@payload), "bytes" => File.size(@payload)}]}
    Dieter::Atomic.json(File.join(@producer, "candidate-android.json"), @manifest)
    @output = File.join(@root, "output")
    Dir.mkdir(@output)
    @context = Context.new(@root, @output, @policy, @identity.source)
    @destination = Destination.new(@identity)
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def runner(phase)
    Dieter::CandidatePipeline.new(@context, "android", {"identity" => @identity_path, "phase" => phase, "products" => @producer}, github: @destination)
  end

  def test_retention_consumes_exact_checkpoint_without_building_or_signing
    assert_equal @manifest, runner("retain").run
    assert_equal ["Dieter-Android.apk", "candidate-android.json"], @destination.uploads.map(&:first)
    assert_equal "original signed bytes", @destination.uploads.first.last
    assert_equal [%w[git rev-parse HEAD]], @context.commands
    assert @context.closed
  end

  def test_failed_payload_upload_does_not_commit_candidate_manifest
    @destination.fail_upload = "Dieter-Android.apk"
    assert_raises(Dieter::PipelineError) { runner("retain").run }
    assert_equal ["Dieter-Android.apk"], @destination.uploads.map(&:first)
    assert_equal ["Dieter-Android.apk"], @destination.records.last.fetch("artifacts")
  end

  def test_mutated_checkpoint_is_rejected_before_remote_mutation
    File.write(@payload, "different signed bytes")
    assert_raises(Dieter::PipelineError) { runner("retain").run }
    assert_empty @destination.uploads
    assert_empty @destination.records
  end

  def test_partial_release_without_producer_never_rebuilds
    @destination.assets = [{"name" => "Dieter-Android.apk"}]
    assert_raises(Dieter::Unavailable) { runner("prepare").run }
    assert_equal [%w[git rev-parse HEAD]], @context.commands
    assert_empty @destination.uploads
  end

  def test_recovered_checkpoint_is_qualified_and_preparation_has_no_upload
    @destination.records << {"state" => "producing"}
    pipeline = runner("prepare")
    manifest = @manifest
    source = @producer
    pipeline.define_singleton_method(:recover_producer) do |_name, output, _manifest_name|
      FileUtils.cp_r(Dir.glob(File.join(source, "*")), output)
      Dieter::CandidatePipeline.validate(manifest, @identity, output, expected: "android")
    end
    output = File.join(@root, "github-output")
    previous = ENV["GITHUB_OUTPUT"]
    ENV["GITHUB_OUTPUT"] = output
    assert_equal @manifest, pipeline.run
    assert_includes File.read(output), "checkpoint_required=false\n"
    assert_empty @destination.uploads
    assert_equal [%w[git rev-parse HEAD]], @context.commands
  ensure
    previous ? ENV["GITHUB_OUTPUT"] = previous : ENV.delete("GITHUB_OUTPUT")
  end

  def test_stopped_producer_without_checkpoint_never_builds_under_the_same_identity_again
    first = runner("prepare")
    calls = 0
    first.define_singleton_method(:produce) do
      calls += 1
      raise Dieter::Interrupted, "producer stopped before checkpoint"
    end
    assert_raises(Dieter::Interrupted) { first.run }
    assert_equal "producing", @destination.records.last.fetch("state")
    assert_empty @destination.uploads

    next_output = File.join(@root, "next-output")
    Dir.mkdir(next_output)
    @context = Context.new(@root, next_output, @policy, @identity.source)
    second = runner("prepare")
    second.define_singleton_method(:produce) { calls += 1 }
    assert_raises(Dieter::Unavailable) { second.run }
    assert_equal 1, calls
    assert @context.closed
  end
end
