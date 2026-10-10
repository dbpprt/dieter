# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "fastlane/command_line_handler"
require_relative "../lib/dieter/ci"

class CIOptionsTest < Minitest::Test
  def test_routine_portable_ci_uses_the_typed_affected_package_plan_without_native_work
    previous = ENV["CI_CHANGE_BASE"]
    ENV["CI_CHANGE_BASE"] = "a" * 40
    context = Struct.new(:root, :environment, :output).new("/isolated", {}, "/evidence")
    requests = [
      {
        "component" => "portable",
        "operation" => "go_test",
        "packages" => ["./internal/pipeline"]
      },
      { "component" => "portable", "operation" => "contracts" },
      { "component" => "mac", "operation" => "e2e" }
    ]
    contract = Object.new
    contract.define_singleton_method(:call) do |operation, values|
      unless operation == "affected-checks" && values == { base: "a" * 40, kind: "local" }
        raise "wrong selection"
      end
      { "checks" => requests }
    end
    executed = []
    executor =
      lambda do |_context, component, operation, options, packages:|
        executed << [component, operation, options, packages]
      end
    Dieter::SourceIdentity.stub(:version, "0.4.413") do
      Dieter::Contract.stub(:new, ->(*) { contract }) do
        Dieter::Atomic.stub(:json, nil) do
          Dieter::Checks.stub(:perform, executor) do
            Dieter::CI.check(context, "portable", full: false)
          end
        end
      end
    end
    assert_equal [
                   ["portable", "go_test", {}, ["./internal/pipeline"]],
                   ["portable", "contracts", {}, []]
                 ],
                 executed
  ensure
    previous ? ENV["CI_CHANGE_BASE"] = previous : ENV.delete("CI_CHANGE_BASE")
  end

  def test_dev_release_cannot_pass_with_skipped_candidates_publication_or_delivery
    results =
      %w[reserve candidates coordinate distribute].to_h { |name| [name, { "result" => "success" }] }
    Dieter::CI.qualify_release(results, channel: "dev")
    results.each_key do |name|
      %w[skipped failure cancelled].each do |status|
        bad = results.merge(name => { "result" => status })
        assert_raises(Dieter::PipelineError) { Dieter::CI.qualify_release(bad, channel: "dev") }
      end
    end
    assert_raises(Dieter::PipelineError) do
      Dieter::CI.qualify_release(results.except("candidates"), channel: "dev")
    end
    results["distribute"]["result"] = "skipped"
    Dieter::CI.qualify_release(results, channel: "draft")
    assert_raises(Dieter::PipelineError) { Dieter::CI.qualify_release(results, channel: "stable") }
  end

  def test_mac_ci_requires_privacy_package_qualification_in_routine_and_full_runs
    [false, true].each do |full|
      context = Struct.new(:root, :environment, :output).new("/isolated", {}, "/evidence")
      context.define_singleton_method(:command) { |*, **| }
      calls = []
      adapter = Object.new
      %i[privacy_native_test core_test].each do |name|
        adapter.define_singleton_method(name) { calls << name }
      end
      %i[unit build].each { |name| adapter.define_singleton_method(name) { |_| calls << name } }
      Dieter::SourceIdentity.stub(:version, "0.4.413") do
        Dieter::Mac.stub(:new, ->(*) { adapter }) do
          Dieter::CI.check(context, "mac", full: full)
          assert_includes calls, :privacy_native_test
          adapter.define_singleton_method(:privacy_native_test) do
            raise Dieter::PipelineError, "invalid helper package"
          end
          assert_raises(Dieter::PipelineError) { Dieter::CI.check(context, "mac", full: full) }
        end
      end
    end
  end

  def test_release_call_chain_can_read_producer_checkpoints_and_recover_completed_claim_owners
    jobs = {
      "ci" => %w[release],
      "release" => %w[candidates coordinate distribute],
      "component-candidate" => %w[candidate],
      "release-coordinate" => %w[publish],
      "release-distribute" => %w[testflight],
      "ios-testflight" => %w[distribute],
      "release-promote" => %w[promote],
      "release-retention" => %w[retention],
      "gateway-deploy" => %w[prepare]
    }
    jobs.each do |workflow, names|
      data =
        YAML.safe_load(
          File.read(File.join(Dieter::Runtime::ROOT, ".github/workflows/#{workflow}.yml"))
        )
      names.each do |name|
        assert_equal "read",
                     data.fetch("jobs").fetch(name).fetch("permissions").fetch("actions"),
                     "#{workflow}/#{name} needs Actions metadata for checkpoint and claim recovery"
      end
    end
  end

  def test_required_gate_refuses_skipped_selected_checks_and_accepts_unselected_components
    selections = %w[core macos ios android kmp].to_h { |name| [name, "false"] }
    selections["ios"] = "true"
    results = { "changes" => { "result" => "success", "outputs" => selections } }
    %w[portable core core-apple mac ios android].each do |name|
      results[name] = { "result" => "skipped" }
    end
    assert_raises(Dieter::PipelineError) { Dieter::CI.qualify_jobs(results, full: false) }
    results["ios"]["result"] = "success"
    Dieter::CI.qualify_jobs(results, full: false)
    selections.delete("android")
    assert_raises(Dieter::PipelineError) { Dieter::CI.qualify_jobs(results, full: false) }
    selections["android"] = "false"
    assert_raises(Dieter::PipelineError) { Dieter::CI.qualify_jobs(results, full: true) }
    results["changes"]["result"] = "failure"
    assert_raises(Dieter::PipelineError) { Dieter::CI.qualify_jobs(results, full: false) }
  end

  def test_selected_mobile_app_gates_cannot_be_missing_skipped_cancelled_or_failed
    selections = %w[core macos ios android kmp].to_h { |name| [name, "true"] }
    results = { "changes" => { "result" => "success", "outputs" => selections } }
    %w[portable core core-apple mac ios android].each do |name|
      results[name] = { "result" => "success" }
    end
    # Jobs outside the gate cannot affect it.
    Dieter::CI.qualify_jobs(results, full: true)
    Dieter::CI.qualify_jobs(results.merge("compose-ios" => { "result" => "failure" }), full: true)
    %w[ios android].each do |name|
      %w[skipped failure cancelled].each do |status|
        assert_raises(Dieter::PipelineError) do
          Dieter::CI.qualify_jobs(results.merge(name => { "result" => status }), full: false)
        end
      end
      assert_raises(Dieter::PipelineError) do
        Dieter::CI.qualify_jobs(results.except(name), full: true)
      end
    end
  end

  def test_ios_ci_builds_the_compose_app_without_a_separate_unit_lane
    [false, true].each do |full|
      context = Struct.new(:root, :environment, :output).new("/isolated", {}, "/evidence")
      calls = []
      adapter = Object.new
      adapter.define_singleton_method(:build) { |options| calls << [:build, options] }
      Dieter::SourceIdentity.stub(:version, "0.4.413") do
        Dieter::IOS.stub(:new, ->(*) { adapter }) { Dieter::CI.check(context, "ios", full: full) }
      end
      assert_equal [[:build, {}]], calls
      refute Dieter::IOS.method_defined?(:unit)
    end
  end

  def test_android_ci_compiles_only_the_e2e_journey_without_running_an_emulator
    [false, true].each do |full|
      context = Struct.new(:root, :environment, :output).new("/isolated", {}, "/evidence")
      started, waited, calls = [], [], []
      context.define_singleton_method(:start) do |argv, **options|
        started << [argv, options.fetch(:log)]
        argv
      end
      context.define_singleton_method(:wait) { |process, **| waited << process }
      adapter = Object.new
      %i[unit build].each do |name|
        adapter.define_singleton_method(name) { |options| calls << [name, options] }
      end
      Dieter::SourceIdentity.stub(:version, "0.4.413") do
        Dieter::Android.stub(:new, ->(*) { adapter }) do
          Dieter::CI.check(context, "android", full: full)
        end
      end
      assert_equal [[:unit, {}], [:build, {}]], calls
      assert_equal [
                     [
                       %w[
                         /isolated/apps/android/gradlew
                         --project-dir
                         apps/android
                         --console=plain
                         -Pdieter.testBuildType=e2e
                         :app:assembleE2e
                         :app:assembleE2eAndroidTest
                       ],
                       "/evidence/e2e-build.log"
                     ]
                   ],
                   started
      assert_equal [started.first.first], waited
    end
  end

  def test_setup_accepts_values_from_the_pinned_fastlane_cli_parser
    %w[true false].each do |literal|
      parsed = Fastlane::CommandLineHandler.convert_value(literal)
      assert_equal literal, Dieter::CI.boolean_option(parsed, "fixture")
      assert_equal literal, Dieter::CI.boolean_option(parsed, "native")
      assert_equal literal, Dieter::CI.boolean_option(literal, "fixture")
    end
  end

  def test_invalid_setup_flags_do_not_admit_runner_preparation
    [nil, "", "maybe", 0, 1, []].each do |value|
      assert_raises(Dieter::PipelineError) { Dieter::CI.boolean_option(value, "fixture") }
    end
  end

  def test_apple_core_ci_runs_kotlin_tests_without_repeating_swift_integration_or_assembling_unused_slices
    context = Struct.new(:root, :environment, :output).new("/isolated", {}, "/evidence")
    commands = []
    context.define_singleton_method(:lease) { |_| }
    context.define_singleton_method(:command) { |argv, **| commands << argv }
    Dieter::SourceIdentity.stub(:version, "0.4.413") { Dieter::CI.check(context, "core-apple") }
    assert_equal 1, commands.length
    assert_equal %w[:shared:macosArm64Test :apple:macosArm64Test], commands.first.last(2)
    refute commands.first.any? { |value| value.include?("XCFramework") || value == "swift" }
  end
end
