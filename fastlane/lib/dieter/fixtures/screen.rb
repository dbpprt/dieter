# frozen_string_literal: true

require "base64"
require "uri"

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
      process = context.start(["pgrep", "-x", "DieterMac"])
      output = process.wait(timeout: 15, check: false)
      raise Unavailable, "DieterMac already running (PIDs #{output.strip}); preserving the operator app" unless process.status.exitstatus == 1 && output.strip.empty?
    end

    def self.tools(context, state, input: false)
      admit(context, input: input)
      helper = File.join(state, "dieter-capture")
      fixture = File.join(state, "screens-fixture")
      context.command(["bash", "native/macos-capture/build.sh", helper], timeout: 300)
      context.command(["go", "build", "-o", fixture, "./tools/fixtures/screens"], timeout: 300)
      return [helper, fixture] unless input
      bundle = File.join(state, "InputTarget.app")
      executable = File.join(bundle, "Contents/MacOS/InputTarget")
      FileUtils.mkdir_p(File.dirname(executable))
      Atomic.write(File.join(bundle, "Contents/Info.plist"), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>InputTarget</string><key>CFBundleIdentifier</key><string>com.dbpprt.dieter.screen-input-fixture</string><key>CFBundleName</key><string>Dieter Input Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>')
      context.command(["xcrun", "swiftc", "-parse-as-library", "-O", "-framework", "AppKit", "native/macos-capture/tests/InputTarget.swift", "-o", executable], timeout: 120)
      context.command(["codesign", "--force", "--sign", "-", bundle], timeout: 30)
      [helper, fixture, bundle]
    end

    def initialize(context, state, evidence, native_only: false)
      @context, @state, @evidence, @native_only = context, state, evidence, native_only
      @processes = []
    end

    def start
      raise Unavailable, "Screen tests require a qualified macOS capture host" unless RUBY_PLATFORM.include?("darwin")
      source = @native_only ? "native-synthetic" : ENV.fetch("DIETER_SCREEN_TEST_SOURCE", "native-synthetic")
      raise PipelineError, "Unknown screen source" unless %w[native-synthetic screen].include?(source)
      helper, fixture_binary, bundle = self.class.tools(@context, @state, input: !@native_only)
      ready_file = File.join(@state, "screen-ready.json")
      fixture = @context.start([fixture_binary, "--helper", helper, "--source", source, "--authenticate", "--ready", ready_file])
      @processes << fixture
      ready = wait_json(fixture, ready_file)
      token = ready.fetch("token")
      raise PipelineError, "Screen fixture missing token" unless token.is_a?(String) && !token.empty?
      @context.secrets << token
      values = {"screenToken" => token}
      if @native_only
        values["screenFixture"] = Base64.strict_encode64(JSON.generate(ready))
        @context.secrets << values["screenFixture"]
        return [values, nil]
      end
      executable = File.join(bundle, "Contents/MacOS/InputTarget")
      input_file = File.join(@state, "input.json")
      input = @context.start([executable, input_file, Process.pid.to_s, ready.fetch("clipboardName")])
      @processes << input
      # AppKit publishes its first window position before activation settles.
      # Admit only a focused report from the exact owned process.
      position = wait_json(input, input_file) { |value| value["active"] == true && value["pid"] == input.pid }
      port = URI.parse(ready.fetch("url")).port.to_s
      ready.merge!("port" => port.to_i, "real" => source == "screen", "multi" => false, "targetX" => position.fetch("x"), "targetY" => position.fetch("y"))
      values["screenFixture"] = Base64.strict_encode64(JSON.generate(ready))
      @context.secrets << values["screenFixture"]
      {"screenLowLatency" => "DIETER_SCREEN_TEST_LOW_LATENCY", "screenSurface" => "DIETER_SCREEN_TEST_SURFACE", "screenDirectSurface" => "DIETER_SCREEN_TEST_DIRECT_SURFACE", "forceTURN" => "DIETER_TEST_FORCE_TURN"}.each do |key, variable|
        value = ENV.fetch(variable, key == "screenLowLatency" ? "1" : "0")
        raise PipelineError, "Invalid #{variable}" unless %w[0 1].include?(value)
        values[key] = value
      end
      [values, port]
    end

    def close
      problems = []
      @processes.reverse_each.with_index do |process, index|
        process.stop
        Atomic.write(File.join(@evidence, "screen-process-#{index}.log"), process.output)
      rescue StandardError => error
        problems << error.message
      end
      input = File.join(@state, "input.json")
      FileUtils.cp(input, File.join(@evidence, "input.json")) if File.file?(input)
      raise CleanupError, problems.join("; ") unless problems.empty?
    end

    private

    def wait_json(process, path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      loop do
        if File.file?(path) && File.size(path) <= 256 * 1024
          value = JSON.parse(File.read(path))
          return value unless block_given?
          return value if yield(value)
        end
        raise PipelineError, "Screen fixture exited before readiness" unless process.running?
        raise Interrupted, "Screen fixture readiness exceeded 60s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
    end
  end
end
