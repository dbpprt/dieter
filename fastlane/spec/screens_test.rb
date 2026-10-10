# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/screens"

class ScreenScenarioSafetyTest < Minitest::Test
  # Runs one case through the Mac adapter with a stubbed context and a runner
  # whose screen operation raises `error`; returns the result and the calls.
  def run_mac_case(parent, scenario, error)
    calls = []
    context = Struct.new(:environment).new({})
    context.define_singleton_method(:with_deadline) do |seconds, &block|
      calls << [:deadline, seconds]
      block.call
    end
    context.define_singleton_method(:close) { calls << :closed }
    mac = Object.new
    %i[screens_native_test screens_test].each do |name|
      mac.define_singleton_method(name) do
        calls << name
        raise error
      end
    end
    result =
      Dieter::RunContext.stub(:new, context) do
        Dieter::SourceIdentity.stub(:version, "0.0.0-spec") do
          Dieter::Mac.stub(:new, mac) { Dieter::Screens.run_case(parent, scenario) }
        end
      end
    assert_equal "0.0.0-spec", context.environment.fetch("DIETER_RELEASE_VERSION")
    [result, calls]
  end

  def test_interruption_stops_before_another_fixture_and_keeps_failure_and_cleanup
    Dir.mktmpdir("screen-interruption-") do |directory|
      manifest = File.join(directory, "manifest.json")
      scenarios = %w[first second].map { |id| { "id" => id, "runner" => "native" } }
      File.write(
        manifest,
        JSON.generate(
          {
            "schemaVersion" => 1,
            "id" => "cancel",
            "required" => %w[first second],
            "cases" => scenarios
          }
        )
      )
      context = Struct.new(:root, :output).new(directory, directory)
      context.define_singleton_method(:command) { |*, **| "fixture" }
      closed = false
      context.define_singleton_method(:close) { closed = true }
      calls = []
      execute =
        lambda do |_, scenario|
          calls << scenario.fetch("id")
          {
            "id" => scenario.fetch("id"),
            "status" => "interrupted",
            "reason" => "swift canceled",
            "artifacts" => []
          }
        end
      Dieter::Config.stub(:new, Object.new) do
        Dieter::RunContext.stub(:new, context) do
          Dieter::Screens.stub(:fingerprint, "unchanged") do
            Dieter::Screens.stub(:run_case, execute) do
              error =
                assert_raises(Dieter::Interrupted) do
                  Dieter::Screens.invoke({ "manifest" => manifest })
                end
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
      parent = Struct.new(:output, :config).new(directory, Object.new)
      result, mac_calls =
        run_mac_case(
          parent,
          { "id" => "native", "runner" => "native", "timeoutSeconds" => 60 },
          Dieter::Interrupted.new("native canceled")
        )
      assert_equal "interrupted", result.fetch("status")
      assert_equal "native canceled", result.fetch("reason")
      assert_equal [[:deadline, 60], :screens_native_test, :closed], mac_calls
    end
  end

  def test_failure_measurements_are_retained_without_overwriting_native_failure
    Dir.mktmpdir("screen-failure-") do |directory|
      parent = Struct.new(:output, :config).new(directory, Object.new)
      Dir.mkdir(File.join(directory, "fixture"))
      scenario = { "id" => "fixture", "runner" => "mac-latency" }
      failure = Dieter::PipelineError.new("native assertion failed")
      observed = {
        "status" => "passed",
        "reason" => "good average",
        "artifacts" => ["latency.json"],
        "metrics" => {
          "inputP95Ms" => 60
        }
      }
      Dieter::Screens.stub(:evidence, observed) do
        result, mac_calls = run_mac_case(parent, scenario, failure)
        assert_equal [[:deadline, 1800], :screens_test, :closed], mac_calls
        assert_equal "failed", result.fetch("status")
        assert_equal "native assertion failed", result.fetch("reason")
        assert_equal ["latency.json"], result.fetch("artifacts")
        assert_equal 60, result.dig("metrics", "inputP95Ms")
      end
      Dieter::Screens.stub(:evidence, ->(*) { raise "private diagnostic text" }) do
        result, = run_mac_case(parent, scenario, failure)
        assert_equal "failed", result.fetch("status")
        assert_equal "native assertion failed", result.fetch("reason")
        assert_equal "RuntimeError", result.fetch("diagnosticError")
        refute result.to_s.include?("private diagnostic text")
      end
    end
  end

  def test_only_declared_scenarios_and_experiments_can_select_execution
    [
      { "runner" => "shell" },
      { "runner" => "android-codec" },
      { "runner" => "native", "switches" => { "DIETER_HOME" => "/live" } },
      { "runner" => "native", "switches" => { "DIETER_SCREEN_OVERLAP" => 50 } },
      { "runner" => "mac-latency", "presentation" => "unknown" },
      { "runner" => "mac-recovery", "codec" => "vp9" }
    ].each do |scenario|
      assert_raises(Dieter::PipelineError) { Dieter::Screens.settings(scenario) }
    end
    settings =
      Dieter::Screens.settings(
        {
          "runner" => "mac-recovery",
          "codec" => "hevc",
          "switches" => {
            "DIETER_SCREEN_FEC" => 1
          }
        }
      )
    assert_equal "hevc", settings.fetch("DIETER_TEST_SCREEN_CODEC")
    assert_equal "1", settings.fetch("DIETER_TEST_SCREEN_RECOVERY")
    assert_equal "1", settings.fetch("DIETER_SCREEN_FEC")
    refute settings.key?("DIETER_TEST_SCREEN_LATENCY_ONLY")
    assert_raises(Dieter::PipelineError) do
      Dieter::Screens.invoke({ "manifest" => "unused.json", "profile" => "android-device" })
    end
  end
end
