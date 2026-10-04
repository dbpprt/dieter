# frozen_string_literal: true

require_relative "contract"
require_relative "request"
require_relative "artifacts"

module Dieter
  class Pipeline
    COMPOSITIONS = {
      "test_unit" => %w[unit], "build" => %w[build],
      "e2e" => %w[plan admission preparation cases qualification],
      "prepare_tests" => %w[plan admission preparation],
      "verify" => %w[verify]
    }.freeze

    def initialize(context, request, adapter, contract: nil, planned_cases: nil)
      @context, @request, @adapter = context, request, adapter
      @contract = contract || Contract.new(context)
      @planned_cases = planned_cases
      @started = clock
      @plan, @report = [], nil
    end

    def run
      composition = COMPOSITIONS.fetch(@request.operation) { raise PipelineError, "Unknown operation #{@request.operation}" }
      Atomic.json(File.join(@context.output, "request.json"), @request.to_h)
      begin
        composition.each do |stage|
          puts "Pipeline #{@request.component}: #{stage}"
          send(stage)
        end
      rescue StandardError => error
        fail_remaining(error)
        raise
      ensure
        begin
          @context.close
        rescue CleanupError => error
          fail_remaining(error, cleanup: true)
          raise
        end
      end
      @context.output
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def unit
      @adapter.unit(@request.options)
    end

    def build
      @adapter.build(@request.options)
    end

    def verify
      ArtifactSet.load(File.expand_path(@request.options.fetch("artifact"), @context.root), component: @request.component)
    end

    def plan
      options = @request.options
      profile_name = options["profile"] || @context.config.default_profile(@request.component)
      @plan = @planned_cases || @request.plan(@context.config, @contract)
      Atomic.json(File.join(@context.output, "plan.json"), @plan)
      @report = {"version" => 1, "platform" => @request.component, "serial" => profile_name,
                 "buildMs" => 0, "installMs" => 0, "durationMs" => 0, "results" => []}
    end

    def admission
      return if @plan.empty?
      @target = @request.profile(@context.config)
      @report["serial"] = @target["serial"] || @target["udid"] || @target["name"]
      @adapter.admit(@target, @plan)
    end

    def preparation
      return if @plan.empty?
      began = clock
      @adapter.prepare(@target, @plan)
      @report["buildMs"] = ((clock - began) * 1000).round
    end

    def cases
      @plan.each_with_index do |test_case, index|
        began = clock
        puts "Running #{index + 1}/#{@plan.length}: #{test_case.fetch('id')} (fresh isolated state)"
        seconds = test_case.fetch("timeout").scan(/(\d+(?:\.\d+)?)(h|m|s)/).sum { |number, unit| number.to_f * {"h" => 3600, "m" => 60, "s" => 1}.fetch(unit) }
        result = @context.with_deadline(seconds) { @adapter.execute_case(@target, test_case) }
        result["id"] = test_case.fetch("id")
        result["durationMs"] = ((clock - began) * 1000).round
        result["status"] = "failed" if result["cleanupError"] && !result["cleanupError"].empty?
        result["status"] ||= "failed"
        @report["results"] << result
        @report["durationMs"] = ((clock - @started) * 1000).round
        Atomic.json(File.join(@context.output, "results.json"), @report)
        puts "#{result['status'].upcase} #{result['id']} in #{(result['durationMs'] / 1000.0).round(1)}s: #{result['reason']}"
        raise CleanupError, result["cleanupError"] if result["cleanupError"] && !result["cleanupError"].empty?
        raise Interrupted, result["reason"] if result["status"] == "interrupted"
      end
    end

    def qualification
      return if @plan.empty?
      write_report
      failed = @report.fetch("results").count { |result| result["status"] != "passed" }
      raise PipelineError, "#{failed}/#{@plan.length} required cases did not pass; #{@context.output}" unless failed.zero?
    end

    def write_report
      @report["durationMs"] = ((clock - @started) * 1000).round
      @contract.call("report", {output: @context.output, cases: @plan, report: @report}, json: false)
    end

    def fail_remaining(error, cleanup: false)
      return if @report.nil? || @plan.empty?
      seen = @report.fetch("results").map { |result| result.fetch("id") }
      @plan.each do |test_case|
        next if seen.include?(test_case.fetch("id"))
        status = error.is_a?(Unavailable) ? "unavailable" : "interrupted"
        @report["results"] << {"id" => test_case.fetch("id"), "status" => status, "reason" => error.message, "durationMs" => 0, "setupMs" => 0, "executionMs" => 0}
      end
      if cleanup
        @report.fetch("results").each do |result|
          result["status"], result["cleanupError"] = "failed", error.message
        end
      end
      write_report
    end
  end
end
