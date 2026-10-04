# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "../atomic"
require_relative "../errors"
require_relative "../config"

module Dieter
  class ReleaseIdentity
    KEYS = %w[schema_version repository source_revision version tag native_build reserved_at policy_sha256].freeze
    # CFBundleVersion permits a four-digit major and two-digit minor/patch.
    MAX_COUNTER = 99_990_000
    attr_reader :data

    def initialize(value, policy: nil)
      raise PipelineError, "Invalid release identity keys" unless value.is_a?(Hash) && value.keys.sort == KEYS.sort
      raise PipelineError, "Invalid release identity types" unless (KEYS - %w[schema_version native_build]).all? { |key| value[key].is_a?(String) }
      raise PipelineError, "Invalid release source" unless value["schema_version"].is_a?(Integer) && value["schema_version"] == 1 && value["source_revision"].match?(/\A[0-9a-f]{40}\z/)
      raise PipelineError, "Invalid release repository" unless value["repository"].match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
      raise PipelineError, "Canonical release must be numeric SemVer" unless value["version"].bytesize <= 64 && value["version"].match?(/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/) && value["tag"] == "v#{value['version']}"
      raise PipelineError, "Invalid native counter" unless value["native_build"].is_a?(Integer) && (1..MAX_COUNTER).cover?(value["native_build"])
      raise PipelineError, "Invalid release policy digest" unless value["policy_sha256"].match?(/\A[0-9a-f]{64}\z/)
      timestamp = value["reserved_at"]
      begin
        valid_time = timestamp.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) && Time.iso8601(timestamp).utc.iso8601 == timestamp
      rescue ArgumentError
        valid_time = false
      end
      raise PipelineError, "Invalid release reservation time" unless valid_time
      if policy
        raise PipelineError, "Release repository mismatch" unless value["repository"] == policy.fetch("repository")
        raise PipelineError, "Release policy changed under reserved identity" unless value["policy_sha256"] == Digest::SHA256.hexdigest(JSON.generate(policy))
        raise PipelineError, "Release counter/line mismatch" unless value["version"] == "#{policy.fetch('release_line')}.#{value.fetch('native_build')}"
      end
      @data = value.transform_values { |item| item.is_a?(String) ? item.dup.freeze : item }.freeze
    end

    def self.load(path, **options)
      raise PipelineError, "Identity must be a bounded regular file" if File.symlink?(path) || !File.file?(path) || File.size(path) > 16 * 1024
      new(JSON.parse(File.read(path), object_class: UniqueObject, allow_duplicate_key: false), **options)
    rescue JSON::ParserError
      raise PipelineError, "Invalid release identity JSON"
    end

    def version = data.fetch("version")
    def tag = data.fetch("tag")
    def source = data.fetch("source_revision")
    def build = data.fetch("native_build").to_s
    def apple_build
      counter = data.fetch("native_build") - 1
      "#{counter / 10_000 + 1}.#{counter / 100 % 100}.#{counter % 100}"
    end
    def digest = Digest::SHA256.hexdigest(JSON.generate(data))
    def write(path) = Atomic.json(path, data)
    def environment
      {"DIETER_RELEASE_VERSION" => version, "DIETER_RELEASE_VERSION_CODE" => build, "RELEASE_VERSION" => version, "BUILD_NUMBER" => apple_build, "IOS_VERSION" => version, "IOS_BUILD_NUMBER" => apple_build}
    end
  end
end
