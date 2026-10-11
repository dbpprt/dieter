# frozen_string_literal: true

require "uri"
require_relative "../errors"

module Dieter
  class GatewayFixture
    def self.compile(context)
      path = File.join(context.private_dir, "isolated-gateway")
      return path if File.executable?(path)
      context.command(
        ["go", "build", "-o", path, "./tools/fixtures/gateway"],
        timeout: 300,
        log: File.join(context.output, "fixture-build.log")
      )
      path
    end

    attr_reader :values, :process

    # e2e seeds the workspace every Maestro flow shares; direct adds the
    # authenticated direct route the Swift-to-core integration tests use.
    def initialize(context, state, evidence: nil, e2e: false, direct: false)
      @context, @state, @evidence, @e2e, @direct = context, state, evidence, e2e, direct
    end

    def start
      binary = File.join(@context.private_dir, "isolated-gateway")
      self.class.compile(@context) unless File.file?(binary)
      argv = [binary, "-addr", "127.0.0.1:0", "-home", File.join(@state, "gateway")]
      argv += %w[-direct-route live] if @direct
      argv << "-e2e-fixture" if @e2e
      @process =
        @context.start(
          argv,
          environment: {
            "DIETER_HARNESS_RUNTIME_DIR" => File.join(@context.root, "internal/harness/runtime"),
            # Production daemons offer WebRTC control channels; the Android app uses them too.
            "DIETER_TEST_CONTROL_WEBRTC" => @e2e ? "1" : nil
          }.compact
        )
      # Seeding runs git and starts two daemons; a CI runner that just tore down a
      # simulator has taken over 60 s for this.
      deadline = monotonic + 120
      loop do
        text = process.stdout.force_encoding(Encoding::UTF_8).scrub
        if text.lines.any? { |line| line.strip == "READY" }
          @values =
            text
              .lines
              .filter_map do |line|
                match = line.strip.match(/\A(DIETER_ISOLATED_[A-Z_]+)=(.*)\z/)
                [match[1], match[2]] if match
              end
              .to_h
          address, token = values["DIETER_ISOLATED_ADDR"], values["DIETER_ISOLATED_TOKEN"]
          unless address&.match?(/\A127\.0\.0\.1:[1-9]\d{0,4}\z/) && token && !token.empty?
            raise PipelineError, "Invalid private fixture readiness"
          end
          @context.secrets << token
          return values
        end
        unless process.running?
          raise PipelineError,
                "Fixture exited before readiness: #{process.output[-2000..] || process.output}"
        end
        raise Interrupted, "Fixture readiness exceeded 120s" if monotonic >= deadline
        sleep 0.1
      end
    end

    def close
      return unless process
      process.stop
      Atomic.write(File.join(@evidence, "fixture.log"), process.output) if @evidence
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
