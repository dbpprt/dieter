# frozen_string_literal: true

require_relative "runtime"

module Dieter
  # Specialized measurement scenarios compose the same adapters as app tests.
  # Evidence validation stays separate from execution and never promotes defaults.
  module Screens
    SWITCHES = %w[
      DIETER_SCREEN_CONTENT_ADAPTATION
      DIETER_SCREEN_OVERLAP
      DIETER_SCREEN_ENCODER_BURST_MS
      DIETER_SCREEN_FEC
      DIETER_SCREEN_LTR
      DIETER_SCREEN_FAST_BITRATE
    ].freeze
    RUNNERS = %w[native mac-latency mac-recovery mac-journey external].freeze

    def self.settings(scenario)
      runner = scenario.fetch("runner")
      raise PipelineError, "Unknown screen runner" unless RUNNERS.include?(runner)
      values = {}
      if runner.start_with?("mac-")
        unless %w[h264 hevc].include?(scenario.fetch("codec", "h264")) &&
                 %w[synthetic screen].include?(scenario.fetch("capture", "synthetic")) &&
                 %w[immediate bounded low-latency display-link].include?(
                   scenario.fetch("presentation", "immediate")
                 )
          raise PipelineError, "Invalid screen codec/capture/presentation"
        end
        values.merge!(
          "DIETER_TEST_SCREEN_CODEC" => scenario.fetch("codec", "h264"),
          "DIETER_TEST_SCREEN_FPS" => scenario.fetch("fps", 60).to_s,
          "DIETER_SCREEN_PRESENTATION" => scenario.fetch("presentation", "immediate")
        )
        values["DIETER_TEST_SCREEN_CAPTURE_REAL"] = "1" if scenario["capture"] == "screen"
        values["DIETER_TEST_SCREEN_RECOVERY"] = "1" if runner == "mac-recovery"
        if runner == "mac-latency"
          values.merge!(
            "DIETER_TEST_SCREEN_LATENCY_ONLY" => "1",
            "DIETER_SCREEN_RENDER_TRACE" => "1",
            "DIETER_TEST_SCREEN_INPUT_SAMPLES" => scenario.fetch("samples", 200).to_s
          )
        end
      end
      scenario
        .fetch("switches", {})
        .each do |key, value|
          allowed = key == "DIETER_SCREEN_ENCODER_BURST_MS" ? %w[0 100 250 500] : %w[0 1]
          unless SWITCHES.include?(key) && allowed.include?(value.to_s)
            raise PipelineError, "Unknown/invalid screen experiment"
          end
          values[key] = value.to_s
        end
      values
    end

    def self.invoke(options)
      values = options.transform_keys(&:to_s)
      unless (values.keys - %w[manifest output baseline cases]).empty?
        raise PipelineError, "Unknown screen qualification options"
      end
      context = RunContext.new(Config.new(Runtime::ROOT), output: values["output"])
      begin
        path = File.expand_path(values.fetch("manifest"), context.root)
        raise PipelineError, "Oversized screen scenario" if File.size(path) > 256 * 1024
        manifest =
          JSON.parse(File.read(path), object_class: UniqueObject, allow_duplicate_key: false)
        scenarios = manifest.fetch("cases")
        ids = scenarios.map { |scenario| scenario.fetch("id") }
        required = manifest.fetch("required", ids)
        unless manifest["schemaVersion"] == 1 && (1..64).cover?(ids.length) && ids.uniq == ids &&
                 ids.all? { |id| id.is_a?(String) && id.match?(/\A[a-z0-9-]+\z/) } &&
                 !required.empty? && required.uniq == required && (required - ids).empty?
          raise PipelineError, "Invalid screen scenario inventory"
        end
        selected = values.fetch("cases", ids.join(",")).split(",")
        raise PipelineError, "Unknown screen scenario selection" unless (selected - ids).empty?
        scenarios.each do |scenario|
          unless (
                   scenario.keys -
                     %w[
                       id
                       runner
                       codec
                       capture
                       fps
                       presentation
                       samples
                       switches
                       timeoutSeconds
                       reason
                     ]
                 ).empty?
            raise PipelineError, "Unknown screen scenario fields"
          end
          %w[fps samples timeoutSeconds].each do |key|
            if scenario.key?(key) &&
                 (!scenario[key].is_a?(Integer) || !(1..7200).cover?(scenario[key]))
              raise PipelineError, "Invalid screen numeric parameter"
            end
          end
          settings(scenario)
        end
        hardware = {
          "system" => context.command(%w[uname -sr], timeout: 30).strip,
          "machine" => context.command(%w[uname -m], timeout: 30).strip
        }
        hardware["model"] = context.command(
          %w[sysctl -n hw.model],
          timeout: 30
        ).strip if RUBY_PLATFORM.include?("darwin")
        record = {
          "schemaVersion" => 1,
          "manifest" => manifest.fetch("id"),
          "commit" => context.command(%w[git rev-parse HEAD], timeout: 30).strip,
          "sourceSHA256" => fingerprint(context),
          "hardware" => hardware,
          "cases" => []
        }
        Atomic.json(File.join(context.output, "scenario.json"), manifest)
        scenarios
          .select { |scenario| selected.include?(scenario["id"]) }
          .each do |scenario|
            puts "Screen qualification: #{scenario.fetch("id")}"
            record["cases"] << run_case(context, scenario)
            Atomic.json(File.join(context.output, "results.json"), record)
            if record["cases"].last["status"] == "interrupted"
              record["missingRequired"] = required - record["cases"].map { |item| item["id"] }
              record["finalSourceSHA256"] = fingerprint(context)
              record["sourceUnchangedDuringRun"] = record["sourceSHA256"] ==
                record["finalSourceSHA256"]
              record["status"] = "failed"
              Atomic.json(File.join(context.output, "results.json"), record)
              raise Interrupted, record["cases"].last.fetch("reason")
            end
          end
        if values["baseline"]
          baseline = File.expand_path(values["baseline"], context.root)
          raise PipelineError, "Oversized screen baseline" if File.size(baseline) > 2 * 1024 * 1024
          record["comparison"] = evidence(
            context,
            {
              operation: "compare",
              current: record,
              baseline:
                JSON.parse(
                  File.read(baseline),
                  object_class: UniqueObject,
                  allow_duplicate_key: false
                )
            }
          )
        end
        record["missingRequired"] = required - record["cases"].map { |item| item["id"] }
        record["finalSourceSHA256"] = fingerprint(context)
        record["sourceUnchangedDuringRun"] = record["sourceSHA256"] == record["finalSourceSHA256"]
        passed =
          record["missingRequired"].empty? &&
            record["cases"]
              .select { |item| required.include?(item["id"]) }
              .all? { |item| item["status"] == "passed" }
        record["status"] = (
          if passed && record["sourceUnchangedDuringRun"] &&
               record.dig("comparison", "status") != "failed" &&
               record.dig("comparison", "status") != "unavailable"
            "passed"
          else
            "failed"
          end
        )
        Atomic.json(File.join(context.output, "results.json"), record)
        puts "Screen qualification evidence: #{context.output}"
        raise PipelineError, "Screen matrix did not qualify" unless record["status"] == "passed"
        record
      ensure
        context.close
      end
    end

    def self.run_case(parent, scenario)
      result = {
        "id" => scenario.fetch("id"),
        "scenario" => scenario,
        "status" => "unavailable",
        "reason" => scenario.fetch("reason", "External evidence required"),
        "artifacts" => []
      }
      return result if scenario["runner"] == "external"
      directory = File.join(parent.output, scenario.fetch("id"))
      previous = ENV.to_h
      begin
        ENV
          .keys
          .grep(/\ADIETER_(?:SCREEN_|TEST_SCREEN_|TEST_CAPTURE_|TEST_RECOVERY_)/)
          .each { |key| ENV.delete(key) }
        settings(scenario).each { |key, value| ENV[key] = value }
        runner = scenario.fetch("runner")
        context = RunContext.new(parent.config, output: directory)
        begin
          context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
          context.with_deadline(scenario.fetch("timeoutSeconds", 1800)) do
            Mac.new(context).public_send(runner == "native" ? :screens_native_test : :screens_test)
          end
        ensure
          context.close
        end
        result.merge!(evidence(parent, { directory: directory, runner: runner }))
      rescue StandardError => error
        status =
          error.is_a?(Interrupted) ?
            "interrupted" :
            error.is_a?(Unavailable) ? "unavailable" : "failed"
        result.merge!("status" => status, "reason" => error.message)
        # Retain allowlisted measurements after a native assertion fails too.
        # An aggregate metric or collector pass cannot replace the native failure.
        if File.directory?(directory)
          begin
            observed = evidence(parent, { directory: directory, runner: runner })
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
      JSON.parse(
        context.command(
          %w[python3 -m fastlane.lib.dieter.native.screen_evidence],
          input: JSON.generate(request),
          binary: true,
          timeout: 120
        )
      )
    end

    def self.fingerprint(context)
      files =
        context
          .command(
            %w[git ls-files --cached --others --exclude-standard -z],
            binary: true,
            timeout: 30
          )
          .split("\0")
          .uniq
          .sort
      digest = Digest::SHA256.new
      files.each do |name|
        path = File.join(context.root, name)
        if File.file?(path) && !File.symlink?(path)
          digest.update(name + "\0" + Digest::SHA256.file(path).digest)
        end
      end
      digest.hexdigest
    end
  end
end
