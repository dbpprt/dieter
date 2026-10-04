# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/screens"

class ScreenScenarioSafetyTest < Minitest::Test
  def test_failure_measurements_are_retained_without_overwriting_native_failure
    Dir.mktmpdir("screen-failure-") do |directory|
      parent = Struct.new(:output).new(directory)
      Dir.mkdir(File.join(directory, "fixture"))
      Dieter::Runtime.stub(:invoke, ->(*) { raise Dieter::PipelineError, "native assertion failed" }) do
        observed = {"status" => "passed", "reason" => "good average", "artifacts" => ["latency.json"], "metrics" => {"inputP95Ms" => 60}}
        Dieter::Screens.stub(:evidence, observed) do
          result = Dieter::Screens.run_case(parent, {"id" => "fixture", "runner" => "android-codec"}, "exact-device")
          assert_equal "failed", result.fetch("status")
          assert_equal "native assertion failed", result.fetch("reason")
          assert_equal ["latency.json"], result.fetch("artifacts")
          assert_equal 60, result.dig("metrics", "inputP95Ms")
        end
        Dieter::Screens.stub(:evidence, ->(*) { raise "private diagnostic text" }) do
          result = Dieter::Screens.run_case(parent, {"id" => "fixture", "runner" => "android-codec"}, "exact-device")
          assert_equal "failed", result.fetch("status")
          assert_equal "native assertion failed", result.fetch("reason")
          assert_equal "RuntimeError", result.fetch("diagnosticError")
          refute result.to_s.include?("private diagnostic text")
        end
      end
    end
  end

  def test_only_declared_scenarios_and_experiments_can_select_execution
    [{"runner" => "shell"}, {"runner" => "native", "switches" => {"DIETER_HOME" => "/live"}}, {"runner" => "native", "switches" => {"DIETER_SCREEN_OVERLAP" => 50}}, {"runner" => "mac-latency", "presentation" => "unknown"}, {"runner" => "android-codec", "directSurface" => "false"}].each do |scenario|
      assert_raises(Dieter::PipelineError) { Dieter::Screens.settings(scenario) }
    end
    settings = Dieter::Screens.settings({"runner" => "android-recovery", "directSurface" => true})
    assert_equal "1", settings.fetch("DIETER_SCREEN_TEST_DIRECT_SURFACE")
    assert_equal "0", settings.fetch("DIETER_SCREEN_TEST_SURFACE")
  end
end
