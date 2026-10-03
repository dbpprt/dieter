# frozen_string_literal: true

require_relative "framework"
require_relative "../fixtures/gateway"
require_relative "../pipeline/contract"

module Dieter
  class Mac
    def initialize(context, actions: nil)
      @context, @root, @actions = context, context.root, actions
      @framework = SharedFramework.new(context)
      @contract = Contract.new(context)
    end

    def unit(options)
      @context.lease("apple-build")
      @framework.build
      swift_test(options.fetch("filter", ""))
    end

    def core_test(options = {})
      @context.lease("apple-build")
      @framework.build
      fixture = GatewayFixture.new(@context, "core", @context.private_dir, direct: true)
      values = fixture.start
      @context.cleanup { fixture.close }
      swift_test(options.fetch("filter", "SharedCoreIntegrationTests|AppSessionCoreIntegrationTests"), values)
    end

    def build(options)
      @context.lease("apple-build")
      assert_stopped
      @context.command(["bash", "apps/mac/scripts/sync-proto.sh"], timeout: 120)
      configuration = options.fetch("configuration", "debug")
      @framework.build(configuration: configuration)
      scratch = File.join(@root, "apps/mac/.build/dieter-local")
      argv = ["swift", "build", "--package-path", "apps/mac", "--scratch-path", scratch, "--only-use-versions-from-resolved-file", "--manifest-cache", "local", "--disable-index-store", "--product", "DieterMac", "-c", configuration, *jobs]
      @context.command(argv, timeout: 2400, log: File.join(@context.output, "build.log"))
      assert_stopped
      @context.command(["python3", "-c", "import os,sys; from pathlib import Path; from fastlane.lib.dieter.native.mac_bundle import package,signing_identity; package(Path(sys.argv[1]), Path(sys.argv[2]), signing_identity(dict(os.environ)), os.environ.get('DIETER_RELEASE_VERSION',''))", @root, File.join(scratch, configuration)], timeout: 300)
      source = @context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip
      bundle = File.join(@root, "apps/mac/build/Dieter.app")
      artifacts = ArtifactSet.new(component: "mac", source: source, configuration: configuration, products: {"app" => bundle})
      artifacts.write(File.join(@context.output, "artifacts.json"))
      bundle
    end

    def assert_stopped
      process = @context.start(["pgrep", "-x", "DieterMac"])
      output = process.wait(timeout: 15, check: false)
      raise Unavailable, "DieterMac already running (PIDs #{output.strip}); preserving the operator app" unless process.status.exitstatus == 1 && output.strip.empty?
    end

    def screens_native_test
      raise Unavailable, "Native Apple capture requires macOS" unless RUBY_PLATFORM.include?("darwin")
      @context.lease("apple-build")
      @context.lease("mac-desktop")
      assert_stopped
      helper = File.join(@context.private_dir, "dieter-capture")
      binary = File.join(@context.private_dir, "input-state")
      @context.command(["bash", "native/macos-capture/build.sh", helper], timeout: 300)
      sources = Dir.glob(File.join(@root, "native/macos-capture/*.swift")).sort
      @context.command(["xcrun", "swiftc", "-parse-as-library", "-O", "-D", "DIETER_CAPTURE_TEST", "-framework", "AppKit", "-framework", "ScreenCaptureKit", "-framework", "VideoToolbox", *sources, "apps/mac/Sources/DieterTransport/RemoteDesktopKeyMap.swift", "apps/mac/Sources/DieterTransport/ScreenClipboardContent.swift", "native/macos-capture/tests/InputState.swift", "-o", binary], timeout: 300)
      @context.command([binary], timeout: 120, log: File.join(@context.output, "input-state.log"))
      @context.command(["go", "test", "-race", "./internal/remotedesktop"], environment: {"DIETER_TEST_CAPTURE_HELPER" => helper}, timeout: 1200, log: File.join(@context.output, "capture-tests.log"))
    end

    def screens_test
      @context.lease("apple-build")
      @context.lease("mac-desktop")
      assert_stopped
      helper, fixture, bundle = ScreenFixture.tools(@context, @context.private_dir, input: true)
      environment = {"DIETER_TEST_CAPTURE_HELPER" => helper, "DIETER_TEST_SCREEN_FIXTURE" => fixture, "DIETER_TEST_INPUT_TARGET" => bundle}
      filter = if ENV["DIETER_TEST_SCREEN_UNDOCK"] == "1"
                 "remoteDesktopUndockedEndToEnd"
               elsif ENV["DIETER_TEST_SCREEN_RECOVERY"] == "1"
                 "remoteDesktopRecoveryAuthenticatedTransport"
               elsif ENV["DIETER_TEST_SCREEN_LATENCY_ONLY"] == "1"
                 "remoteDesktopNativeEndToEnd"
               else "remoteDesktop"
               end
      matrix = [{"DIETER_TEST_SCREEN_CODEC" => ENV.fetch("DIETER_TEST_SCREEN_CODEC", "h264")}]
      if ENV["DIETER_TEST_SCREEN_LATENCY_MATRIX"] == "1"
        presentations = ENV.fetch("DIETER_TEST_SCREEN_PRESENTATIONS", "immediate display-link").split
        raise PipelineError, "Invalid presentation modes" unless !presentations.empty? && (presentations - %w[immediate display-link bounded low-latency]).empty?
        matrix = %w[h264 hevc].product(presentations, %w[0 1]).map { |codec, mode, bitrate| {"DIETER_TEST_SCREEN_CODEC" => codec, "DIETER_SCREEN_PRESENTATION" => mode, "DIETER_SCREEN_FAST_BITRATE" => bitrate, "DIETER_TEST_SCREEN_LATENCY_ONLY" => "1"} }
        filter = "remoteDesktopNativeEndToEnd"
      end
      @framework.build
      matrix.each { |values| swift_test(filter, environment.merge(values)) }
    end

    def screens_hevc_test
      @context.lease("apple-build")
      @context.lease("mac-desktop")
      assert_stopped
      helper, fixture, = ScreenFixture.tools(@context, @context.private_dir, input: false)
      environment = {"DIETER_TEST_CAPTURE_HELPER" => helper, "DIETER_TEST_SCREEN_FIXTURE" => fixture, "DIETER_TEST_HEVC_FRAMES" => File.join(@context.private_dir, "frames.bin")}
      @context.command(["go", "test", "-race", "./internal/remotedesktop", "-run", "TestHEVC|TestCapturePoolKeepsCodecs|TestNativeHelperHEVCRoundTrip|TestNativeHEVCAndH264", "-count=1", "-v"], environment: environment, timeout: 1200, log: File.join(@context.output, "hevc-native.log"))
      @framework.build
      swift_test("remoteDesktopHEVC", environment)
    end

    def admit(target, _plan)
      raise Unavailable, "Mac execution requires macOS" unless RUBY_PLATFORM.include?("darwin")
      @context.lease("mac-desktop")
      assert_stopped
      user = @context.command(["stat", "-f", "%Su", "/dev/console"], timeout: 15).strip
      raise Unavailable, "Mac execution requires a logged-in desktop" if %w[root loginwindow].include?(user) || user.empty?
      @context.lease("apple-build")
    end

    def prepare(_target, _plan)
      @bundle = build({})
      GatewayFixture.compile(@context)
    end

    def execute_case(_target, test_case)
      started = monotonic
      evidence = File.join(@context.output, test_case.fetch("id"))
      FileUtils.mkdir_p(evidence, mode: 0o700)
      state = Dir.mktmpdir("mac-case-", @context.private_dir)
      preferences = "com.dbpprt.dieter.e2e.#{Digest::SHA256.hexdigest(state)}"
      fixture, app = nil, nil
      result = {"status" => "failed", "reason" => "", "setupMs" => 0, "executionMs" => 0}
      begin
        assert_stopped
        suite = test_case.dig("native", "suite") || "flow"
        base = ["--dieter-state-root", File.join(state, "client"), "--appearance-defaults-suite", preferences]
        if test_case.fetch("fixture") == "gateway"
          fixture = GatewayFixture.new(@context, suite, state, evidence: evidence)
          values = fixture.start
          token = File.join(state, "session-token")
          Atomic.write(token, values.fetch("DIETER_ISOLATED_TOKEN"))
          base += ["--dieter-endpoint", "http://#{values.fetch('DIETER_ISOLATED_ADDR')}", "--dieter-access-token-file", token, "--ui-smoke-fixture-root", File.join(state, "gateway"), "--ui-smoke-fixture-daemon", values.fetch("DIETER_ISOLATED_DAEMON")]
        end
        @context.command(["defaults", "write", preferences, "DieterAppearance", "-string", "dark"], timeout: 15) if suite == "island"
        if test_case["native"]
          phases = @contract.call("mac-phases", {suite: suite, output: evidence, target: preferences})
        else
          plan = File.join(state, "plan.json")
          Atomic.json(plan, {version: 1, case: test_case})
          phases = [{"name" => "flow", "report" => "report.json", "argv" => ["--flow-ui-smoke", "--e2e-plan", plan, "--ui-smoke-output", evidence]}]
        end
        result["setupMs"] = ((monotonic - started) * 1000).round
        began = monotonic
        results = {}
        phases.each do |phase|
          if suite == "terminal" && phase.fetch("name") == "resume"
            trigger = File.join(evidence, "daemon-restart")
            Atomic.write(trigger, "")
            await_file(fixture.process, trigger + ".ready", timeout: 15)
          end
          assert_stopped
          path = File.join(evidence, phase.fetch("report"))
          FileUtils.mkdir_p(File.dirname(path))
          activation = File.join(evidence, "activation-#{phase.fetch('name')}.pid")
          executable = File.join(@bundle, "Contents/MacOS/DieterMac")
          app = @context.start([executable, *base, "--e2e-activation-ready", activation, *phase.fetch("argv")], log: File.join(evidence, "app-#{phase.fetch('name')}.log"))
          await_file(app, activation, timeout: 20)
          raise PipelineError, "Activation PID does not match owned app" unless File.read(activation).strip == app.pid.to_s
          actual = @context.command(["pgrep", "-x", "DieterMac"], timeout: 10).strip
          raise PipelineError, "Activation requires exactly the owned app" unless actual == app.pid.to_s
          @context.command(["open", @bundle], timeout: 15)
          await_file(app, path, timeout: 1200)
          raise PipelineError, "Invalid or oversized Mac report" if File.symlink?(path) || File.size(path) > 1024 * 1024
          phase_results = JSON.parse(File.read(path))
          app.wait(timeout: 5) # A failing app cannot override passing report fragments.
          app = nil
          phase_results.each { |key, value| results["#{phase.fetch('name')}.#{key}"] = value }
        end
        result["executionMs"] = ((monotonic - began) * 1000).round
        report = File.join(evidence, "qualified-checks.json")
        Atomic.json(report, results)
        required = test_case.dig("native", "checks") || test_case.fetch("steps").each_index.map { |index| "flow.step-#{index}" }
        qualified_case = test_case.merge("native" => {"checks" => required})
        result.merge!(@contract.call("qualify", {platform: "mac", path: report, case: qualified_case}))
      rescue StandardError => error
        result["status"] = error.is_a?(Unavailable) ? "unavailable" : error.is_a?(Interrupted) ? "interrupted" : "failed"
        result["reason"] = error.message
      ensure
        problems = []
        @context.during_cleanup do
          [app, fixture].compact.each do |process|
            process.respond_to?(:stop) ? process.stop : process.close
          rescue StandardError => error
            problems << error.message
          end
          @context.command(["defaults", "delete", preferences], timeout: 15, check: false)
          FileUtils.remove_entry_secure(state) if problems.empty?
        end
        result["cleanupError"] = problems.join("; ")
      end
      result
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def await_file(process, path, timeout:)
      deadline = monotonic + @context.remaining(timeout)
      progress = monotonic + 30
      loop do
        return if File.file?(path)
        # Check the atomically published file again after observing app exit.
        raise PipelineError, "Owned process exited before #{File.basename(path)}" if !process.running? && !File.file?(path)
        raise Interrupted, "Deadline waiting for #{File.basename(path)}" if monotonic >= deadline
        if monotonic >= progress
          puts "Waiting for native #{File.basename(path)}; deadline in #{(deadline - monotonic).round}s"
          progress = monotonic + 30
        end
        sleep 0.1
      end
    end

    def jobs
      value = @context.environment["DIETER_SWIFT_JOBS"] || ENV["DIETER_SWIFT_JOBS"]
      value ? ["--jobs", value] : []
    end

    def swift_test(filter, extra_environment = {})
      argv = ["swift", "test", "--package-path", "apps/mac", "--scratch-path", File.join(@root, "apps/mac/.build/dieter-tests"), "--only-use-versions-from-resolved-file", "--manifest-cache", "local", "--disable-index-store", "--no-parallel", *jobs]
      argv += ["--filter", filter] unless filter.empty?
      @context.command(argv, environment: extra_environment, timeout: 3600, log: File.join(@context.output, "unit.log"))
    end
  end
end
