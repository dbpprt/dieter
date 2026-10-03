# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/pipeline/context"
require_relative "../lib/dieter/pipeline/engine"

class PipelineConfigTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("pipeline-config-")
    FileUtils.mkdir_p(File.join(@root, "fastlane"))
    %w[config.json config.schema.json release-policy.json].each do |name|
      FileUtils.cp(File.expand_path("../#{name}", __dir__), File.join(@root, "fastlane", name))
    end
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def override(value)
    File.write(File.join(@root, "fastlane/local.json"), JSON.generate(value))
  end

  def test_ci_ignores_even_invalid_local_configuration
    File.write(File.join(@root, "fastlane/local.json"), "bad JSON")
    refute Dieter::Config.new(@root, ci: true).local_loaded
    assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: false) }
  end

  def test_named_profile_override_preserves_other_profiles_and_rejects_wrong_component
    override({profiles: {"android-device" => {enabled: true, serial: "physical-123"}}})
    config = Dieter::Config.new(@root, ci: false)
    assert_equal "physical-123", config.profile("android-device", component: "android").fetch("serial")
    assert_equal 8, config.data.fetch("profiles").length
    assert_raises(Dieter::PipelineError) { config.profile("android-device", component: "ios") }
    assert_raises(Dieter::PipelineError) { config.profile("android-device", physical_explicit: false) }
  end

  def test_unknown_keys_executable_hooks_and_local_release_policy_are_rejected
    [{hooks: {after: "sh"}}, {release: {channel: "stable"}}, {profiles: {"android-emulator" => {renderer: "software"}}}].each do |value|
      override(value)
      assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: false) }
    end
  end

  def test_duplicate_keys_are_rejected_before_merge
    File.write(File.join(@root, "fastlane/local.json"), '{"schema_version":1,"schema_version":1}')
    assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: false) }
  end

  def test_unresolved_simulator_runtime_and_physical_identity_fail_admission
    config = Dieter::Config.new(@root, ci: false)
    assert_raises(Dieter::Unavailable) { config.profile("ios-iphone") }
    override({profiles: {"android-device" => {enabled: true}}})
    assert_raises(Dieter::Unavailable) { Dieter::Config.new(@root, ci: false).profile("android-device") }
  end

  def with_ci_environment(values)
    keys = %w[DIETER_CI_DEVICE_CONFIG GITHUB_ACTIONS GITHUB_REF RUNNER_ENVIRONMENT]
    previous = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| values[key] ? ENV[key] = values[key] : ENV.delete(key) }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_physical_ci_configuration_requires_trusted_main_and_preserves_policy
    trusted = {"GITHUB_ACTIONS" => "true", "GITHUB_REF" => "refs/heads/main", "RUNNER_ENVIRONMENT" => "self-hosted", "DIETER_CI_DEVICE_CONFIG" => JSON.generate(profiles: {"android-device" => {enabled: true, serial: "fixture-phone"}})}
    with_ci_environment(trusted) do
      config = Dieter::Config.new(@root, ci: true)
      assert_equal "fixture-phone", config.profile("android-device").fetch("serial")
      assert_equal "emulator-5554", config.profile("android-emulator").fetch("serial")
      refute config.local_loaded
    end
    [{"GITHUB_ACTIONS" => "false"}, {"GITHUB_REF" => "refs/pull/1/merge"}, {"RUNNER_ENVIRONMENT" => "github-hosted"}].each do |change|
      with_ci_environment(trusted.merge(change)) { assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: true) } }
    end
    [{defaults: {android_profile: "android-device"}}, {profiles: {"android-emulator" => {enabled: false}}}, {signing: {"android-release" => {keystore_file: "evil"}}}, {profiles: []}, {fixture_routes: []}].each do |value|
      with_ci_environment(trusted.merge("DIETER_CI_DEVICE_CONFIG" => JSON.generate(value))) { assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: true) } }
    end
    ["invalid JSON", " " * 16_385, '{"profiles":{},"profiles":{}}'].each do |raw|
      with_ci_environment(trusted.merge("DIETER_CI_DEVICE_CONFIG" => raw)) { assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: true) } }
    end
  end
end

class PipelinePrimitivesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("pipeline-primitives-")
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_exact_argv_and_binary_stdout_stay_separate_from_stderr
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'STDOUT.write(ARGV.fetch(0)); STDERR.write("diagnostic")', "a;$(false) ' b"], binary: true)
    assert_equal "a;$(false) ' b", process.wait(timeout: 5)
    assert_equal "diagnostic", process.stderr
  end

  def test_private_input_and_secret_redaction
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'STDOUT.write(STDIN.read)'], input: "private-token", secrets: ["private-token"])
    assert_equal "<redacted>", process.wait(timeout: 5)
    refute process.output.include?("private-token")
  end

  def test_binary_output_overflow_fails_instead_of_retaining_a_truncated_success
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'STDOUT.write("x" * 4096)'], binary: true, output_limit: 1024)
    assert_raises(Dieter::PipelineError) { process.wait(timeout: 5) }
  end

  def test_deadline_stops_owned_child_and_reaps_it
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'trap("INT") { exit }; sleep 30'])
    assert_raises(Dieter::Interrupted) { process.wait(timeout: 0.25) }
    refute process.running?
    assert_raises(Errno::ESRCH) { Process.kill(0, process.pid) }
  end

  def test_lease_conflict_preserves_inode_then_releases
    lease = Dieter::Lease.new("spec", root: @root)
    inode = File.stat(lease.path).ino
    begin
      assert_raises(Dieter::Unavailable) { Dieter::Lease.new("spec", root: @root) }
      assert_equal inode, File.stat(lease.path).ino
    ensure
      lease.close
    end
    successor = Dieter::Lease.new("spec", root: @root)
    assert_equal inode, File.stat(successor.path).ino
    successor.close
  end

  def test_artifacts_fail_on_mutated_bytes_and_escaping_links
    product = File.join(@root, "app")
    File.write(product, "verified")
    artifacts = Dieter::ArtifactSet.new(component: "android", source: "source", configuration: "debug", products: {"apk" => product})
    manifest = File.join(@root, "artifacts.json")
    artifacts.write(manifest)
    assert_equal artifacts.manifest, Dieter::ArtifactSet.load(manifest, source: "source", component: "android").manifest
    File.write(product, "changed")
    assert_raises(Dieter::PipelineError) { Dieter::ArtifactSet.load(manifest) }
    tree = File.join(@root, "tree")
    Dir.mkdir(tree)
    File.write(File.join(tree, "contents"), "valid directory artifact")
    first = Dieter::ArtifactSet.sha256(tree)
    File.write(File.join(tree, "contents"), "mutated directory artifact")
    refute_equal first, Dieter::ArtifactSet.sha256(tree)
    File.symlink("../app", File.join(tree, "escape"))
    assert_raises(Dieter::PipelineError) { Dieter::ArtifactSet.sha256(tree) }
  end

  def test_directory_product_hash_is_portable_and_includes_modes_and_links
    first = File.join(@root, "first")
    second = File.join(@root, "second")
    Dir.mkdir(first)
    File.write(File.join(first, "executable"), "immutable bytes")
    File.symlink("executable", File.join(first, "current"))
    FileUtils.cp_r(first, second)
    assert_equal Dieter::ArtifactSet.sha256(first), Dieter::ArtifactSet.sha256(second)
    File.chmod(0o755, File.join(second, "executable"))
    refute_equal Dieter::ArtifactSet.sha256(first), Dieter::ArtifactSet.sha256(second)
  end
end

class PipelineExecutionTest < Minitest::Test
  Config = Struct.new(:root) do
    def environment = {}
    def data = {"defaults" => {"suite" => "functional"}, "profiles" => {"target" => {"layout" => "iphone"}}}
    def default_profile(_component) = "target"
    def profile(name, **) = {"name" => name}
  end

  class FakeContract
    attr_reader :reports, :plans
    def initialize
      @reports = []
      @plans = []
    end
    def call(operation, request, **)
      if operation == "plan"
        @plans << request
        return {"cases" => %w[first second].map { |id| {"id" => id, "timeout" => "10s"} }}
      end
      @reports << Marshal.load(Marshal.dump(request.fetch(:report))) if operation == "report"
      {}
    end
  end

  class FakeAdapter
    attr_reader :calls
    def initialize(failure: nil, cleanup: false)
      @calls, @failure, @cleanup = [], failure, cleanup
    end
    def admit(*)
      @calls << :admit
      raise @failure if @failure
    end
    def prepare(*) = @calls << :prepare
    def execute_case(_target, test_case)
      @calls << test_case.fetch("id")
      {"status" => "passed", "setupMs" => 0, "executionMs" => 0, "cleanupError" => @cleanup ? "fixture still running" : ""}
    end
  end

  def setup
    @root = Dir.mktmpdir("pipeline-execution-")
    @context = Dieter::RunContext.new(Config.new(@root))
    @contract = FakeContract.new
    @request = Dieter::PipelineRequest.new("e2e", "ios")
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_shared_loop_prepares_once_and_requires_all_selected_cases
    adapter = FakeAdapter.new
    Dieter::Pipeline.new(@context, @request, adapter, contract: @contract).run
    assert_equal [:admit, :prepare, "first", "second"], adapter.calls
    assert_equal %w[first second], @contract.reports.last.fetch("results").map { |value| value.fetch("id") }
    assert JSON.parse(File.read(File.join(@context.output, "cleanup.json"))).fetch("passed")
    assert_equal "functional", @contract.plans.last.fetch(:suite)
  end

  def test_explicit_cases_do_not_expand_the_configured_default_suite
    request = Dieter::PipelineRequest.new("e2e", "ios", {cases: "first"})
    Dieter::Pipeline.new(@context, request, FakeAdapter.new, contract: @contract).run
    assert_equal "", @contract.plans.last.fetch(:suite)
    assert_equal ["first"], @contract.plans.last.fetch(:ids)
  end

  def test_unavailable_admission_accounts_for_every_required_case
    adapter = FakeAdapter.new(failure: Dieter::Unavailable.new("leased target"))
    assert_raises(Dieter::Unavailable) { Dieter::Pipeline.new(@context, @request, adapter, contract: @contract).run }
    assert_equal [:admit], adapter.calls
    assert_equal ["unavailable", "unavailable"], @contract.reports.last.fetch("results").map { |value| value.fetch("status") }
  end

  def test_cleanup_failure_stops_loop_and_fails_remaining_cases
    adapter = FakeAdapter.new(cleanup: true)
    assert_raises(Dieter::CleanupError) { Dieter::Pipeline.new(@context, @request, adapter, contract: @contract).run }
    assert_equal [:admit, :prepare, "first"], adapter.calls
    assert_equal ["failed", "interrupted"], @contract.reports.last.fetch("results").map { |value| value.fetch("status") }
  end

  def test_unknown_options_and_invalid_booleans_fail_before_execution
    assert_raises(Dieter::PipelineError) { Dieter::PipelineRequest.new("e2e", "ios", {upload: true}) }
    assert_raises(Dieter::PipelineError) { Dieter::PipelineRequest.new("e2e", "android", {changed: "maybe"}) }
  end
end
