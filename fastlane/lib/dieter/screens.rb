# frozen_string_literal: true

require_relative "runtime"

module Dieter
  # Specialized measurement scenarios compose the same adapters as app tests.
  # Evidence validation stays separate from execution and never promotes defaults.
  module Screens
    SWITCHES = %w[DIETER_SCREEN_CONTENT_ADAPTATION DIETER_SCREEN_OVERLAP DIETER_SCREEN_ENCODER_BURST_MS DIETER_SCREEN_FEC DIETER_SCREEN_LTR DIETER_SCREEN_FAST_BITRATE].freeze
    RUNNERS = %w[native mac-latency mac-recovery mac-journey android-codec android-journey android-recovery android-sdk external].freeze

    def self.settings(scenario)
      runner = scenario.fetch("runner")
      raise PipelineError, "Unknown screen runner" unless RUNNERS.include?(runner)
      values = {}
      if runner.start_with?("mac-")
        raise PipelineError, "Invalid screen codec/capture/presentation" unless %w[h264 hevc].include?(scenario.fetch("codec", "h264")) && %w[synthetic screen].include?(scenario.fetch("capture", "synthetic")) && %w[immediate bounded low-latency display-link].include?(scenario.fetch("presentation", "immediate"))
        values.merge!("DIETER_TEST_SCREEN_CODEC" => scenario.fetch("codec", "h264"), "DIETER_TEST_SCREEN_FPS" => scenario.fetch("fps", 60).to_s, "DIETER_SCREEN_PRESENTATION" => scenario.fetch("presentation", "immediate"))
        values["DIETER_TEST_SCREEN_CAPTURE_REAL"] = "1" if scenario["capture"] == "screen"
        values["DIETER_TEST_SCREEN_RECOVERY"] = "1" if runner == "mac-recovery"
        values.merge!("DIETER_TEST_SCREEN_LATENCY_ONLY" => "1", "DIETER_SCREEN_RENDER_TRACE" => "1", "DIETER_TEST_SCREEN_INPUT_SAMPLES" => scenario.fetch("samples", 200).to_s) if runner == "mac-latency"
      elsif runner.start_with?("android-")
        raise PipelineError, "Invalid Android capture source" unless %w[native-synthetic screen].include?(scenario.fetch("capture", "native-synthetic"))
        {"lowLatency" => "DIETER_SCREEN_TEST_LOW_LATENCY", "surfaceView" => "DIETER_SCREEN_TEST_SURFACE", "directSurface" => "DIETER_SCREEN_TEST_DIRECT_SURFACE"}.each do |key, name|
          value = scenario.fetch(key, key == "lowLatency")
          raise PipelineError, "Expected boolean screen setting" unless value == true || value == false
          values[name] = value ? "1" : "0"
        end
        values["DIETER_SCREEN_TEST_SOURCE"] = scenario.fetch("capture", "native-synthetic")
      end
      scenario.fetch("switches", {}).each do |key, value|
        allowed = key == "DIETER_SCREEN_ENCODER_BURST_MS" ? %w[0 100 250 500] : %w[0 1]
        raise PipelineError, "Unknown/invalid screen experiment" unless SWITCHES.include?(key) && allowed.include?(value.to_s)
        values[key] = value.to_s
      end
      values
    end

    def self.invoke(options)
      values = options.transform_keys(&:to_s)
      raise PipelineError, "Unknown screen qualification options" unless (values.keys - %w[manifest output profile baseline cases]).empty?
      context = RunContext.new(Config.new(Runtime::ROOT), output: values["output"])
      begin
        path = File.expand_path(values.fetch("manifest"), context.root)
        raise PipelineError, "Oversized screen scenario" if File.size(path) > 256 * 1024
        manifest = JSON.parse(File.read(path), object_class: UniqueObject, allow_duplicate_key: false)
        scenarios = manifest.fetch("cases")
        ids = scenarios.map { |scenario| scenario.fetch("id") }
        required = manifest.fetch("required", ids)
        raise PipelineError, "Invalid screen scenario inventory" unless manifest["schemaVersion"] == 1 && (1..64).cover?(ids.length) && ids.uniq == ids && ids.all? { |id| id.is_a?(String) && id.match?(/\A[a-z0-9-]+\z/) } && !required.empty? && required.uniq == required && (required - ids).empty?
        selected = values.fetch("cases", ids.join(",")).split(",")
        raise PipelineError, "Unknown screen scenario selection" unless (selected - ids).empty?
        scenarios.each do |scenario|
          raise PipelineError, "Unknown screen scenario fields" unless (scenario.keys - %w[id runner codec capture fps presentation samples lowLatency surfaceView directSurface switches timeoutSeconds reason]).empty?
          %w[fps samples timeoutSeconds].each { |key| raise PipelineError, "Invalid screen numeric parameter" if scenario.key?(key) && (!scenario[key].is_a?(Integer) || !(1..7200).cover?(scenario[key])) }
          settings(scenario)
        end
        hardware = {"system" => context.command(["uname", "-sr"], timeout: 30).strip, "machine" => context.command(["uname", "-m"], timeout: 30).strip}
        hardware["model"] = context.command(["sysctl", "-n", "hw.model"], timeout: 30).strip if RUBY_PLATFORM.include?("darwin")
        if scenarios.any? { |scenario| selected.include?(scenario["id"]) && scenario["runner"].start_with?("android-") }
          raise PipelineError, "Physical screen qualification requires an explicit profile" unless values["profile"]
          target = context.config.profile(values["profile"], component: "android", physical_explicit: true)
          raise PipelineError, "Physical screen qualification requires a device profile" unless target["kind"] == "device"
          hardware["androidSerial"] = target.fetch("serial")
          %w[ro.product.model ro.build.fingerprint].each { |prop| hardware[prop] = context.command([File.join(context.environment.fetch("ANDROID_HOME"), "platform-tools/adb"), "-s", target.fetch("serial"), "shell", "getprop", prop], timeout: 30).strip }
        end
        record = {"schemaVersion" => 1, "manifest" => manifest.fetch("id"), "commit" => context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip, "sourceSHA256" => fingerprint(context), "hardware" => hardware, "cases" => []}
        Atomic.json(File.join(context.output, "scenario.json"), manifest)
        scenarios.select { |scenario| selected.include?(scenario["id"]) }.each do |scenario|
          puts "Screen qualification: #{scenario.fetch('id')}"
          record["cases"] << run_case(context, scenario, values["profile"])
          Atomic.json(File.join(context.output, "results.json"), record)
        end
        if values["baseline"]
          baseline = File.expand_path(values["baseline"], context.root)
          raise PipelineError, "Oversized screen baseline" if File.size(baseline) > 2 * 1024 * 1024
          record["comparison"] = evidence(context, {operation: "compare", current: record, baseline: JSON.parse(File.read(baseline), object_class: UniqueObject, allow_duplicate_key: false)})
        end
        record["missingRequired"] = required - record["cases"].map { |item| item["id"] }
        record["finalSourceSHA256"] = fingerprint(context)
        record["sourceUnchangedDuringRun"] = record["sourceSHA256"] == record["finalSourceSHA256"]
        passed = record["missingRequired"].empty? && record["cases"].select { |item| required.include?(item["id"]) }.all? { |item| item["status"] == "passed" }
        record["status"] = passed && record["sourceUnchangedDuringRun"] && record.dig("comparison", "status") != "failed" && record.dig("comparison", "status") != "unavailable" ? "passed" : "failed"
        Atomic.json(File.join(context.output, "results.json"), record)
        puts "Screen qualification evidence: #{context.output}"
        raise PipelineError, "Screen matrix did not qualify" unless record["status"] == "passed"
        record
      ensure
        context.close
      end
    end

    def self.run_case(parent, scenario, profile)
      result = {"id" => scenario.fetch("id"), "scenario" => scenario, "status" => "unavailable", "reason" => scenario.fetch("reason", "External evidence required"), "artifacts" => []}
      return result if scenario["runner"] == "external"
      directory = File.join(parent.output, scenario.fetch("id"))
      previous = ENV.to_h
      begin
        ENV.keys.grep(/\ADIETER_(?:SCREEN_|TEST_SCREEN_|TEST_CAPTURE_|TEST_RECOVERY_)/).each { |key| ENV.delete(key) }
        settings(scenario).each { |key, value| ENV[key] = value }
        runner = scenario.fetch("runner")
        if runner.start_with?("android-")
          selection = runner == "android-sdk" ? {"suite" => "sdk"} : {"cases" => "screens.screen-#{ {"android-codec" => "codec-", "android-journey" => "", "android-recovery" => "recovery-"}.fetch(runner) }end-to-end-test"}
          Runtime.invoke("e2e", "android", selection.merge("profile" => profile, "output" => directory))
        else
          context = RunContext.new(parent.config, output: directory)
          begin
            context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
            context.with_deadline(scenario.fetch("timeoutSeconds", 1800)) { Mac.new(context).public_send(runner == "native" ? :screens_native_test : :screens_test) }
          ensure
            context.close
          end
        end
        result.merge!(evidence(parent, {directory: directory, runner: runner}))
      rescue StandardError => error
        result.merge!("status" => error.is_a?(Unavailable) ? "unavailable" : "failed", "reason" => error.message)
        # Retain allowlisted measurements after a native assertion fails too.
        # An aggregate metric or collector pass cannot replace the native failure.
        if File.directory?(directory)
          begin
            observed = evidence(parent, {directory: directory, runner: runner})
            result.merge!(observed.slice("artifacts", "metrics"))
          rescue StandardError => diagnostic_error
            result["diagnosticError"] = diagnostic_error.class.name
          end
        end
      ensure
        ENV.replace(previous)
      end
      result
    end

    def self.evidence(context, request)
      JSON.parse(context.command(["python3", "-m", "fastlane.lib.dieter.native.screen_evidence"], input: JSON.generate(request), binary: true, timeout: 120))
    end

    def self.fingerprint(context)
      files = context.command(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], binary: true, timeout: 30).split("\0").uniq.sort
      digest = Digest::SHA256.new
      files.each do |name|
        path = File.join(context.root, name)
        digest.update(name + "\0" + Digest::SHA256.file(path).digest) if File.file?(path) && !File.symlink?(path)
      end
      digest.hexdigest
    end
  end
end
