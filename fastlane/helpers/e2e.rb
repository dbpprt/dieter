# frozen_string_literal: true

require "find"
require "psych"
require "rexml/document"
require "yaml"
require_relative "dieter"

module Dieter
  # The tests/maestro flows: Android and iOS run the mobile flows with the
  # Maestro CLI; the debug Mac app interprets the mac flows in-process.
  module Flows
    DIRECTORIES = {
      "android" => "tests/maestro/mobile",
      "ios" => "tests/maestro/mobile",
      "mac" => "tests/maestro/mac"
    }.freeze
    TAGS = %w[smoke full].freeze
    # The subset the Mac app's NativeUIFlowRunner implements.
    MAC_COMMANDS = %w[
      launchApp
      tapOn
      assertVisible
      assertNotVisible
      inputText
      extendedWaitUntil
      takeScreenshot
      pressKey
      scroll
    ].freeze

    module_function

    def parse(file)
      source = file.delete_prefix("#{ROOT}/")
      text = File.read(file, encoding: "UTF-8")
      header, body = text.split(/^---[ \t]*\n/, 2)
      raise ArgumentError, "#{source}: expected a header, ---, then commands" unless body
      meta = YAML.safe_load(header)
      unless meta.is_a?(Hash) && !meta["name"].to_s.empty?
        raise ArgumentError, "#{source}: the header needs a name"
      end
      tags = meta["tags"]
      unless tags.is_a?(Array) && !tags.empty? && (tags - TAGS).empty?
        raise ArgumentError, "#{source}: tags must be smoke and/or full"
      end
      steps = YAML.safe_load(body)
      unless steps.is_a?(Array) && (1..100).cover?(steps.length)
        raise ArgumentError, "#{source}: expected 1 to 100 commands"
      end
      offset = header.lines.length + 2
      lines = Psych.parse(body).root.children.map { |node| node.start_line + offset }
      {
        "id" => File.basename(file, ".yaml"),
        "name" => meta["name"],
        "tags" => tags,
        "path" => file,
        "source" => source,
        "steps" => steps,
        "lines" => lines
      }
    end

    # smoke selects flows tagged smoke, full every flow; flow names override tags.
    def select(platform, tags: nil, names: nil)
      all =
        Dir.glob(Dieter.path(DIRECTORIES.fetch(platform), "*.yaml")).sort.map { |file| parse(file) }
      raise ArgumentError, "No Maestro flows for #{platform}" if all.empty?
      unless names.to_s.empty?
        return(
          names
            .split(",")
            .map do |name|
              all.find { |flow| flow["id"] == name } ||
                raise(ArgumentError, "Unknown #{platform} flow #{name}")
            end
        )
      end
      tags = tags.to_s.empty? ? "smoke" : tags
      raise ArgumentError, "tags must be smoke or full" unless TAGS.include?(tags)
      tags == "full" ? all : all.select { |flow| flow["tags"].include?("smoke") }
    end

    # The bounded JSON plan the Mac app runs; unsupported commands fail here.
    def mac_plan(flow)
      steps =
        flow["steps"].each_with_index.map do |step, index|
          line = flow["lines"][index]
          step = { step => true } if step.is_a?(String)
          unless step.is_a?(Hash) && step.length == 1
            raise ArgumentError, "#{flow["source"]}:#{line}: expected one command"
          end
          unless MAC_COMMANDS.include?(step.keys.first)
            raise ArgumentError,
                  "#{flow["source"]}:#{line}: unsupported Maestro command #{step.keys.first} on macOS"
          end
          step.merge("line" => line)
        end
      { "version" => 1, "name" => flow["name"], "source" => flow["source"], "steps" => steps }
    end

    # Parses every flow and its subflow references without a device.
    def lint
      DIRECTORIES.values.uniq.sum do |directory|
        platform = DIRECTORIES.key(directory)
        select(platform, tags: "full")
          .each do |flow|
            next mac_plan(flow) if platform == "mac"
            flow["steps"].each do |step|
              next unless step.is_a?(Hash) && step.key?("runFlow")
              run = step["runFlow"]
              # An inline conditional block (`when` + `commands`) needs no file.
              next if run.is_a?(Hash) && run.key?("commands") && !run.key?("file")
              reference = run.is_a?(Hash) ? run["file"] : run
              unless File.file?(File.join(File.dirname(flow["path"]), reference.to_s))
                raise ArgumentError, "#{flow["source"]}: missing subflow #{reference}"
              end
            end
          end
          .length
      end
    end

    # Every planned step reported passed and nothing else reported.
    def qualify_mac(report, plan)
      return "failed", report["flow"].to_s if report.key?("flow")
      expected = plan["steps"].each_index.map { |index| "step-#{index}" }
      expected.each_with_index do |key, index|
        next if report[key] == "passed"
        return [
          "failed",
          "#{plan["source"]}:#{plan["steps"][index]["line"]}: #{report[key] || "no result"}"
        ]
      end
      return "failed", "unexpected report entries" unless (report.keys - expected).empty?
      ["passed", ""]
    end

    # Maestro's JUnit report keyed by flow file name: [status, message, seconds].
    def junit_cases(file)
      return {} unless File.file?(file)
      REXML::Document
        .new(File.read(file))
        .get_elements("//testcase")
        .to_h do |testcase|
          failure = testcase.elements["failure"] || testcase.elements["error"]
          passed = failure.nil? && [nil, "SUCCESS"].include?(testcase.attributes["status"])
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
  end

  # One isolated gateway fixture (tools/fixtures/gateway) per run. It prints
  # KEY=VALUE lines, then READY; the token never reaches logs or evidence.
  class Fixture
    TOKEN = /isolated_[0-9a-fA-F]{48}/
    attr_reader :values

    def self.binary
      @binary ||=
        begin
          output = Dieter.path("tmp/pipeline/bin/isolated-gateway")
          Dieter.sh("go", "build", "-o", output, "./tools/fixtures/gateway")
          output
        end
    end

    def initialize(evidence, cleanup, e2e: false, direct: false)
      state = Dir.mktmpdir("dieter-fixture-")
      argv = [self.class.binary, "-addr", "127.0.0.1:0", "-home", File.join(state, "gateway")]
      argv += %w[-direct-route live] if direct
      argv << "-e2e-fixture" if e2e
      if e2e && !ENV["DIETER_TEST_MAIL_REPORT"].to_s.empty?
        argv += ["-mail-report", File.expand_path(ENV.fetch("DIETER_TEST_MAIL_REPORT"))]
      end
      env = { "DIETER_HARNESS_RUNTIME_DIR" => Dieter.path("internal/harness/runtime") }
      env["DIETER_TEST_CONTROL_WEBRTC"] = "1" if e2e
      log = File.join(evidence, "fixture.log")
      @process = Owned.new(argv, log: log, env: env)
      cleanup.add do
        @process.stop
        FileUtils.rm_rf(state)
        Fixture.redact(log)
      end
      # Seeding runs git and starts two daemons; a busy runner has taken over 60s.
      deadline = Dieter.clock + 120
      until (lines = File.read(log).lines.map(&:strip)).include?("READY")
        raise Unavailable, "Fixture exited before readiness; see #{log}" unless @process.running?
        raise Unavailable, "Fixture readiness exceeded 120s" if Dieter.clock > deadline
        sleep 0.1
      end
      @values =
        lines.filter_map { |line| line.match(/\A(DIETER_ISOLATED_[A-Z_]+)=(.*)\z/)&.captures }.to_h
      unless @values["DIETER_ISOLATED_ADDR"].to_s.match?(/\A127\.0\.0\.1:\d+\z/) &&
               !@values["DIETER_ISOLATED_TOKEN"].to_s.empty? &&
               !@values["DIETER_ISOLATED_PAIRING_CODE"].to_s.empty?
        raise "Invalid fixture readiness"
      end
    end

    def address = values.fetch("DIETER_ISOLATED_ADDR")
    def token = values.fetch("DIETER_ISOLATED_TOKEN")
    # The one-time code the fixture's machine approves; apps pair with it.
    def pairing_code = values.fetch("DIETER_ISOLATED_PAIRING_CODE")

    def self.redact(path)
      return unless File.exist?(path)
      Find.find(path) do |file|
        next unless File.file?(file) && !File.symlink?(file) && File.size(file) <= 16 * 1024 * 1024
        next unless %w[.json .txt .log .xml .yaml .html].include?(File.extname(file))
        text = File.binread(file)
        redacted = text.gsub(TOKEN, "<redacted>")
        File.binwrite(file, redacted) unless redacted == text
      end
    end
  end

  # Results of one E2E run: every selected flow must pass, missing results fail.
  class Results
    attr_reader :entries

    def initialize(platform, flows, evidence)
      @platform, @flows, @evidence, @entries = platform, flows, evidence, []
    end

    def record(flow, status, reason = "", seconds = 0)
      reason = reason.to_s.gsub(/\e\[[0-9;]*m/, "")
      @entries << {
        "id" => "#{@platform}.#{flow["id"]}",
        "status" => status,
        "reason" => reason.to_s,
        "seconds" => seconds.round(1)
      }
      puts "#{status.upcase} #{@platform}.#{flow["id"]} in #{seconds.round(1)}s#{reason.to_s.empty? ? "" : ": #{reason}"}"
    end

    def record_junit(junit)
      cases = Flows.junit_cases(junit)
      @flows.each do |flow|
        result = cases[File.basename(flow["path"])]
        if result
          record(flow, *result)
        else
          record(flow, "failed", "missing from the Maestro JUnit report")
        end
      end
    end

    # Flows without a result inherit the error that ended the run.
    def finish(error = nil)
      seen = @entries.map { |entry| entry["id"] }
      if error
        @flows.each do |flow|
          record(flow, "failed", error.message) unless seen.include?("#{@platform}.#{flow["id"]}")
        end
      end
      File.write(
        File.join(@evidence, "results.json"),
        JSON.pretty_generate("platform" => @platform, "results" => @entries) + "\n"
      )
      failed = @entries.reject { |entry| entry["status"] == "passed" }
      return if error.nil? && failed.empty? && @entries.length == @flows.length
      raise error if error
      raise "#{failed.length}/#{@flows.length} #{@platform} flows failed; evidence #{@evidence}"
    end
  end
end
