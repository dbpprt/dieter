# frozen_string_literal: true

require_relative "../errors"

module Dieter
  class PipelineRequest
    COMPONENTS = %w[android ios mac daemon gateway core].freeze
    COMMON = %w[profile output configuration filter artifact identity suite cases changed base].freeze
    attr_reader :operation, :component, :options

    def initialize(operation, component, options = {}, allowed: COMMON)
      raise PipelineError, "Unknown component #{component}" unless COMPONENTS.include?(component)
      @operation, @component = operation.to_s, component.to_s
      @options = options.transform_keys(&:to_s)
      unknown = @options.keys - allowed
      raise PipelineError, "Unknown options: #{unknown.join(', ')}" unless unknown.empty?
      if @options["configuration"] && !%w[debug release].include?(@options["configuration"])
        raise PipelineError, "configuration must be debug or release"
      end
      if @options.key?("changed")
        @options["changed"] = case @options["changed"]
                             when true, "true" then true
                             when false, "false" then false
                             else raise PipelineError, "changed must be true or false"
                             end
      end
      @options.freeze
      freeze
    end

    def profile(config)
      name = options["profile"] || config.default_profile(component)
      config.profile(name, component: component, physical_explicit: options.key?("profile"))
    end

    def to_h
      {"schema_version" => 1, "operation" => operation, "component" => component, "options" => options}
    end
  end
end
