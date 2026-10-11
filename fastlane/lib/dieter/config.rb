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
      if ci && ENV["GITHUB_ACTIONS"] == "true" && ENV["DIETER_CI_IOS_RUNTIME"]
        runtime = ENV.fetch("DIETER_CI_IOS_RUNTIME")
        unless runtime.match?(/\Acom\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+-\d+(?:-\d+)?\z/)
          raise PipelineError, "Invalid CI simulator runtime"
        end
        profiles = %w[ios-iphone ios-ipad].to_h { |name| [name, { "runtime" => runtime }] }
        @data = merge(@data, { "profiles" => profiles })
      end
      validate!
      # Policy lives in its own tracked file and cannot be supplied locally.
      @policy = read(File.join(root, "fastlane/release-policy.json"))
    end

    def profile(name, component: nil, physical_explicit: true)
      profile =
        data.fetch("profiles").fetch(name) { raise PipelineError, "Unknown profile #{name}" }
      unless profile.fetch("enabled")
        raise Unavailable, "Profile #{name} is disabled; configure fastlane/local.json"
      end
      actual = profile["component"] || profile.fetch("platform")
      if component && component != actual
        raise PipelineError, "Profile #{name} belongs to #{actual}, not #{component}"
      end
      if profile["kind"] == "device"
        raise PipelineError, "Physical devices require an explicit profile" unless physical_explicit
        unless profile["serial"].is_a?(String) && !profile["serial"].empty?
          raise Unavailable, "Profile #{name} requires an exact serial"
        end
      end
      if profile["kind"] == "simulator" && (profile["runtime"].nil? || profile["runtime"].empty?)
        raise Unavailable,
              "Profile #{name} requires an installed exact simulator runtime; run config_init"
      end
      profile.merge("name" => name)
    end

    def default_profile(component)
      data
        .fetch("defaults")
        .fetch("#{component}_profile") { raise PipelineError, "No default #{component} profile" }
    end

    def path(value)
      return nil if value.nil?
      value = File.join(Dir.home, value.delete_prefix("~/")) if value.start_with?("~/")
      File.expand_path(value, root)
    end

    def environment
      mapping = {
        "java_home" => "JAVA_HOME",
        "android_sdk" => "ANDROID_HOME",
        "developer_dir" => "DEVELOPER_DIR",
        "swift_jobs" => "DIETER_SWIFT_JOBS"
      }
      # Bundler's vendor/bundle is not a Go vendor tree. Resolve the authoritative
      # module graph on local runs as well as CI, without changing global flags.
      mapping.each_with_object(
        { "GOFLAGS" => [ENV["GOFLAGS"], "-mod=mod"].compact.join(" ") }
      ) do |(key, variable), result|
        configured = data.fetch("toolchains")[key]
        if configured.nil?
          inherited = ENV[variable]
          if variable == "JAVA_HOME" &&
               (inherited.nil? || !File.executable?(File.join(inherited, "bin/java")))
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
          if local_loaded && key != "swift_jobs" && inherited != value
            raise PipelineError, "#{variable} conflicts with local configuration"
          end
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
      JSON.parse(
        File.read(path),
        object_class: UniqueObject,
        allow_duplicate_key: false,
        max_nesting: 32
      )
    rescue JSON::ParserError => error
      raise PipelineError, "Invalid JSON in #{File.basename(path)}: #{error.message}"
    end

    def merge(base, override)
      base.merge(override) do |_key, first, second|
        first.is_a?(Hash) && second.is_a?(Hash) ? merge(first, second) : second
      end
    end

    def validate!
      schema = File.join(root, "fastlane/config.schema.json")
      JSON::Validator.validate!(schema, data, strict: false)
    rescue JSON::Schema::ValidationError => error
      raise PipelineError, "Invalid pipeline configuration: #{error.message}"
    end
  end
end
