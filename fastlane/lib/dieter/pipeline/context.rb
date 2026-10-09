# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require_relative "../atomic"
require_relative "lease"
require_relative "process"

module Dieter
  class RunContext
    attr_reader :config, :root, :output, :environment, :private_dir, :secrets

    def initialize(config, output: nil, parent: nil)
      @config, @root = config, config.root
      @parent = parent
      @output = output ? File.expand_path(output, root) : File.join(root, "tmp/app-pipelines", SecureRandom.uuid)
      raise PipelineError, "Evidence directory already exists: #{@output}" if File.exist?(@output)
      FileUtils.mkdir_p(File.dirname(@output), mode: 0o700)
      Dir.mkdir(@output, 0o700)
      @private_dir = Dir.mktmpdir("dieter-pipeline-")
      @environment = parent ? parent.environment.dup : config.environment
      @leases, @processes, @cleanup, @secrets = {}, [], [], []
      @children = []
      parent&.register_child(self)
      @timings = []
    end

    def lease(resource, identity: nil)
      return @parent.lease(resource, identity: identity) if @parent
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
      measure(label) { start(argv, **options).wait(timeout: timeout, label: label, check: check) }
    end

    def measure(label)
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      passed = false
      value = yield
      passed = true
      value
    ensure
      @timings << {name: label, durationMs: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000).round, status: passed ? "passed" : "failed"}
      Atomic.json(File.join(output, "timings.json"), {version: 1, operations: @timings})
    end

    def remaining(seconds)
      return seconds unless @deadline
      left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Interrupted, "Case deadline exceeded" unless left.positive?
      [seconds, left].min
    end

    def wait(process, timeout:, **options, &block)
      measure(options[:label] || File.basename(process.argv.first)) { process.wait(timeout: remaining(timeout), **options, &block) }
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

    def register_child(child)
      @children << child
    end

    def close
      return if @closed
      problems = []
      @children.reverse.each do |child|
        child.close
        @children.delete(child)
      rescue StandardError => error
        problems << error.message
      end
      @cleanup.reverse.each do |operation|
        operation.call
        @cleanup.delete(operation)
      rescue StandardError => error
        problems << error.message
      end
      @processes.reverse.each do |process|
        process.stop
        @processes.delete(process)
      rescue StandardError => error
        problems << error.message
      end
      @leases.values.reverse_each(&:close) if problems.empty?
      FileUtils.remove_entry_secure(private_dir) if problems.empty? && File.directory?(private_dir)
      Atomic.json(File.join(output, "cleanup.json"), {schema_version: 1, passed: problems.empty?, errors: problems})
      raise CleanupError, problems.join("; ") unless problems.empty?
      @closed = true
    end
  end
end
