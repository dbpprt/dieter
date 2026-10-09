# frozen_string_literal: true

require "minitest/autorun"
require "fastlane"
require_relative "../lib/dieter/pipeline/action"

class NativeActionTest < Minitest::Test
  def test_pinned_actions_accept_explicit_destinations_without_device_discovery_or_test_retries
    Fastlane.load_actions
    options = Fastlane::Actions::RunTestsAction.available_options.map(&:key)
    %i[xctestrun destination build_for_testing test_without_building skip_detect_devices only_testing result_bundle_path output_types parallel_testing disable_concurrent_testing number_of_retries skip_build skip_slack].each do |key|
      assert_includes options, key
    end
    options = Fastlane::Actions::BuildAppAction.available_options.map(&:key)
    %i[archive_path output_directory export_options skip_profile_detection xcargs].each { |key| assert_includes options, key }
  end

  def test_native_action_uses_private_input_and_the_owned_runner_instead_of_shell_or_ambient_devices
    context = Object.new
    calls = []
    context.define_singleton_method(:start) { |argv, **values| calls << [argv, values] }
    Dieter::NativeAction.start(context, "run_tests", {xctestrun: "/private/run.xctestrun", destination: "platform=iOS,id=exact-udid"}, log: "/evidence/test.log")
    argv, values = calls.first
    refute argv.join.include?("exact-udid")
    request = JSON.parse(values.fetch(:input))
    assert_equal "platform=iOS,id=exact-udid", request.fetch("options").fetch("destination")
    assert_raises(Dieter::PipelineError) { Dieter::NativeAction.start(context, "match", {}, log: "log") }
  end

  def test_existing_test_products_skip_resolution_and_builds_preserve_locked_dependencies
    testing = Dieter::NativeAction.configuration_options("test_without_building" => true)
    assert testing.fetch(:skip_package_dependencies_resolution)
    assert testing.fetch(:disable_package_automatic_updates)
    assert_equal "xcpretty", testing.fetch(:xcodebuild_formatter)
    building = Dieter::NativeAction.configuration_options("build_for_testing" => true)
    refute building[:skip_package_dependencies_resolution]
    assert building.fetch(:disable_package_automatic_updates)
  end
end
