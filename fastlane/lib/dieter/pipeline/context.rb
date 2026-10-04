# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require_relative "../atomic"
require_relative "lease"
require_relative "process"

module Dieter
  class RunContext
    attr_reader :config, :root, :output, :environment, :private_dir, :secrets

    def initialize(config, output: nil)
      @config, @root = config, config.root
      @output = output ? File.expand_path(output, root) : File.join(root, "tmp/app-pipelines", SecureRandom.uuid)
      raise PipelineError, "Evidence directory already exists: #{@output}" if File.exist?(@output)
      FileUtils.mkdir_p(File.dirname(@output), mode: 0o700)
      Dir.mkdir(@output, 0o700)
      @private_dir = Dir.mktmpdir("dieter-pipeline-")
      @environment = config.environment
      @leases, @processes, @cleanup, @secrets = {}, [], [], []
    end

    def lease(resource, identity: nil)
      key = [resource, identity]
      return @leases[key] if @leases.key?(key)
      @leases[key] = Lease.new(resource, root: root, identity: identity)
    end

    def with_lease(resource, identity: nil)
      key = [resource, identity]
      inherited = @leases.key?(key)
      lease(resource, identity: identity)
      yield
    ensure
      @leases.delete(key)&.close unless inherited
    end

    def start(argv, **options)
      process = OwnedProcess.new(root, argv, environment: environment.merge(options.delete(:environment) || {}), secrets: secrets, **options)
      @processes << process
      process
    end

    def command(argv, timeout: 1200, **options)
      timeout = remaining(timeout)
      label = options.delete(:label) || File.basename(argv.first)
      check = options.key?(:check) ? options.delete(:check) : true
      start(argv, **options).wait(timeout: timeout, label: label, check: check)
    end

    def remaining(seconds)
      return seconds unless @deadline
      left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Interrupted, "Case deadline exceeded" unless left.positive?
      [seconds, left].min
    end

    def wait(process, timeout:, **options, &block)
      process.wait(timeout: remaining(timeout), **options, &block)
    end

    def with_deadline(seconds)
      previous = @deadline
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      yield
    ensure
      @deadline = previous
    end

    def during_cleanup
      previous, @deadline = @deadline, nil
      yield
    ensure
      @deadline = previous
    end

    def cleanup(&block)
      @cleanup << block
    end

    def close
      problems = []
      @cleanup.reverse_each do |operation|
        operation.call
      rescue StandardError => error
        problems << error.message
      end
      @processes.reverse_each do |process|
        process.stop
      rescue StandardError => error
        problems << error.message
      end
      @leases.values.reverse_each(&:close) if problems.empty?
      FileUtils.remove_entry_secure(private_dir) if problems.empty? && File.directory?(private_dir)
      Atomic.json(File.join(output, "cleanup.json"), {schema_version: 1, passed: problems.empty?, errors: problems})
      raise CleanupError, problems.join("; ") unless problems.empty?
    end
  end
end
