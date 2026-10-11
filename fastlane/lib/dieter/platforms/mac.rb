# frozen_string_literal: true

require_relative "framework"
require_relative "apple_build"
require "digest"
require_relative "../fixtures/gateway"
require_relative "../fixtures/screen"

module Dieter
  class Mac
    def initialize(context, actions: nil)
      @context, @root, @actions = context, context.root, actions
      @framework = SharedFramework.new(context)
    end

    def unit(options)
      @context.lease("apple-build")
      @framework.build
      swift_test(options.fetch("filter", ""))
    end

    def core_test(options = {})
      @context.lease("apple-build")
      @framework.build
      fixture = GatewayFixture.new(@context, @context.private_dir, direct: true)
      values = fixture.start
      @context.cleanup { fixture.close }
      swift_test(
        options.fetch("filter", "SharedCoreIntegrationTests|AppSessionCoreIntegrationTests"),
        values
      )
    end

    def build(options)
      @context.lease("apple-build")
      assert_stopped
      @context.command(%w[bash apps/mac/scripts/sync-proto.sh], timeout: 120)
      configuration = options.fetch("configuration", "debug")
      @framework.build(configuration: configuration)
      scratch = AppleBuild.mac_scratch(@context, operation: :build)
      argv = [
        "swift",
        "build",
        "--package-path",
        "apps/mac",
        "--scratch-path",
        scratch,
        "--only-use-versions-from-resolved-file",
        "--manifest-cache",
        "local",
        "--disable-index-store",
        "--product",
        "DieterMac",
        "-c",
        configuration,
        *jobs
      ]
      @context.command(argv, timeout: 2400, log: File.join(@context.output, "build.log"))
      assert_stopped
      @context.command(
        [
          "python3",
          "-c",
          "import os,sys; from pathlib import Path; from fastlane.lib.dieter.native.mac_bundle import package,signing_identity; package(Path(sys.argv[1]), Path(sys.argv[2]), signing_identity(dict(os.environ)), os.environ.get('DIETER_RELEASE_VERSION',''))",
          @root,
          File.join(scratch, configuration)
        ],
        timeout: 300
      )
      source = @context.command(%w[git rev-parse HEAD], timeout: 30).strip
      bundle = File.join(@root, "apps/mac/build/Dieter.app")
      artifacts =
        ArtifactSet.new(
          component: "mac",
          source: source,
          configuration: configuration,
          products: {
            "app" => bundle
          }
        )
      artifacts.write(File.join(@context.output, "artifacts.json"))
      bundle
    end

    def assert_stopped
      ScreenFixture.assert_stopped(@context)
    end

    def screens_virtual_test
      unless RUBY_PLATFORM.include?("darwin")
        raise Unavailable, "Virtual display qualification requires macOS"
      end
      @context.lease("apple-build")
      if ENV["DIETER_TEST_VIRTUAL_HARDWARE"] == "1"
        @context.lease("mac-desktop")
        assert_stopped
      end
      helper = File.join(@context.private_dir, "dieter-capture")
      @context.command(["bash", "native/macos-capture/build.sh", helper], timeout: 300)
      @context.command(
        %w[go test -race ./internal/remotedesktop -run TestNativeVirtualDisplay -count=1 -v],
        environment: {
          "DIETER_TEST_CAPTURE_HELPER" => helper,
          "DIETER_TEST_VIRTUAL_STATE_ROOT" => File.join(@context.output, "virtual-display-state")
        },
        timeout: 180,
        log: File.join(@context.output, "virtual-display-tests.log")
      )
    end

    def screens_native_test
      unless RUBY_PLATFORM.include?("darwin")
        raise Unavailable, "Native Apple capture requires macOS"
      end
      @context.lease("apple-build")
      @context.lease("mac-desktop")
      assert_stopped
      helper = File.join(@context.private_dir, "dieter-capture")
      binary = File.join(@context.private_dir, "input-state")
      @context.command(["bash", "native/macos-capture/build.sh", helper], timeout: 300)
      bridge = File.join(@context.private_dir, "virtual-display-bridge.o")
      @context.command(
        [
          "xcrun",
          "clang",
          "-fobjc-arc",
          "-target",
          "arm64-apple-macos15.0",
          "-c",
          "native/macos-capture/VirtualDisplayBridge.m",
          "-o",
          bridge
        ],
        timeout: 60
      )
      sources = Dir.glob(File.join(@root, "native/macos-capture/*.swift")).sort
      @context.command(
        [
          "xcrun",
          "swiftc",
          "-parse-as-library",
          "-O",
          "-D",
          "DIETER_CAPTURE_TEST",
          "-import-objc-header",
          "native/macos-capture/VirtualDisplayBridge.h",
          bridge,
          "-framework",
          "AppKit",
          "-framework",
          "IOKit",
          "-framework",
          "Security",
          "-framework",
          "ServiceManagement",
          "-framework",
          "SystemConfiguration",
          "-framework",
          "ScreenCaptureKit",
          "-framework",
          "VideoToolbox",
          *sources,
          "apps/mac/Sources/DieterTransport/RemoteDesktopKeyMap.swift",
          "apps/mac/Sources/DieterTransport/ScreenClipboardContent.swift",
          "native/macos-capture/tests/InputState.swift",
          "-o",
          binary
        ],
        timeout: 300
      )
      @context.command([binary], timeout: 120, log: File.join(@context.output, "input-state.log"))
      privacy_hid_tests
      @context.command(
        %w[go test -race ./internal/remotedesktop],
        environment: {
          "DIETER_TEST_CAPTURE_HELPER" => helper
        },
        timeout: 1200,
        log: File.join(@context.output, "capture-tests.log")
      )
    end

    # This package/IPC gate uses synthetic pixels and isolated state. It needs
    # a compiler lease, but never owns or changes the operator's desktop.
    def privacy_native_test
      unless RUBY_PLATFORM.include?("darwin")
        raise Unavailable, "Native privacy packaging requires macOS"
      end
      @context.lease("apple-build")
      stage = File.join(@context.private_dir, "privacy-package")
      FileUtils.mkdir_p(stage)
      @context.command(
        ["go", "build", "-o", File.join(stage, "dieter"), "./cmd/dieter"],
        timeout: 600
      )
      @context.command(
        [
          "codesign",
          "--force",
          "--identifier",
          "com.dbpprt.dieter.daemon",
          "--sign",
          "-",
          File.join(stage, "dieter")
        ],
        timeout: 120
      )
      helper = File.join(stage, "dieter-capture")
      @context.command(["bash", "native/macos-capture/build.sh", helper], timeout: 300)
      @context.command(
        ["codesign", "--force", "--identifier", "com.dbpprt.dieter.capture", "--sign", "-", helper],
        timeout: 120
      )
      @context.command(["bash", "native/macos-privacy/package.sh", stage], timeout: 300)
      privacy_hid_tests
      @context.command(
        %w[
          go
          test
          -race
          ./internal/serviceruntime
          -run
          ^TestNativePrivacyPackageSmoke$
          -count=1
          -v
        ],
        environment: {
          "DIETER_TEST_PRIVACY_PACKAGE" => stage
        },
        timeout: 300,
        log: File.join(@context.output, "privacy-package.log")
      )
      @context.command(
        %w[go test -race ./internal/remotedesktop -run Privacy -count=1 -v],
        environment: {
          "DIETER_TEST_CAPTURE_HELPER" => helper
        },
        timeout: 300,
        log: File.join(@context.output, "privacy-capture.log")
      )
      release_stage = File.join(@context.private_dir, "privacy-release-package")
      FileUtils.mkdir_p(release_stage)
      %w[dieter dieter-capture].each { |name| FileUtils.cp(File.join(stage, name), release_stage) }
      @context.command(
        ["bash", "native/macos-privacy/package.sh", release_stage],
        environment: {
          "DIETER_PRIVACY_RELEASE" => "1"
        },
        timeout: 300
      )
      @context.command(
        %w[
          go
          test
          -race
          ./internal/serviceruntime
          -run
          ^TestNativePrivacyPackageSmoke$
          -count=1
          -v
        ],
        environment: {
          "DIETER_TEST_PRIVACY_PACKAGE" => release_stage,
          "DIETER_TEST_PRIVACY_RELEASE" => "1"
        },
        timeout: 300,
        log: File.join(@context.output, "privacy-release-package.log")
      )
    end

    def privacy_hid_tests
      hid_binary = File.join(@context.private_dir, "privacy-hid-tests")
      @context.command(
        [
          "xcrun",
          "swiftc",
          "-parse-as-library",
          "-O",
          "-D",
          "DIETER_PRIVACY_TEST",
          "-framework",
          "IOKit",
          "-framework",
          "Security",
          "-framework",
          "ServiceManagement",
          "-framework",
          "SystemConfiguration",
          "native/macos-privacy/PrivacyHIDProtection.swift",
          "native/macos-privacy/PrivacyHIDService.swift",
          "native/macos-capture/PrivacyHIDProtocol.swift",
          "native/macos-capture/PrivacyHelperPackage.swift",
          "native/macos-capture/tests/PrivacyHIDProtectionTests.swift",
          "-o",
          hid_binary
        ],
        timeout: 300
      )
      @context.command(
        [hid_binary],
        timeout: 120,
        log: File.join(@context.output, "privacy-hid-tests.log")
      )
    end

    def screens_test
      @context.lease("apple-build")
      @context.lease("mac-desktop")
      assert_stopped
      helper, fixture, bundle = ScreenFixture.tools(@context, @context.private_dir, input: true)
      environment = {
        "DIETER_TEST_CAPTURE_HELPER" => helper,
        "DIETER_TEST_SCREEN_FIXTURE" => fixture,
        "DIETER_TEST_INPUT_TARGET" => bundle,
        "DIETER_TEST_SCREEN_VIRTUAL_EVIDENCE" => File.join(@context.output, "virtual-viewer")
      }
      filter =
        if ENV["DIETER_TEST_SCREEN_VIRTUAL"] == "1"
          "remoteDesktopVirtualDisplayEndToEnd"
        elsif ENV["DIETER_TEST_SCREEN_UNDOCK"] == "1"
          "remoteDesktopUndockedEndToEnd"
        elsif ENV["DIETER_TEST_SCREEN_RECOVERY"] == "1"
          "remoteDesktopRecoveryAuthenticatedTransport"
        elsif ENV["DIETER_TEST_SCREEN_LATENCY_ONLY"] == "1"
          "remoteDesktopNativeEndToEnd"
        else
          "remoteDesktop"
        end
      matrix = [{ "DIETER_TEST_SCREEN_CODEC" => ENV.fetch("DIETER_TEST_SCREEN_CODEC", "h264") }]
      if ENV["DIETER_TEST_SCREEN_LATENCY_MATRIX"] == "1"
        presentations =
          ENV.fetch("DIETER_TEST_SCREEN_PRESENTATIONS", "immediate display-link").split
        unless !presentations.empty? &&
                 (presentations - %w[immediate display-link bounded low-latency]).empty?
          raise PipelineError, "Invalid presentation modes"
        end
        matrix =
          %w[h264 hevc]
            .product(presentations, %w[0 1])
            .map do |codec, mode, bitrate|
              {
                "DIETER_TEST_SCREEN_CODEC" => codec,
                "DIETER_SCREEN_PRESENTATION" => mode,
                "DIETER_SCREEN_FAST_BITRATE" => bitrate,
                "DIETER_TEST_SCREEN_LATENCY_ONLY" => "1"
              }
            end
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
      environment = {
        "DIETER_TEST_CAPTURE_HELPER" => helper,
        "DIETER_TEST_SCREEN_FIXTURE" => fixture,
        "DIETER_TEST_HEVC_FRAMES" => File.join(@context.private_dir, "frames.bin")
      }
      @context.command(
        %w[
          go
          test
          -race
          ./internal/remotedesktop
          -run
          TestHEVC|TestCapturePoolKeepsCodecs|TestNativeHelperHEVCRoundTrip|TestNativeHEVCAndH264
          -count=1
          -v
        ],
        environment: environment,
        timeout: 1200,
        log: File.join(@context.output, "hevc-native.log")
      )
      @framework.build
      swift_test("remoteDesktopHEVC", environment)
    end

    def admit
      raise Unavailable, "Mac execution requires macOS" unless RUBY_PLATFORM.include?("darwin")
      @context.lease("mac-desktop")
      assert_stopped
      user = @context.command(%w[stat -f %Su /dev/console], timeout: 15).strip
      if %w[root loginwindow].include?(user) || user.empty?
        raise Unavailable, "Mac execution requires a logged-in desktop"
      end
      @context.lease("apple-build")
    end

    # Runs one Maestro-syntax plan in a fresh debug app; the app interprets it
    # in-process, writes report.json and quits.
    def run_flow(bundle, plan, evidence, endpoint:, token:)
      FileUtils.mkdir_p(evidence, mode: 0o700)
      state = Dir.mktmpdir("mac-flow-", @context.private_dir)
      preferences = "com.dbpprt.dieter.e2e.#{Digest::SHA256.hexdigest(state)[0, 16]}"
      app = nil
      begin
        assert_stopped
        token_file = File.join(state, "session-token")
        Atomic.write(token_file, token)
        plan_file = File.join(state, "plan.json")
        Atomic.json(plan_file, plan)
        activation = File.join(evidence, "activation.pid")
        app =
          @context.start(
            [
              File.join(bundle, "Contents/MacOS/DieterMac"),
              "--dieter-state-root",
              File.join(state, "client"),
              "--appearance-defaults-suite",
              preferences,
              "--dieter-endpoint",
              endpoint,
              "--dieter-access-token-file",
              token_file,
              "--e2e-activation-ready",
              activation,
              "--e2e-flow",
              plan_file,
              "--e2e-output",
              evidence
            ],
            log: File.join(evidence, "app.log")
          )
        await_file(app, activation, timeout: 30)
        unless File.read(activation).strip == app.pid.to_s
          raise PipelineError, "Activation PID does not match owned app"
        end
        actual = @context.command(%w[pgrep -x DieterMac], timeout: 10).strip
        unless actual == app.pid.to_s
          raise PipelineError, "Activation requires exactly the owned app"
        end
        @context.command(["open", bundle], timeout: 15)
        report = File.join(evidence, "report.json")
        await_file(app, report, timeout: 300)
        if File.symlink?(report) || File.size(report) > 1024 * 1024
          raise PipelineError, "Invalid or oversized Mac report"
        end
        results = JSON.parse(File.read(report))
        app.wait(timeout: 15) # The app quits after publishing its report.
        app = nil
        results
      ensure
        @context.during_cleanup do
          app&.stop
          @context.command(["defaults", "delete", preferences], timeout: 15, check: false)
          FileUtils.remove_entry_secure(state)
        end
      end
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def await_file(process, path, timeout:)
      deadline = monotonic + @context.remaining(timeout)
      progress = monotonic + 30
      loop do
        return if File.file?(path)
        # Check the atomically published file again after observing app exit.
        if !process.running? && !File.file?(path)
          raise PipelineError, "Owned process exited before #{File.basename(path)}"
        end
        raise Interrupted, "Deadline waiting for #{File.basename(path)}" if monotonic >= deadline
        if monotonic >= progress
          puts "Waiting for native #{File.basename(path)}; deadline in #{(deadline - monotonic).round}s"
          progress = monotonic + 30
        end
        sleep 0.1
      end
    end

    def jobs
      AppleBuild.jobs(@context, tool: :swift)
    end

    def swift_test(filter, extra_environment = {})
      argv = [
        "swift",
        "test",
        "--package-path",
        "apps/mac",
        "--scratch-path",
        AppleBuild.mac_scratch(@context, operation: :test),
        "--only-use-versions-from-resolved-file",
        "--manifest-cache",
        "local",
        "--disable-index-store",
        "--no-parallel",
        *jobs
      ]
      argv += ["--filter", filter] unless filter.empty?
      @context.command(
        argv,
        environment: extra_environment,
        timeout: 3600,
        log: File.join(@context.output, "unit.log")
      )
    end
  end
end
