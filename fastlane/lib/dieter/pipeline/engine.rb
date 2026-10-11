# frozen_string_literal: true

require_relative "request"
require_relative "artifacts"

module Dieter
  # Unit, build and verify compositions. Maestro flows run through E2E.
  class Pipeline
    COMPOSITIONS = { "test_unit" => %w[unit], "build" => %w[build], "verify" => %w[verify] }.freeze

    def initialize(context, request, adapter)
      @context, @request, @adapter = context, request, adapter
    end

    def run
      composition =
        COMPOSITIONS.fetch(@request.operation) do
          raise PipelineError, "Unknown operation #{@request.operation}"
        end
      Atomic.json(File.join(@context.output, "request.json"), @request.to_h)
      begin
        composition.each do |stage|
          puts "Pipeline #{@request.component}: #{stage}"
          send(stage)
        end
      ensure
        @context.close
      end
      @context.output
    end

    private

    def unit
      @adapter.unit(@request.options)
    end

    def build
      @adapter.build(@request.options)
    end

    def verify
      ArtifactSet.load(
        File.expand_path(@request.options.fetch("artifact"), @context.root),
        component: @request.component
      )
    end
  end
end
