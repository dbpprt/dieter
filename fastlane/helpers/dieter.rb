# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "tmpdir"

# Shared plumbing of the Dieter lanes: configuration, identity, versions,
# owned subprocesses, leases and ownership journals. Everything else is a
# Fastlane action or a plain toolchain command.
module Dieter
  ROOT = File.expand_path("../..", __dir__)
  Unavailable = Class.new(StandardError)

  module_function

  def path(*parts) = File.join(ROOT, *parts)
  def ci? = ENV["GITHUB_ACTIONS"] == "true" || ENV["CI"] == "true"
  def darwin? = RUBY_PLATFORM.include?("darwin")

  def identity = @identity ||= JSON.parse(File.read(path("config/identity.json")))
  def policy = @policy ||= JSON.parse(File.read(path("fastlane/release-policy.json")))

  # fastlane/config.json, merged with the ignored fastlane/local.json except in CI.
  def config
    @config ||=
      begin
        base = JSON.parse(File.read(path("fastlane/config.json")))
        local = path("fastlane/local.json")
        ci? || !File.file?(local) ? base : deep_merge(base, JSON.parse(File.read(local)))
      end
  end

  def deep_merge(base, override)
    base.merge(override) { |_key, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b }
  end

  # A named target profile. Physical devices are never a default: they need an
  # explicit profile naming one exact serial.
  def profile(platform, name = nil)
    explicit = !name.to_s.empty?
    name = config.fetch("defaults").fetch(platform) unless explicit
    value = config.fetch("profiles").fetch(name) { raise ArgumentError, "Unknown profile #{name}" }
    unless value["platform"] == platform
      raise ArgumentError, "Profile #{name} is for #{value["platform"]}"
    end
    raise Unavailable, "Profile #{name} is disabled" if value["enabled"] == false
    if value["kind"] == "device"
      raise ArgumentError, "Physical devices require an explicit profile:#{name}" unless explicit
      if value["serial"].to_s.empty?
        raise Unavailable, "Profile #{name} needs an exact serial in fastlane/local.json"
      end
    end
    value.merge("name" => name)
  end

  # --- Versions ---------------------------------------------------------------

  # Local and CI builds: next patch after the newest release tag, marked dev.
  def dev_version
    return ENV["DIETER_RELEASE_VERSION"] unless ENV["DIETER_RELEASE_VERSION"].to_s.empty?
    tags = capture("git", "tag", "--list", "v*", "--sort=-version:refname").split
    major, minor, patch =
      (tags.find { |tag| tag.match?(/\Av\d+\.\d+\.\d+\z/) } || "v0.0.0")
        .delete_prefix("v")
        .split(".")
        .map(&:to_i)
    count = capture("git", "rev-list", "--count", "HEAD").strip
    sha = capture("git", "rev-parse", "--short=8", "HEAD").strip
    dirty = capture("git", "status", "--porcelain", "--untracked-files=no").empty? ? "" : ".dirty"
    "#{major}.#{minor}.#{patch + 1}-dev.#{count}+#{sha}#{dirty}"
  end

  # The next release on the policy's release line. The patch number is one
  # counter across every line, so Android versionCode and Apple build numbers
  # keep increasing when the line moves (v0.4.399 -> v0.5.400).
  def next_release(tags, line: policy.fetch("release_line"))
    counters = tags.filter_map { |tag| tag[/\Av\d+\.\d+\.(\d+)\z/, 1]&.to_i }
    counter = (counters.max || 0) + 1
    {
      "version" => "#{line}.#{counter}",
      "tag" => "v#{line}.#{counter}",
      "build" => counter,
      "apple_build" => apple_build(counter)
    }
  end

  # CFBundleVersion allows a four-digit major and two-digit minor/patch, so the
  # monotonic counter is encoded: 1 -> 1.0.0, 413 -> 1.4.12, 10_001 -> 2.0.0.
  def apple_build(counter)
    raise ArgumentError, "Build counter out of range" unless (1..99_990_000).cover?(counter)
    value = counter - 1
    "#{value / 10_000 + 1}.#{value / 100 % 100}.#{value % 100}"
  end

  # --- Processes ----------------------------------------------------------------

  def capture(*argv, chdir: ROOT)
    out = IO.popen(argv, chdir: chdir, err: File::NULL, &:read)
    raise "#{argv.first} failed" unless $?.success?
    out
  end

  # Runs one exact argv in the repository root through Fastlane's sh (streamed
  # and returned). env is an optional leading hash.
  # Runs argv in the repository root, or in chdir.
  def sh(*argv, env: {}, log: true, chdir: ROOT)
    Dir.chdir(chdir) { Fastlane::Actions.sh(env, *argv.map(&:to_s), log: log) }
  end

  def group(title)
    puts(ci? ? "::group::#{title}" : "==> #{title}")
    yield
  ensure
    puts "::endgroup::" if ci?
  end

  # A background process in its own process group; stop signals only that group.
  class Owned
    attr_reader :pid, :log

    def initialize(argv, log:, env: {})
      @log = log
      FileUtils.mkdir_p(File.dirname(log))
      @pid =
        Process.spawn(
          env,
          *argv.map(&:to_s),
          :chdir => ROOT,
          :pgroup => true,
          :in => File::NULL,
          %i[out err] => [log, "w"]
        )
      @status = nil
    end

    def running?
      return false if @status
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      @status = status if status
      @status.nil?
    end

    def status
      running?
      @status
    end

    def wait(timeout)
      deadline = Dieter.clock + timeout
      sleep 0.2 while running? && Dieter.clock < deadline
      raise Unavailable, "#{File.basename(log)} did not finish within #{timeout}s" if running?
      @status
    end

    def stop(grace: 15)
      return unless running?
      Process.kill("TERM", -pid)
      deadline = Dieter.clock + grace
      sleep 0.2 while running? && Dieter.clock < deadline
      Process.kill("KILL", -pid) if running?
      wait(10)
    rescue Errno::ESRCH
      nil
    end
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Cleanup callbacks run in reverse order; every failure is reported and fails
  # the run after all of them ran.
  class Cleanup
    def initialize = @steps = []
    def add(&block) = @steps << block

    def run
      errors = []
      @steps.reverse_each do |step|
        step.call
      rescue StandardError => e
        errors << e.message
      end
      @steps.clear
      raise "Cleanup failed: #{errors.join("; ")}" unless errors.empty?
    end
  end

  def with_cleanup
    cleanup = Cleanup.new
    failed = false
    yield cleanup
  rescue Exception # rubocop:disable Lint/RescueException
    failed = true
    raise
  ensure
    begin
      cleanup&.run
    rescue StandardError => e
      raise unless failed
      warn e.message
    end
  end

  # --- Leases and journals ------------------------------------------------------

  # One exclusive flock per resource (and exact identity such as an ADB serial).
  # A held lease reports its owner PID; never delete a lease file to bypass it.
  class Lease
    def self.path(resource, identity = nil)
      user = Process.uid
      case resource
      when "android-device", "android-avd", "android-runtime"
        File.join(
          Dir.tmpdir,
          "#{resource}-leases-#{user}",
          "#{Digest::SHA256.hexdigest(identity.to_s)}.lock"
        )
      when "mac-desktop"
        File.join(Dir.tmpdir, "dieter-mac-e2e-#{user}.lock")
      when "apple-signing", "ios-simulator"
        File.join(Dir.tmpdir, "dieter-#{resource}-#{user}.lock")
      else
        File.join(
          Dir.tmpdir,
          "dieter-#{resource}-#{Digest::SHA256.hexdigest(File.realpath(ROOT))}.lock"
        )
      end
    end

    def self.hold(resource, identity = nil)
      lease = new(resource, identity)
      yield
    ensure
      lease&.release
    end

    def initialize(resource, identity = nil)
      path = self.class.path(resource, identity)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      @file = File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
      unless @file.flock(File::LOCK_EX | File::LOCK_NB)
        owner = @file.read(512).to_s.strip
        @file.close
        raise Unavailable,
              "#{resource} #{identity} is busy (owner #{owner}); inspect that PID and keep its lock"
      end
      @file.truncate(0)
      @file.write(JSON.generate(pid: Process.pid, resource: resource, owner: "dieter-pipeline"))
      @file.flush
    end

    def release
      return if @file.closed?
      @file.flock(File::LOCK_UN)
      @file.close
    end
  end

  # Ownership journals record processes and devices a run started, so an
  # interrupted run is recovered or inspected, never guessed at.
  module Journal
    module_function

    def path(name) = Dieter.path("tmp/e2e-cache", name)
    def read(file) = File.file?(file) ? JSON.parse(File.read(file)) : nil

    def write(file, value)
      FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
      temporary = "#{file}.#{Process.pid}.tmp"
      File.write(temporary, JSON.pretty_generate(value) + "\n", perm: 0o600)
      File.rename(temporary, file)
    end

    def delete(file) = FileUtils.rm_f(file)
  end

  # Process identity that survives exec but not PID reuse: start time + argv.
  def process_signature(pid)
    IO.popen(["ps", "-p", pid.to_s, "-o", "lstart=,command="], err: File::NULL, &:read).strip
  end

  # --- Files --------------------------------------------------------------------

  # A run's evidence directory (logs, JUnit, screenshots) under tmp/pipeline.
  def evidence(name)
    directory =
      path(
        "tmp/pipeline",
        "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{name}-#{SecureRandom.hex(3)}"
      )
    FileUtils.mkdir_p(directory, mode: 0o700)
    directory
  end

  # Decodes a base64 secret from the environment into a private file.
  def secret_file(variable, name)
    value = ENV.fetch(variable) { raise Unavailable, "Missing #{variable}" }
    directory = (@secrets ||= Dir.mktmpdir("dieter-secrets-"))
    file = File.join(directory, name)
    File.binwrite(file, Base64.strict_decode64(value.strip))
    File.chmod(0o600, file)
    file
  end

  def sha256(file) = Digest::SHA256.file(file).hexdigest

  def github_output(values)
    return unless ENV["GITHUB_OUTPUT"]
    File.open(ENV["GITHUB_OUTPUT"], "a") do |file|
      values.each { |key, value| file.puts("#{key}=#{value}") }
    end
  end
end
