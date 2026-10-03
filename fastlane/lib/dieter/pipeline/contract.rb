# frozen_string_literal: true

require "digest"
require_relative "../atomic"

module Dieter
  class Contract
    def initialize(context)
      @context = context
      @binary = File.join(context.private_dir, "pipeline-contract")
    end

    def call(operation, request = {}, json: true)
      compile
      value = @context.command([@binary, operation], input: JSON.generate(request), timeout: 120, binary: true)
      json && !value.empty? ? JSON.parse(value) : value
    end

    private

    def compile
      return if @compiled || File.executable?(@binary)
      @context.command(["go", "build", "-o", @binary, "./tools/pipeline-contract"], timeout: 300, label: "Compile pipeline contracts")
      @compiled = true
    end
  end
end
