# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "fastlane/command_line_handler"
require_relative "../lib/dieter/ci"

class CIOptionsTest < Minitest::Test
  def test_release_call_chain_can_read_producer_checkpoints_and_recover_completed_claim_owners
    jobs = {
      "ci" => %w[release], "release" => %w[candidates coordinate distribute],
      "component-candidate" => %w[candidate], "release-coordinate" => %w[publish],
      "release-distribute" => %w[testflight], "ios-testflight" => %w[distribute],
      "release-promote" => %w[promote], "release-retention" => %w[retention],
      "gateway-deploy" => %w[prepare]
    }
    jobs.each do |workflow, names|
      data = YAML.safe_load(File.read(File.join(Dieter::Runtime::ROOT, ".github/workflows/#{workflow}.yml")))
      names.each do |name|
        assert_equal "read", data.fetch("jobs").fetch(name).fetch("permissions").fetch("actions"), "#{workflow}/#{name} needs Actions metadata for checkpoint and claim recovery"
      end
    end
  end

  def test_required_gate_refuses_skipped_selected_checks_and_accepts_unselected_components
    selections = %w[core macos ios android kmp].to_h { |name| [name, "false"] }
    selections["ios"] = "true"
    results = {"changes" => {"result" => "success", "outputs" => selections}}
    %w[portable core core-apple mac ios android].each { |name| results[name] = {"result" => "skipped"} }
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
