# frozen_string_literal: true

require "minitest/autorun"
require "fastlane"
require_relative "../lib/dieter/pipeline/action"

class NativeActionTest < Minitest::Test
  def test_pinned_build_action_accepts_simulator_and_archive_options
    Fastlane.load_actions
    options = Fastlane::Actions::BuildAppAction.available_options.map(&:key)
    %i[
      archive_path
      output_directory
      export_options
      skip_archive
      skip_package_ipa
      skip_profile_detection
      derived_data_path
      destination
      xcargs
    ].each { |key| assert_includes options, key }
  end

  def test_native_action_uses_private_input_and_the_owned_runner_instead_of_shell
    context = Object.new
    calls = []
    context.define_singleton_method(:start) { |argv, **values| calls << [argv, values] }
    Dieter::NativeAction.start(
      context,
      "build_app",
      { destination: "generic/platform=iOS Simulator", xcargs: "SECRET=1" },
      log: "/evidence/build.log"
    )
    argv, values = calls.first
    refute argv.join.include?("SECRET")
    request = JSON.parse(values.fetch(:input))
    assert_equal "generic/platform=iOS Simulator", request.fetch("options").fetch("destination")
    assert_raises(Dieter::PipelineError) do
      Dieter::NativeAction.start(context, "run_tests", {}, log: "log")
    end
  end

  def test_builds_preserve_locked_dependencies_and_compact_output
    building = Dieter::NativeAction.configuration_options("skip_archive" => true)
    refute building[:skip_package_dependencies_resolution]
    assert building.fetch(:disable_package_automatic_updates)
    assert_equal "xcpretty", building.fetch(:xcodebuild_formatter)
  end
end
