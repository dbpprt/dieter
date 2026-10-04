# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/pipeline/context"
require_relative "../lib/dieter/pipeline/engine"
require_relative "../lib/dieter/platforms/apple_build"

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

  def test_explicit_apple_job_limit_overrides_the_local_limit_but_paths_still_conflict
    previous = %w[DIETER_SWIFT_JOBS DEVELOPER_DIR].to_h { |key| [key, ENV[key]] }
    override(toolchains: {swift_jobs: 2, developer_dir: "/configured/xcode"})
    ENV["DIETER_SWIFT_JOBS"] = "4"
    ENV["DEVELOPER_DIR"] = "/configured/xcode"
    environment = Dieter::Config.new(@root, ci: false).environment
    context = Struct.new(:environment).new(environment)
    assert_equal ["-jobs", "4"], Dieter::AppleBuild.jobs(context, tool: :xcode)
    ENV["DEVELOPER_DIR"] = "/another/xcode"
    assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: false).environment }
    ENV["DEVELOPER_DIR"] = "/configured/xcode"
    ENV["DIETER_SWIFT_JOBS"] = "65"
    context.environment = Dieter::Config.new(@root, ci: false).environment
    assert_raises(Dieter::PipelineError) { Dieter::AppleBuild.jobs(context, tool: :xcode) }
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_only_disposable_hosted_checks_share_the_mac_test_and_app_build_graph
    keys = %w[GITHUB_ACTIONS RUNNER_ENVIRONMENT DIETER_APPLE_CHECK_CACHE]
    previous = keys.to_h { |key| [key, ENV[key]] }
    context = Struct.new(:root).new(@root)
    ENV["GITHUB_ACTIONS"] = "true"
    ENV["RUNNER_ENVIRONMENT"] = "github-hosted"
    ENV["DIETER_APPLE_CHECK_CACHE"] = "true"
    assert_equal Dieter::AppleBuild.mac_scratch(context, operation: :test), Dieter::AppleBuild.mac_scratch(context, operation: :build)
    ENV.delete("DIETER_APPLE_CHECK_CACHE") # Release producers keep their graph.
    assert_equal File.join(@root, "apps/mac/.build/dieter-local"), Dieter::AppleBuild.mac_scratch(context, operation: :build)
    ENV["DIETER_APPLE_CHECK_CACHE"] = "true"
    ENV["RUNNER_ENVIRONMENT"] = "self-hosted"
    assert_equal File.join(@root, "apps/mac/.build/dieter-local"), Dieter::AppleBuild.mac_scratch(context, operation: :build)
    ENV.delete("GITHUB_ACTIONS")
    assert_equal File.join(@root, "apps/mac/.build/dieter-local"), Dieter::AppleBuild.mac_scratch(context, operation: :build)
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_unresolved_simulator_runtime_and_physical_identity_fail_admission
    config = Dieter::Config.new(@root, ci: false)
    assert_raises(Dieter::Unavailable) { config.profile("ios-iphone") }
    override({profiles: {"android-device" => {enabled: true}}})
    assert_raises(Dieter::Unavailable) { Dieter::Config.new(@root, ci: false).profile("android-device") }
  end

  def test_go_module_mode_avoids_the_ruby_vendor_directory_and_keeps_other_flags
    previous = ENV["GOFLAGS"]
    ENV["GOFLAGS"] = "-tags=pipeline"
    assert_equal "-tags=pipeline -mod=mod", Dieter::Config.new(@root, ci: false).environment.fetch("GOFLAGS")
    ENV.delete("GOFLAGS")
    assert_equal "-mod=mod", Dieter::Config.new(@root, ci: false).environment.fetch("GOFLAGS")
  ensure
    previous ? ENV["GOFLAGS"] = previous : ENV.delete("GOFLAGS")
  end

  def with_ci_environment(values)
    keys = %w[DIETER_CI_DEVICE_CONFIG DIETER_CI_IOS_RUNTIME GITHUB_ACTIONS GITHUB_REF RUNNER_ENVIRONMENT]
    previous = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| values[key] ? ENV[key] = values[key] : ENV.delete(key) }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_ci_runtime_selection_replaces_template_values_without_disabling_duplicate_json_checks
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    with_ci_environment("GITHUB_ACTIONS" => "true", "DIETER_CI_IOS_RUNTIME" => runtime) do
      config = Dieter::Config.new(@root, ci: true)
      %w[ios-iphone ios-ipad].each { |name| assert_equal runtime, config.profile(name).fetch("runtime") }
    end
    override({profiles: {"ios-iphone" => {runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"}}})
    assert_equal "com.apple.CoreSimulator.SimRuntime.iOS-27-0", Dieter::Config.new(@root, ci: false).profile("ios-iphone").fetch("runtime")
    File.write(File.join(@root, "fastlane/local.json"), '{"profiles":{"ios-iphone":{"runtime":"a","runtime":"b"}}}')
    assert_raises(Dieter::PipelineError) { Dieter::Config.new(@root, ci: false) }
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

  def test_live_log_redacts_secrets_split_between_pipe_reads_and_keeps_stream_identity
    log = File.join(@root, "live.log")
    stdout, = capture_io do
      process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", '$stdout.sync = true; print "private-"; sleep 0.05; puts "token"; warn "diagnostic"'], log: log, secrets: ["private-token"])
      process.wait(timeout: 5)
    end
    assert_includes stdout, "stdout: <redacted>"
    assert_includes stdout, "stderr: diagnostic"
    refute_includes stdout, "private-token"
    refute_includes File.read(log), "private-token"
  end

  def test_child_context_reuses_parent_lease_but_closes_its_own_resources
    config = Struct.new(:root) { def environment = {} }.new(@root)
    parent = Dieter::RunContext.new(config)
    child = Dieter::RunContext.new(config, parent: parent)
    begin
      lease = parent.lease("apple-build")
      assert_same lease, child.lease("apple-build")
      child.close
      assert_raises(Dieter::Unavailable) { Dieter::Lease.new("apple-build", root: @root) }
      parent.close
      successor = Dieter::Lease.new("apple-build", root: @root)
      successor.close
    ensure
      child.close
      parent.close
    end
  end

  def test_binary_output_overflow_fails_instead_of_retaining_a_truncated_success
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'STDOUT.write("x" * 4096)'], binary: true, output_limit: 1024)
    assert_raises(Dieter::PipelineError) { process.wait(timeout: 5) }
  end

  def test_parent_preserves_borrowed_lease_until_failed_child_cleanup_succeeds
    config = Struct.new(:root) { def environment = {} }.new(@root)
    parent = Dieter::RunContext.new(config)
    child = Dieter::RunContext.new(config, parent: parent)
    child.lease("apple-build")
    ready, completed = false, 0
    child.cleanup { raise Dieter::CleanupError, "owned simulator remains" unless ready }
    child.cleanup { completed += 1 }
    assert_raises(Dieter::CleanupError) { child.close }
    assert_raises(Dieter::CleanupError) { parent.close }
    assert_equal 1, completed
    assert File.directory?(child.private_dir)
    assert_raises(Dieter::Unavailable) { Dieter::Lease.new("apple-build", root: @root) }
    ready = true
    parent.close
    child.close
    parent.close
    assert_equal 1, completed
    refute File.directory?(child.private_dir)
    successor = Dieter::Lease.new("apple-build", root: @root)
    successor.close
  ensure
    ready = true
    parent&.close
  end

  def test_deadline_stops_owned_child_and_reaps_it
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'trap("INT") { exit }; sleep 30'])
    assert_raises(Dieter::Interrupted) { process.wait(timeout: 0.25) }
    refute process.running?
    assert_raises(Errno::ESRCH) { Process.kill(0, process.pid) }
  end

  def test_progress_observer_receives_the_owned_process_without_changing_its_result
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-e", 'sleep 0.2; print "done"'])
    process.define_singleton_method(:clock) { @tick = (@tick || 0) + 31 }
    observed = []
    assert_equal "done", process.wait(timeout: 10_000) { |running| observed << running }
    refute_empty observed
    assert observed.all? { |running| running.equal?(process) }
    assert process.status.success?
  end

  def test_stop_cleans_descendants_after_the_process_group_leader_exits
    script = 'pid = spawn(RbConfig.ruby, "-e", "sleep 30"); puts pid; STDOUT.flush; exit'
    process = Dieter::OwnedProcess.new(@root, [RbConfig.ruby, "-rrbconfig", "-e", script])
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while process.running? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.01
    end
    refute process.running?
    descendant = Integer(process.stdout.strip)
    process.stop
    refute process.instance_variable_get(:@readers).any?(&:alive?)
    # An orphan may remain a zombie until launchd reaps it, but must not run.
    state = IO.popen(["ps", "-o", "stat=", "-p", descendant.to_s], &:read).strip
    assert state.empty? || state.start_with?("Z"), "descendant still running: #{state}"
  ensure
    process&.stop
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

  def test_relative_artifact_verification_resolves_from_repository_while_fastlane_changes_directory
    product = File.join(@root, "app.apk")
    File.write(product, "verified application")
    manifest = File.join(@root, "artifacts.json")
    Dieter::ArtifactSet.new(component: "android", source: "source", configuration: "debug", products: {"apk" => product}).write(manifest)
    lane_directory = File.join(@root, "fastlane")
    FileUtils.mkdir_p(lane_directory)
    File.write(File.join(lane_directory, "artifacts.json"), "invalid shadow manifest")
    request = Dieter::PipelineRequest.new("verify", "android", {artifact: "artifacts.json"})
    Dir.chdir(lane_directory) do
      assert_equal @context.output, Dieter::Pipeline.new(@context, request, FakeAdapter.new, contract: @contract).run
    end
    assert JSON.parse(File.read(File.join(@context.output, "cleanup.json"))).fetch("passed")
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
