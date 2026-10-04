# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/screens"

class ScreenScenarioSafetyTest < Minitest::Test
  def test_interruption_stops_before_another_fixture_and_keeps_failure_and_cleanup
    Dir.mktmpdir("screen-interruption-") do |directory|
      manifest = File.join(directory, "manifest.json")
      scenarios = %w[first second].map { |id| {"id" => id, "runner" => "native"} }
      File.write(manifest, JSON.generate({"schemaVersion" => 1, "id" => "cancel", "required" => %w[first second], "cases" => scenarios}))
      context = Struct.new(:root, :output).new(directory, directory)
      context.define_singleton_method(:command) { |*, **| "fixture" }
      closed = false
      context.define_singleton_method(:close) { closed = true }
      calls = []
      execute = lambda do |_, scenario, _|
        calls << scenario.fetch("id")
        {"id" => scenario.fetch("id"), "status" => "interrupted", "reason" => "swift canceled", "artifacts" => []}
      end
      Dieter::Config.stub(:new, Object.new) do
        Dieter::RunContext.stub(:new, context) do
          Dieter::Screens.stub(:fingerprint, "unchanged") do
            Dieter::Screens.stub(:run_case, execute) do
              error = assert_raises(Dieter::Interrupted) { Dieter::Screens.invoke({"manifest" => manifest}) }
              assert_equal "swift canceled", error.message
            end
          end
        end
      end
      assert_equal ["first"], calls
      assert closed
      report = JSON.parse(File.read(File.join(directory, "results.json")))
      assert_equal "failed", report.fetch("status")
      assert_equal ["second"], report.fetch("missingRequired")
      assert report.fetch("sourceUnchangedDuringRun")
      parent = Struct.new(:output).new(directory)
      Dieter::Runtime.stub(:invoke, ->(*) { raise Dieter::Interrupted, "native canceled" }) do
        result = Dieter::Screens.run_case(parent, {"id" => "android", "runner" => "android-codec"}, "exact-device")
        assert_equal "interrupted", result.fetch("status")
      end
    end
  end

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
