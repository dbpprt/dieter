# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/dieter/screens"

class ScreenScenarioSafetyTest < Minitest::Test
  def test_only_declared_scenarios_and_experiments_can_select_execution
    [{"runner" => "shell"}, {"runner" => "native", "switches" => {"DIETER_HOME" => "/live"}}, {"runner" => "native", "switches" => {"DIETER_SCREEN_OVERLAP" => 50}}, {"runner" => "mac-latency", "presentation" => "unknown"}, {"runner" => "android-codec", "directSurface" => "false"}].each do |scenario|
      assert_raises(Dieter::PipelineError) { Dieter::Screens.settings(scenario) }
    end
    settings = Dieter::Screens.settings({"runner" => "android-recovery", "directSurface" => true})
    assert_equal "1", settings.fetch("DIETER_SCREEN_TEST_DIRECT_SURFACE")
    assert_equal "0", settings.fetch("DIETER_SCREEN_TEST_SURFACE")
  end
end
