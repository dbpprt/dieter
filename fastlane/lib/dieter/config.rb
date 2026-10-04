# frozen_string_literal: true

require "json"
require "json-schema"
require_relative "errors"
require_relative "atomic"

module Dieter
  class UniqueObject < Hash
    def []=(key, value)
      raise PipelineError, "Duplicate configuration key: #{key}" if key?(key)
      super
    end
  end

  class Config
    attr_reader :root, :data, :local_loaded

    def initialize(root, ci: ENV["CI"] == "true" || ENV["GITHUB_ACTIONS"] == "true")
      @root = File.realpath(root)
      @data = read(File.join(root, "fastlane/config.json"))
      local = File.join(root, "fastlane/local.json")
      @local_loaded = !ci && File.file?(local)
      @data = merge(@data, read(local)) if @local_loaded
      if ci && ENV["DIETER_CI_DEVICE_CONFIG"] && !ENV["DIETER_CI_DEVICE_CONFIG"].empty?
        raise PipelineError, "Physical CI configuration requires a trusted self-hosted main runner" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF"] == "refs/heads/main" && ENV["RUNNER_ENVIRONMENT"] == "self-hosted"
        raw = ENV.fetch("DIETER_CI_DEVICE_CONFIG")
        raise PipelineError, "Physical CI configuration exceeds 16 KiB" if raw.bytesize > 16 * 1024
        begin
          device = JSON.parse(raw, object_class: UniqueObject, allow_duplicate_key: false, max_nesting: 16)
        rescue JSON::ParserError
          raise PipelineError, "Invalid CI device configuration JSON"
        end
        raise PipelineError, "CI device configuration can only select physical profiles and existing development signing/routes" unless device.is_a?(Hash) && (device.keys - %w[profiles signing fixture_routes]).empty? && %w[profiles signing fixture_routes].all? { |key| device.fetch(key, {}).is_a?(Hash) } && (device.fetch("profiles", {}).keys - %w[android-device ios-device]).empty? && (device.fetch("signing", {}).keys - %w[ios-development]).empty?
        @data = merge(@data, device)
      end
      if ci && ENV["GITHUB_ACTIONS"] == "true" && ENV["DIETER_CI_IOS_RUNTIME"]
        runtime = ENV.fetch("DIETER_CI_IOS_RUNTIME")
        raise PipelineError, "Invalid CI simulator runtime" unless runtime.match?(/\Acom\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+-\d+(?:-\d+)?\z/)
        profiles = %w[ios-iphone ios-ipad].to_h { |name| [name, {"runtime" => runtime}] }
        @data = merge(@data, {"profiles" => profiles})
      end
      validate!
      # Policy lives in its own tracked file and cannot be supplied locally.
      @policy = read(File.join(root, "fastlane/release-policy.json"))
    end

    def profile(name, component: nil, physical_explicit: true)
      profile = data.fetch("profiles").fetch(name) { raise PipelineError, "Unknown profile #{name}" }
      raise Unavailable, "Profile #{name} is disabled; configure fastlane/local.json" unless profile.fetch("enabled")
      actual = profile["component"] || profile.fetch("platform")
      raise PipelineError, "Profile #{name} belongs to #{actual}, not #{component}" if component && component != actual
      if profile["kind"] == "device"
        raise PipelineError, "Physical devices require an explicit profile" unless physical_explicit
        key = actual == "android" ? "serial" : "udid"
        raise Unavailable, "Profile #{name} requires an exact #{key}" unless profile[key].is_a?(String) && !profile[key].empty?
      end
      if profile["kind"] == "simulator" && (profile["runtime"].nil? || profile["runtime"].empty?)
        raise Unavailable, "Profile #{name} requires an installed exact simulator runtime; run config_init"
      end
      profile.merge("name" => name)
    end

    def default_profile(component)
      data.fetch("defaults").fetch("#{component}_profile") { raise PipelineError, "No default #{component} profile" }
    end

    def path(value)
      return nil if value.nil?
      value = File.join(Dir.home, value.delete_prefix("~/")) if value.start_with?("~/")
      File.expand_path(value, root)
    end

    def environment
      mapping = {"java_home" => "JAVA_HOME", "android_sdk" => "ANDROID_HOME", "developer_dir" => "DEVELOPER_DIR", "swift_jobs" => "DIETER_SWIFT_JOBS"}
      mapping.each_with_object({}) do |(key, variable), result|
        configured = data.fetch("toolchains")[key]
        if configured.nil?
          inherited = ENV[variable]
          if variable == "JAVA_HOME" && (inherited.nil? || !File.executable?(File.join(inherited, "bin/java")))
            bundled = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
            inherited = bundled if File.executable?(File.join(bundled, "bin/java"))
          elsif variable == "ANDROID_HOME" && inherited.nil?
            inherited = ENV["ANDROID_SDK_ROOT"]
            bundled = File.join(Dir.home, "Library/Android/sdk")
            inherited ||= bundled if File.directory?(bundled)
          end
          result[variable] = inherited if inherited && !inherited.empty?
          next
        end
        value = key == "swift_jobs" ? configured.to_s : path(configured)
        inherited = ENV[variable]
        if inherited && !inherited.empty?
          raise PipelineError, "#{variable} conflicts with local configuration" if local_loaded && key != "swift_jobs" && inherited != value
          value = inherited
        end
        result[variable] = value
      end
    end

    def policy
      @policy
    end

    private

    def read(path)
      raise PipelineError, "Configuration exceeds 256 KiB" if File.size(path) > 256 * 1024
      JSON.parse(File.read(path), object_class: UniqueObject, allow_duplicate_key: false, max_nesting: 32)
    rescue JSON::ParserError => error
      raise PipelineError, "Invalid JSON in #{File.basename(path)}: #{error.message}"
    end

    def merge(base, override)
      base.merge(override) { |_key, first, second| first.is_a?(Hash) && second.is_a?(Hash) ? merge(first, second) : second }
    end

    def validate!
      schema = File.join(root, "fastlane/config.schema.json")
      JSON::Validator.validate!(schema, data, strict: false)
    rescue JSON::Schema::ValidationError => error
      raise PipelineError, "Invalid pipeline configuration: #{error.message}"
    end
  end
end
