# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../lib/dieter/distribution/github"

class DistributionClaimTest < Minitest::Test
  class Context
    attr_reader :config, :secrets
    attr_accessor :before_acquire
    def initialize(root, repository)
      @root, @config, @secrets = root, Struct.new(:policy).new({"repository" => repository}), []
    end
    def command(argv, input: nil, label: nil, **)
      if label == "Acquire exact distribution claim" && before_acquire
        hook, self.before_acquire = before_acquire, nil
        hook.call
      end
      stdout, stderr, status = Open3.capture3(*argv, stdin_data: input || "", chdir: @root)
      raise Dieter::PipelineError, "#{label || argv.first} failed: #{stderr}" unless status.success?
      stdout
    end
    def during_cleanup = yield
  end

  class Destination < Dieter::GitHubDestination
    attr_accessor :owner_status
    def initialize(context, remote)
      super(context)
      @remote, @owner_status = remote, "completed"
    end
    def claim_remote = @remote
    def api(path, **)
      if path.start_with?("git/ref/")
        ref = "refs/" + path.delete_prefix("git/ref/")
        stdout, _stderr, status = Open3.capture3("git", "--git-dir", @remote, "rev-parse", "--verify", ref)
        raise Dieter::PipelineError, "404 missing ref" unless status.success?
        {"object" => {"sha" => stdout.strip}}
      elsif path.start_with?("git/tags/")
        sha = path.delete_prefix("git/tags/")
        object, = Open3.capture3("git", "--git-dir", @remote, "cat-file", "-p", sha)
        {"message" => object.split("\n\n", 2).last}
      elsif path.start_with?("actions/runs/")
        {"status" => owner_status}
      else
        raise "Unexpected API #{path}"
      end
    end
  end

  def setup
    @root = Dir.mktmpdir("distribution-claims-")
    @remote = File.join(@root, "destination.git")
    command = ->(*argv) do
      _stdout, stderr, status = Open3.capture3(*argv, chdir: @root)
      raise stderr unless status.success?
    end
    command.call("git", "init", "--bare", @remote)
    command.call("git", "init", @root)
    command.call("git", "config", "user.name", "Pipeline test")
    command.call("git", "config", "user.email", "pipeline@example.invalid")
    File.write(File.join(@root, "fixture"), "source")
    command.call("git", "add", "fixture")
    command.call("git", "-c", "commit.gpgsign=false", "commit", "-m", "source")
    @context = Context.new(@root, "example/pipeline")
    source = @context.command(%w[git rev-parse HEAD]).strip
    @identity = Dieter::ReleaseIdentity.new({"schema_version" => 1, "repository" => "example/pipeline", "source_revision" => source, "version" => "0.4.413", "tag" => "v0.4.413", "native_build" => 413, "reserved_at" => "2026-10-03T21:00:00Z", "policy_sha256" => "b" * 64})
    @destination = Destination.new(@context, @remote)
    @ref = "refs/tags/pipeline-claims/testflight/v0.4.413"
    @environment = %w[GITHUB_RUN_ID GITHUB_RUN_ATTEMPT].to_h { |name| [name, ENV[name]] }
    ENV["GITHUB_RUN_ID"], ENV["GITHUB_RUN_ATTEMPT"] = "5", "1"
  end

  def teardown
    @environment.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    FileUtils.remove_entry_secure(@root)
  end

  def remote_ref
    stdout, _stderr, status = Open3.capture3("git", "--git-dir", @remote, "rev-parse", "--verify", @ref)
    status.success? ? stdout.strip : nil
  end

  def insert_owner(run: 3)
    data = JSON.generate({identity: @identity.digest, run: run, attempt: 1})
    tag = "object #{@identity.source}\ntype commit\ntag test-claim\ntagger Test <test@example.invalid> 1791060000 +0000\n\n#{data}\n"
    sha = @context.command(%w[git mktag], input: tag).strip
    @context.command(["git", "push", "--force", @remote, "#{sha}:#{@ref}"])
    sha
  end

  def test_exact_claim_is_acquired_and_released
    entered = false
    @destination.with_claim(@identity, "testflight") { entered = true; refute_nil remote_ref }
    assert entered
    assert_nil remote_ref
  end

  def test_active_owner_is_preserved
    original = insert_owner
    @destination.owner_status = "in_progress"
    assert_raises(Dieter::Unavailable) { @destination.with_claim(@identity, "testflight") { flunk "active owner displaced" } }
    assert_equal original, remote_ref
  end

  def test_completed_owner_can_be_recovered
    original = insert_owner
    @destination.with_claim(@identity, "testflight") { refute_equal original, remote_ref }
    assert_nil remote_ref
  end

  def test_competing_admission_loses_compare_and_swap_without_entering
    competing = nil
    @context.before_acquire = -> { competing = insert_owner(run: 8) }
    assert_raises(Dieter::PipelineError) { @destination.with_claim(@identity, "testflight") { flunk "lost admission entered" } }
    assert_equal competing, remote_ref
  end

  def test_failure_releases_only_its_owned_claim
    assert_raises(Dieter::Interrupted) { @destination.with_claim(@identity, "testflight") { raise Dieter::Interrupted, "canceled delivery" } }
    assert_nil remote_ref
  end

  def test_replaced_claim_is_never_deleted_during_cleanup
    replacement = nil
    assert_raises(Dieter::PipelineError) { @destination.with_claim(@identity, "testflight") { replacement = insert_owner(run: 8) } }
    assert_equal replacement, remote_ref
  end
end
