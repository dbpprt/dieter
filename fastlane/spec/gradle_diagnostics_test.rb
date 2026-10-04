# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/dieter/pipeline/gradle_diagnostics"

class HostedGradleDiagnosticsTest < Minitest::Test
  Context = Struct.new(:root, :output, :environment, :commands) do
    def with_deadline(seconds)
      raise "Unbounded diagnostics" unless seconds <= 90
      yield
    end

    def command(argv, **options)
      commands << [argv, options]
      return "11 org.gradle.launcher.daemon.bootstrap.GradleDaemon\n12 unrelated.App\n13 org.jetbrains.kotlin.daemon.KotlinCompileDaemon\n14 org.gradle.launcher.daemon.bootstrap.GradleDaemon extra-argument\n" if argv.last == "-l"
      "diagnostic"
    end
  end

  def setup
    @directory = Dir.mktmpdir("gradle-diagnostics-")
    @context = Context.new(@directory, @directory, {"JAVA_HOME" => "/fake-jdk"}, [])
    @original = %w[GITHUB_ACTIONS RUNNER_ENVIRONMENT].to_h { |key| [key, ENV[key]] }
    ENV["GITHUB_ACTIONS"], ENV["RUNNER_ENVIRONMENT"] = "true", "github-hosted"
  end

  def teardown
    @original.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.remove_entry_secure(@directory)
  end

  def test_capture_uses_only_exact_gradle_daemons_and_omits_process_arguments
    observer = Dieter::HostedGradleDiagnostics.new(@context, "performance")
    observer.capture
    commands = @context.commands.map(&:first)
    assert_includes commands, ["/fake-jdk/bin/jcmd", "11", "Thread.print"]
    assert_includes commands, ["/fake-jdk/bin/jcmd", "11", "GC.heap_info"]
    assert_equal 2, commands.count { |command| command.first.end_with?("/jcmd") }
    refute commands.any? { |command| command.include?("args") || command.include?("-v") }
    assert @context.commands.all? { |_argv, options| options.fetch(:timeout) <= 30 }
  end

  def test_only_two_quiet_snapshots_and_new_output_resets_the_clock
    observer = Dieter::HostedGradleDiagnostics.new(@context, "performance")
    now, captures = 0, []
    observer.define_singleton_method(:monotonic) { now }
    observer.define_singleton_method(:capture) { captures << now }
    process = Struct.new(:output).new("compiling")
    observer.progress(process)
    now = 299
    observer.progress(process)
    assert_empty captures
    now = 300
    observer.progress(process)
    assert_equal [300], captures
    now, process.output = 350, "packaging"
    observer.progress(process)
    now = 949
    observer.progress(process)
    assert_equal [300], captures
    now = 950
    observer.progress(process)
    now = 5000
    observer.progress(process)
    assert_equal [300, 950], captures
  end

  def test_local_and_self_hosted_runs_do_not_inspect_java_processes
    observer = Dieter::HostedGradleDiagnostics.new(@context, "performance")
    observer.define_singleton_method(:capture) { flunk "inspected operator JVMs" }
    process = Struct.new(:output).new("")
    ENV["RUNNER_ENVIRONMENT"] = "self-hosted"
    observer.progress(process)
    ENV["GITHUB_ACTIONS"] = "false"
    ENV["RUNNER_ENVIRONMENT"] = "github-hosted"
    observer.progress(process)
    assert_empty @context.commands
  end

  def test_diagnostic_failure_preserves_command_result_without_leaking_error_text
    observer = Dieter::HostedGradleDiagnostics.new(@context, "performance")
    now = 0
    observer.define_singleton_method(:monotonic) { now }
    observer.define_singleton_method(:capture) { raise "secret diagnostic failure" }
    process = Struct.new(:output).new("")
    observer.progress(process)
    now = 300
    observer.progress(process)
    assert_equal "RuntimeError", File.read(File.join(@directory, "performance-diagnostic-error.txt"))
  end
end
