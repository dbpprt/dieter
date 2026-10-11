# frozen_string_literal: true

require "find"
require "psych"
require "rexml/document"
require "tmpdir"
require "yaml"
require_relative "config"
require_relative "maestro"
require_relative "pipeline/context"
require_relative "pipeline/source"
require_relative "fixtures/gateway"
require_relative "platforms/android"
require_relative "platforms/ios"
require_relative "platforms/mac"

module Dieter
  # Runs the tests/maestro flows of one client against one isolated gateway
  # fixture. Android and iOS use the Maestro CLI; the Mac app interprets the
  # same YAML in-process because Maestro has no macOS driver.
  class E2E
    ROOT = File.expand_path("../../..", __dir__)
    FLOWS = {
      "android" => "tests/maestro/mobile",
      "ios" => "tests/maestro/mobile",
      "mac" => "tests/maestro/mac"
    }.freeze
    TAGS = %w[smoke full].freeze
    # The subset NativeUIFlowRunner implements.
    MAC_COMMANDS = %w[
      launchApp
      tapOn
      assertVisible
      assertNotVisible
      inputText
      extendedWaitUntil
      takeScreenshot
      pressKey
    ].freeze
    TOKEN = /isolated_[0-9a-fA-F]{48}/

    def self.invoke(platform, options, actions: nil, parent: nil)
      raise PipelineError, "Unknown E2E platform #{platform}" unless FLOWS.key?(platform)
      values = options.transform_keys(&:to_s).reject { |_key, value| value.to_s.empty? }
      unknown = values.keys - %w[profile tags flows output]
      raise PipelineError, "Unknown e2e options: #{unknown.join(", ")}" unless unknown.empty?
      context = RunContext.new(Config.new(ROOT), output: values.delete("output"), parent: parent)
      puts "E2E evidence: #{context.output}"
      begin
        context.environment["DIETER_RELEASE_VERSION"] ||= SourceIdentity.version(context)
        new(context, platform, values, actions: actions).run
      ensure
        context.close
      end
      context.output
    end

    # smoke selects flows tagged smoke; full selects every flow. Explicit
    # flow names (file names without .yaml) override tags.
    def self.flows(platform, tags: nil, names: nil)
      all =
        Dir.glob(File.join(ROOT, FLOWS.fetch(platform), "*.yaml")).sort.map { |path| flow(path) }
      raise PipelineError, "No Maestro flows in #{FLOWS.fetch(platform)}" if all.empty?
      if names
        return(
          names.map do |name|
            all.find { |entry| entry.fetch("id") == name } ||
              raise(PipelineError, "Unknown #{platform} flow #{name}")
          end
        )
      end
      tags ||= "smoke"
      raise PipelineError, "tags must be smoke or full" unless TAGS.include?(tags)
      tags == "full" ? all : all.select { |entry| entry.fetch("tags").include?("smoke") }
    end

    def self.flow(path)
      source = path.delete_prefix(ROOT + "/")
      text = File.read(path, encoding: "UTF-8")
      raise PipelineError, "#{source}: exceeds 256 KiB" if text.bytesize > 256 * 1024
      header, body = text.split(/^---[ \t]*\n/, 2)
      raise PipelineError, "#{source}: expected a header, ---, then commands" unless body
      meta = YAML.safe_load(header)
      unless meta.is_a?(Hash) && meta["name"].is_a?(String) && !meta["name"].empty?
        raise PipelineError, "#{source}: the header needs a name"
      end
      tags = meta["tags"]
      unless tags.is_a?(Array) && !tags.empty? && (tags - TAGS).empty?
        raise PipelineError, "#{source}: tags must be smoke and/or full"
      end
      steps = YAML.safe_load(body)
      unless steps.is_a?(Array) && (1..100).cover?(steps.length)
        raise PipelineError, "#{source}: expected 1 to 100 commands"
      end
      offset = header.lines.length + 1
      lines = Psych.parse(body).root.children.map { |node| node.start_line + offset + 1 }
      {
        "id" => File.basename(path, ".yaml"),
        "name" => meta["name"],
        "tags" => tags,
        "path" => path,
        "source" => source,
        "steps" => steps,
        "lines" => lines
      }
    end

    # The bounded JSON plan the Mac app interprets.
    def self.mac_plan(flow)
      steps =
        flow
          .fetch("steps")
          .each_with_index
          .map do |step, index|
            line = flow.fetch("lines")[index]
            step = { step => true } if step.is_a?(String)
            unless step.is_a?(Hash) && step.length == 1
              raise PipelineError, "#{flow.fetch("source")}:#{line}: expected one command"
            end
            command = step.keys.first
            unless MAC_COMMANDS.include?(command)
              raise PipelineError,
                    "#{flow.fetch("source")}:#{line}: Unsupported Maestro command #{command} on macOS"
            end
            step.merge("line" => line)
          end
      {
        "version" => 1,
        "name" => flow.fetch("name"),
        "source" => flow.fetch("source"),
        "steps" => steps
      }
    end

    # Parses every flow and its subflow references without a device.
    def self.lint
      count = 0
      FLOWS.values.uniq.each do |directory|
        platform = FLOWS.key(directory)
        flows(platform, tags: "full").each do |entry|
          count += 1
          if platform == "mac"
            mac_plan(entry)
            next
          end
          entry
            .fetch("steps")
            .each do |step|
              next unless step.is_a?(Hash) && step.key?("runFlow")
              reference = step.fetch("runFlow")
              reference = reference.fetch("file") if reference.is_a?(Hash)
              unless File.file?(File.join(File.dirname(entry.fetch("path")), reference.to_s))
                raise PipelineError, "#{entry.fetch("source")}: missing subflow #{reference}"
              end
            end
        end
      end
      count
    end

    def initialize(context, platform, options, actions: nil)
      @context, @platform, @options, @actions = context, platform, options, actions
      @flows =
        self.class.flows(platform, tags: options["tags"], names: options["flows"]&.split(","))
      name = options["profile"] || context.config.default_profile(platform)
      @target =
        context.config.profile(
          name,
          component: platform,
          physical_explicit: options.key?("profile")
        )
      @started = clock
      @report = {
        "version" => 1,
        "platform" => platform,
        "serial" => name,
        "buildMs" => 0,
        "installMs" => 0,
        "durationMs" => 0,
        "results" => []
      }
    end

    def run
      Atomic.json(
        File.join(@context.output, "request.json"),
        {
          "schema_version" => 1,
          "operation" => "e2e",
          "component" => @platform,
          "options" => @options,
          "flows" => @flows.map { |flow| flow.fetch("id") }
        }
      )
      puts "E2E #{@platform} on #{@report.fetch("serial")}: #{@flows.map { |flow| flow.fetch("id") }.join(", ")}"
      begin
        send(@platform)
      rescue StandardError => error
        status =
          case error
          when Unavailable
            "unavailable"
          when Interrupted
            "interrupted"
          else
            "failed"
          end
        seen = @report.fetch("results").map { |result| result.fetch("id") }
        @flows.each do |flow|
          record(flow, status, error.message, 0) unless seen.include?(identifier(flow))
        end
        raise
      ensure
        @report["durationMs"] = ((clock - @started) * 1000).round
        Atomic.json(File.join(@context.output, "results.json"), @report)
      end
      failed = @report.fetch("results").reject { |result| result["status"] == "passed" }
      return if failed.empty? && @report.fetch("results").length == @flows.length
      raise PipelineError,
            "#{failed.length}/#{@flows.length} #{@platform} flows did not pass; #{@context.output}"
    end

    private

    def android
      adapter = Android.new(@context, actions: @actions)
      # Compile before booting the emulator so low-memory hosts do not run both.
      apk = timed("buildMs") { adapter.e2e_build }
      serial = adapter.admit(@target)
      timed("installMs") { adapter.install(apk) }
      @context.cleanup { adapter.stop_app }
      values = fixture
      adapter.reverse(values.fetch("DIETER_ISOLATED_ADDR").split(":").last)
      maestro(serial, Android::APP, values)
    end

    def ios
      adapter = IOS.new(@context, actions: @actions)
      adapter.admit(@target)
      adapter.create_simulator
      app = timed("buildMs") { adapter.build({}) }
      simulator = adapter.ready
      timed("installMs") { adapter.install(app) }
      maestro(simulator, IOS::E2E_BUNDLE_ID, fixture)
    end

    def mac
      adapter = Mac.new(@context, actions: @actions)
      adapter.admit
      bundle = timed("buildMs") { adapter.build({}) }
      values = fixture
      endpoint = "http://#{values.fetch("DIETER_ISOLATED_ADDR")}"
      token = values.fetch("DIETER_ISOLATED_TOKEN")
      @flows.each do |flow|
        began = clock
        plan = self.class.mac_plan(flow)
        status, reason = "failed", ""
        begin
          report =
            @context.with_deadline(600) do
              adapter.run_flow(
                bundle,
                plan,
                File.join(@context.output, flow.fetch("id")),
                endpoint: endpoint,
                token: token
              )
            end
          status, reason = qualify(report, plan)
        rescue Unavailable, Interrupted, CleanupError
          raise
        rescue PipelineError => error
          reason = error.message
        end
        record(flow, status, reason, clock - began)
      end
    end

    def fixture
      state = Dir.mktmpdir("fixture-", @context.private_dir)
      gateway = GatewayFixture.new(@context, state, evidence: @context.output, e2e: true)
      @context.cleanup { gateway.close }
      gateway.start
    end

    def maestro(device, app, values)
      binary = Maestro.executable(@context)
      output = File.join(@context.output, "maestro")
      junit = File.join(@context.output, "junit.xml")
      java = @context.environment["JAVA_HOME"] || ENV["JAVA_HOME"]
      process =
        @context.start(
          [
            binary,
            "--device",
            device,
            "test",
            "--format",
            "junit",
            "--output",
            junit,
            "--test-output-dir",
            output,
            "-e",
            "APP_ID=#{app}",
            "-e",
            "FIXTURE_URL=http://#{values.fetch("DIETER_ISOLATED_ADDR")}",
            "-e",
            "FIXTURE_TOKEN=#{values.fetch("DIETER_ISOLATED_TOKEN")}",
            *@flows.map { |flow| flow.fetch("path") }
          ],
          environment: Maestro::ENVIRONMENT.merge(java ? { "JAVA_HOME" => java } : {}),
          log: File.join(@context.output, "maestro.log")
        )
      @context.wait(
        process,
        timeout: 300 * @flows.length + 300,
        label: "Maestro #{@platform}",
        check: false
      )
      redact(output)
      redact(junit)
      cases = junit_cases(junit)
      @flows.each do |flow|
        result = cases[File.basename(flow.fetch("path"))]
        if result
          record(flow, *result)
        else
          record(flow, "failed", "missing from the Maestro JUnit report", 0)
        end
      end
      return if process.status.success?
      if @report.fetch("results").all? { |result| result["status"] == "passed" }
        raise PipelineError, "Maestro exited #{process.status.exitstatus} despite passing flows"
      end
    end

    def junit_cases(path)
      return {} unless File.file?(path) && File.size(path) <= 1024 * 1024
      REXML::Document
        .new(File.read(path))
        .get_elements("//testcase")
        .to_h do |testcase|
          failure = testcase.elements["failure"] || testcase.elements["error"]
          status = testcase.attributes["status"]
          passed = failure.nil? && (status.nil? || status == "SUCCESS")
          # Maestro reports the flow path as it was given.
          [
            File.basename(testcase.attributes["file"].to_s),
            [
              passed ? "passed" : "failed",
              failure&.text.to_s.strip[0, 500],
              testcase.attributes["time"].to_f
            ]
          ]
        end
    end

    # Every step must report passed, and only the planned steps may report.
    def qualify(report, plan)
      return "failed", report["flow"].to_s if report.key?("flow")
      expected = plan.fetch("steps").each_index.map { |index| "step-#{index}" }
      expected.each_with_index do |key, index|
        next if report[key] == "passed"
        line = plan.fetch("steps")[index].fetch("line")
        return "failed", "#{plan.fetch("source")}:#{line}: #{report[key] || "no result"}"
      end
      return "failed", "Unexpected report entries" unless (report.keys - expected).empty?
      ["passed", ""]
    end

    # Maestro writes the resolved launch arguments into its evidence.
    def redact(path)
      return unless File.exist?(path)
      Find.find(path) do |file|
        next unless File.file?(file) && !File.symlink?(file) && File.size(file) <= 16 * 1024 * 1024
        next unless %w[.json .txt .log .xml .yaml .html].include?(File.extname(file))
        text = File.binread(file)
        redacted = text.gsub(TOKEN, "<redacted>")
        Atomic.write(file, redacted) unless redacted == text
      end
    end

    def record(flow, status, reason, seconds)
      milliseconds = (seconds * 1000).round
      @report.fetch("results") << {
        "id" => identifier(flow),
        "status" => status,
        "reason" => reason.to_s,
        "setupMs" => 0,
        "executionMs" => milliseconds,
        "durationMs" => milliseconds
      }
      suffix = reason.to_s.empty? ? "" : ": #{reason}"
      puts "#{status.upcase} #{identifier(flow)} in #{seconds.round(1)}s#{suffix}"
    end

    def identifier(flow) = "#{@platform}.#{flow.fetch("id")}"

    def timed(key)
      began = clock
      value = yield
      @report[key] = ((clock - began) * 1000).round
      value
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
