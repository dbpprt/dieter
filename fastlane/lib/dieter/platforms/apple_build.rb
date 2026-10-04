# frozen_string_literal: true

require_relative "../errors"

module Dieter
  module AppleBuild
    def self.jobs(context, tool:)
      value = context.environment["DIETER_SWIFT_JOBS"] || ENV["DIETER_SWIFT_JOBS"]
      return [] unless value
      raise PipelineError, "DIETER_SWIFT_JOBS must be an integer from 1 to 64" unless value.to_s.match?(/\A[1-9][0-9]*\z/) && (1..64).cover?(value.to_i)
      [tool == :xcode ? "-jobs" : "--jobs", value.to_s]
    end
  end
end
