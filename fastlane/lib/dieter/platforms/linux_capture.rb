# frozen_string_literal: true

module Dieter
  class LinuxCapture
    MATRIX = %w[LinuxNativeHelperCapabilities LinuxNativeStartupAllowsPortalConsentDelay NativeHelperBaselineUsesLowLatencyHardware NativeHelperHardwareLifecycle NativeHelperKeepsInputResponsiveUnderMediaBackpressure NativeHelperWatchdogExitsWithoutDaemonHeartbeat NativeMultiplexSharesEncoderAndIsolatesRenditions NativeFourIndependentHardwareRenditions NativeCancelledLifecyclePreservesExistingViewer NativeConfigurationAndSlowEventsPreserveHeartbeat NativeDelayedHeartbeatReplyPreservesActiveCapture NativeHelperShutdownDuringFrameCreditsIsRecoverable NativeHelperHighRefreshHardware].freeze

    def initialize(context) = @context = context

    def test
      raise Unavailable, "Linux capture requires a Linux host" unless RUBY_PLATFORM.include?("linux")
      helper = File.join(@context.private_dir, "dieter-capture")
      target = File.join(@context.private_dir, "x11-test-target")
      @context.command(["bash", "native/linux-capture/build.sh", helper], timeout: 300)
      flags = @context.command(["pkg-config", "--cflags", "--libs", "x11"], timeout: 30)
      @context.command(["cc", "-std=c17", "-O2", "-Wall", "-Wextra", "-Werror", "native/linux-capture/x11-test-target.c", *Shellwords.split(flags), "-o", target], timeout: 120)
      JSON.parse(@context.command([helper, "--capabilities", "--synthetic", "true"], timeout: 30))
      environment = {"DIETER_TEST_CAPTURE_HELPER" => helper}
      pattern = "^(#{MATRIX.map { |name| 'Test' + name }.join('|')})$"
      @context.command(["go", "test", "./internal/remotedesktop", "-count=1", "-run", pattern], environment: environment, timeout: 600, log: File.join(@context.output, "capture-tests.log"))
      # Xvfb allocates a free display atomically and returns it on the pipe.
      xvfb = @context.start(["Xvfb", "-displayfd", "1", "-screen", "0", "1024x768x24", "-nolisten", "tcp", "-ac"], log: File.join(@context.output, "xvfb.log"))
      @context.cleanup { xvfb.stop }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      display = nil
      until display
        output = xvfb.stdout.strip
        display = ":#{output}" if output.match?(/\A\d+\z/)
        raise Unavailable, "Owned Xvfb did not become ready" if !xvfb.running? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1 unless display
      end
      @context.command(["go", "test", "./internal/remotedesktop", "-count=1", "-run", "^TestLinuxNativeX11CaptureAndControl$"], environment: environment.merge("DISPLAY" => display, "XDG_SESSION_TYPE" => "x11", "XAUTHORITY" => "", "DIETER_TEST_X11_TARGET" => target), timeout: 300, log: File.join(@context.output, "x11-tests.log"))
    end
  end
end
