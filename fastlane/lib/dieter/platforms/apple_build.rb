# frozen_string_literal: true

require_relative "../errors"

module Dieter
  module AppleBuild
    def self.mac_scratch(context, operation:)
      # Disposable hosted qualification already compiles the app with swift test.
      # Reuse that graph for packaging instead of compiling every dependency twice.
      hosted_check = ENV["GITHUB_ACTIONS"] == "true" && ENV["RUNNER_ENVIRONMENT"] == "github-hosted" && ENV["DIETER_APPLE_CHECK_CACHE"] == "true"
      name = operation == :test || hosted_check ? "dieter-tests" : "dieter-local"
      File.join(context.root, "apps/mac/.build", name)
    end

    def self.jobs(context, tool:)
      value = context.environment["DIETER_SWIFT_JOBS"] || ENV["DIETER_SWIFT_JOBS"]
      return [] unless value
      raise PipelineError, "DIETER_SWIFT_JOBS must be an integer from 1 to 64" unless value.to_s.match?(/\A[1-9][0-9]*\z/) && (1..64).cover?(value.to_i)
      [tool == :xcode ? "-jobs" : "--jobs", value.to_s]
    end
  end
end
