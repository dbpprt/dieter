# frozen_string_literal: true

require "digest"
require_relative "../atomic"

module Dieter
  # Observe stalled unsigned checks only on disposable hosted runners. Thread
  # dumps retain evidence before the normal deadline cancels the owned command;
  # they never restart a daemon, extend a deadline or turn failure into success.
  class HostedGradleDiagnostics
    def initialize(context, name)
      @context, @name = context, name
      @digest, @changed_at, @captures = nil, monotonic, 0
    end

    def progress(process)
      return unless ENV["GITHUB_ACTIONS"] == "true" && ENV["RUNNER_ENVIRONMENT"] == "github-hosted"
      digest = Digest::SHA256.hexdigest(process.output)
      if digest != @digest
        @digest, @changed_at = digest, monotonic
      end
      return if @captures >= 2 || monotonic - @changed_at < 300 * (@captures + 1)
      @captures += 1
      @context.with_deadline(90) { capture }
    rescue StandardError => error
      # Diagnostics are optional; preserve the authoritative command result.
      Atomic.write(File.join(@context.output, "#{@name}-diagnostic-error.txt"), error.class.name)
    end

    def capture
      directory = File.join(@context.output, "#{@name}-stall-#{@captures}")
      FileUtils.mkdir_p(directory, mode: 0o700)
      @context.command(%w[ps -eo pid,ppid,stat,etime,pcpu,pmem,rss,comm], timeout: 15, log: File.join(directory, "processes.log"))
      @context.command(["df", "-h", @context.root], timeout: 15, log: File.join(directory, "disk.log"))
      %w[meminfo pressure/memory].each do |name|
        path = "/proc/#{name}"
        Atomic.write(File.join(directory, name.tr('/', '-') + ".log"), File.read(path)) if File.file?(path)
      end
      java = @context.environment.fetch("JAVA_HOME")
      jps = @context.command([File.join(java, "bin/jps"), "-l"], timeout: 15)
      # jps -l omits JVM arguments. Never dump unrelated JVMs or environments.
      pids = jps.lines.filter_map { |line| line[/\A(\d+) org\.gradle\.launcher\.daemon\.bootstrap\.GradleDaemon\s*\z/, 1] }
      pids.first(4).each do |pid|
        %w[Thread.print GC.heap_info].each do |operation|
          @context.command([File.join(java, "bin/jcmd"), pid, operation], timeout: 30, log: File.join(directory, "gradle-#{pid}-#{operation}.log"))
        end
      end
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
