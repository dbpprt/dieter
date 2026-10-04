# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "../errors"

module Dieter
  class OwnedProcess
    LIMIT = 4 * 1024 * 1024
    LINE_LIMIT = 64 * 1024
    attr_reader :pid, :status, :argv

    def initialize(root, argv, environment: {}, input: nil, binary: false, log: nil, secrets: [], output_limit: nil, stream: nil)
      raise PipelineError, "Expected nonempty exact argv" unless argv.is_a?(Array) && argv.all? { |v| v.is_a?(String) && !v.include?("\0") } && !argv.empty?
      @argv, @root, @binary, @log, @secrets = argv, root, binary, log, secrets
      # Fixture readiness and structured/binary stdout must remain private.
      @stream = stream.nil? ? !binary && !log.nil? : stream && !binary
      @limit = output_limit || (binary ? 32 * 1024 * 1024 : LIMIT)
      @stdout, @stderr, @overflow = "".b, "".b, false
      @mutex = Mutex.new
      @stdin, stdout, stderr, @waiter = Open3.popen3(environment, *argv, chdir: root, pgroup: true)
      @pid = @waiter.pid
      @readers = [read(stdout, :@stdout), read(stderr, :@stderr)]
      @writer = Thread.new do
        @stdin.binmode
        @stdin.write(input) if input
      rescue Errno::EPIPE, IOError
        # The authoritative command status is checked after wait.
      ensure
        @stdin.close rescue nil
      end
    end

    def stdout
      @mutex.synchronize { @stdout.dup }
    end

    def stderr
      @mutex.synchronize { @stderr.dup }
    end

    def output
      redact(stdout + stderr)
    end

    def running?
      @waiter.alive?
    end

    def wait(timeout:, label: File.basename(argv.first), check: true)
      deadline = clock + timeout
      next_progress = clock + 30
      while running?
        if clock >= deadline
          stop
          raise Interrupted, "#{label} exceeded #{timeout}s"
        end
        if clock >= next_progress
          puts "Still running #{label}; deadline in #{(deadline - clock).round}s"
          Atomic.write(@log, output) if @log
          yield self if block_given?
          next_progress = clock + 30
        end
        @waiter.join(0.1)
      end
      @status = @waiter.value
      finish_io
      raise PipelineError, "Binary output exceeds #{@limit} bytes" if @binary && @overflow
      if check && !@status.success?
        raise PipelineError, "#{label} exited #{@status.exitstatus || @status.termsig}: #{output[-3000..] || output}"
      end
      @binary ? stdout : output
    rescue Interrupt, SignalException
      stop
      raise Interrupted, "#{label} canceled"
    ensure
      if @log
        Atomic.write(@log, output)
      end
    end

    def stop
      # The group remains ours while descendants keep its pipes open, even if
      # the leader has exited (for example Fastlane's timed-out settings query).
      # A live leader must still prove the exact group identity before signaling.
      return finish_io if !running? && io_finished?
      raise CleanupError, "Owned child #{@pid} changed its process group" if running? && Process.getpgid(@pid) != @pid
      signal("INT")
      return finish_io if wait_for_exit(15)
      signal("TERM")
      return finish_io if wait_for_exit(10)
      raise CleanupError, "Owned child #{@pid} did not exit; preserve resources and diagnostics"
    rescue Errno::ESRCH
      finish_io
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def signal(kind)
      Process.kill(kind, -@pid)
    rescue Errno::ESRCH
      nil
    end

    def io_finished?
      [@writer, *@readers].none?(&:alive?)
    end

    def wait_for_exit(seconds)
      deadline = clock + seconds
      until !running? && io_finished?
        return false if clock >= deadline
        sleep 0.05
      end
      true
    end

    def read(io, variable)
      Thread.new do
        io.binmode
        pending = "".b
        dropping = false
        loop do
          chunk = io.readpartial(16 * 1024)
          @mutex.synchronize do
            value = instance_variable_get(variable) + chunk
            @overflow ||= value.bytesize > @limit
            instance_variable_set(variable, value.byteslice(-@limit, @limit) || value)
          end
          next unless @stream
          pending << chunk
          while (newline = pending.index("\n"))
            line = pending.slice!(0, newline + 1)
            emit(variable, line) unless dropping || line.bytesize > LINE_LIMIT
            dropping = false
          end
          if pending.bytesize > LINE_LIMIT
            # Never print a partial secret split across pipe reads or long lines.
            emit(variable, "<oversized output line omitted>\n") unless dropping
            pending.clear
            dropping = true
          end
        end
      rescue EOFError, IOError
        emit(variable, pending) if @stream && !dropping && pending && !pending.empty?
        nil
      ensure
        io.close rescue nil
      end
    end

    def emit(variable, value)
      $stdout.write("  #{variable == :@stdout ? 'stdout' : 'stderr'}: #{redact(value)}")
      $stdout.flush
    end

    def finish_io
      [@writer, *@readers].each do |thread|
        next if thread.join(5)
        # A descendant retaining the pipes is not a successful cleanup.
        raise CleanupError, "Owned process #{@pid} descendants retained input/output pipes"
      end
      @status ||= @waiter.value unless running?
      Atomic.write(@log, output) if @log
    end

    def redact(value)
      text = value.dup.force_encoding(Encoding::UTF_8).scrub
      @secrets.each { |secret| text = text.gsub(secret, "<redacted>") unless secret.nil? || secret.empty? }
      text.gsub(/isolated_[0-9a-fA-F]{48}/, "<redacted>")
    end
  end
end
