# frozen_string_literal: true

module Dieter
  class ScreenFixture
    def self.supported_host? = RUBY_PLATFORM.include?("darwin")

    def self.admit(context, input: false)
      raise Unavailable, "Screen fixtures require macOS" unless supported_host?
      context.lease("apple-build")
      if input
        context.lease("mac-desktop")
        assert_stopped(context)
      end
    end

    def self.assert_stopped(context)
      process = context.start(%w[pgrep -x DieterMac])
      output = process.wait(timeout: 15, check: false)
      unless process.status.exitstatus == 1 && output.strip.empty?
        raise Unavailable,
              "DieterMac already running (PIDs #{output.strip}); preserving the operator app"
      end
    end

    def self.tools(context, state, input: false)
      admit(context, input: input)
      helper = File.join(state, "dieter-capture")
      fixture = File.join(state, "screens-fixture")
      context.command(["bash", "native/macos-capture/build.sh", helper], timeout: 300)
      context.command(["go", "build", "-o", fixture, "./tools/fixtures/screens"], timeout: 300)
      return helper, fixture unless input
      bundle = File.join(state, "InputTarget.app")
      executable = File.join(bundle, "Contents/MacOS/InputTarget")
      FileUtils.mkdir_p(File.dirname(executable))
      Atomic.write(
        File.join(bundle, "Contents/Info.plist"),
        '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>InputTarget</string><key>CFBundleIdentifier</key><string>com.dbpprt.dieter.screen-input-fixture</string><key>CFBundleName</key><string>Dieter Input Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>'
      )
      context.command(
        [
          "xcrun",
          "swiftc",
          "-parse-as-library",
          "-O",
          "-framework",
          "AppKit",
          "native/macos-capture/tests/InputTarget.swift",
          "-o",
          executable
        ],
        timeout: 120
      )
      context.command(["codesign", "--force", "--sign", "-", bundle], timeout: 30)
      [helper, fixture, bundle]
    end
  end
end
