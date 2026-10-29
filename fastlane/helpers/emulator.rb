# frozen_string_literal: true

require "rbconfig"
require "timeout"
require_relative "dieter"

module Dieter
  # One exact AVD on one exact serial, either borrowed (already running and
  # verified) or owned by this run. Owned emulators boot without snapshots and
  # are journaled; only their own process group is ever signalled.
  class Emulator
    attr_reader :serial

    def self.sdk
      sdk = ENV["ANDROID_HOME"] || ENV["ANDROID_SDK_ROOT"]
      sdk ||= File.join(Dir.home, "Library/Android/sdk") if File.directory?(
        File.join(Dir.home, "Library/Android/sdk")
      )
      raise Unavailable, "Set ANDROID_HOME to an Android SDK" unless sdk && File.directory?(sdk)
      sdk
    end

    def initialize(profile)
      @profile, @serial, @avd = profile, profile.fetch("serial"), profile.fetch("avd")
      @port = @serial[/\Aemulator-(\d+)\z/, 1].to_i
      unless (5554..5682).cover?(@port) && @port.even?
        raise ArgumentError, "Emulator serial must be emulator-PORT with an even port 5554..5682"
      end
      raise ArgumentError, "Unsafe AVD name" unless @avd.match?(/\A[A-Za-z0-9_.-]+\z/)
      @host_sdk = self.class.sdk
      if (storage = profile["storage_dir"])
        unless storage.match?(/\A\.android(?:-[A-Za-z0-9_-]+)?\z/)
          raise ArgumentError, "storage_dir must name a project .android folder"
        end
        @storage = Dieter.path(storage)
        @sdk, @registry = File.join(@storage, "sdk"), File.join(@storage, "avd")
        @env = {
          "ANDROID_HOME" => @sdk,
          "ANDROID_SDK_ROOT" => @sdk,
          "ANDROID_USER_HOME" => File.join(@storage, "user"),
          "ANDROID_EMULATOR_HOME" => File.join(@storage, "user"),
          "ANDROID_AVD_HOME" => @registry
        }
      else
        @sdk = @host_sdk
        @registry =
          File.expand_path(
            ENV["ANDROID_AVD_HOME"] ||
              File.join(ENV["ANDROID_USER_HOME"] || File.join(Dir.home, ".android"), "avd")
          )
        @env = { "ANDROID_AVD_HOME" => @registry }
      end
      @journal =
        Journal.path(
          "emulator-#{Digest::SHA256.hexdigest([@registry, @avd, @serial].join("\0"))}.json"
        )
    end

    def adb(*args, timeout: 30)
      IO
        .popen(
          [File.join(@host_sdk, "platform-tools/adb"), "-s", @serial, *args],
          err: File::NULL
        ) { |io| Timeout.timeout(timeout) { io.read } }
        .to_s
    end

    def shell(*args) = adb("shell", Shellwords.join(args))
    def state = adb("get-state").strip

    # Copies the emulator runtime and system image from the host SDK into the
    # project storage once; never downloads or updates packages.
    def setup
      raise ArgumentError, "Emulator setup requires storage_dir" unless @storage
      [
        "cmdline-tools/latest",
        "platform-tools",
        "emulator",
        system_image.tr(";", "/")
      ].each do |package|
        source, target = File.join(@host_sdk, package), File.join(@sdk, package)
        next if File.file?(File.join(target, "package.xml"))
        unless File.file?(File.join(source, "package.xml"))
          raise Unavailable, "Install #{package} in the host SDK first (#{source})"
        end
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        staging = "#{target}.partial-#{Process.pid}"
        system("/bin/cp", "-R", source, staging, exception: true)
        File.rename(staging, target)
      end
      %w[avd user].each { |folder| FileUtils.mkdir_p(File.join(@storage, folder), mode: 0o700) }
      puts "Project emulator runtime ready in #{@storage}"
    end

    # Borrows a healthy running emulator of exactly this AVD, or launches one
    # owned by this run (registered with cleanup). warm keeps it for later runs.
    def start(cleanup, evidence, warm: false)
      began = Dieter.clock
      running = state == "device"
      recover(borrow: running)
      if running
        exact_avd!
        puts "Borrowing running #{@avd} on #{@serial}"
      else
        if @profile["lifecycle"] == "borrow"
          raise Unavailable, "#{@serial} is not running; profile #{@profile["name"]} only borrows"
        end
        avd_lease = Lease.new("android-avd", [@registry, @avd].join("\0"))
        cleanup.add { avd_lease.release }
        if IO
             .popen(%w[ps -axo command=], &:read)
             .lines
             .any? { |line|
               line.match?(%r{qemu-system|/emulator(\s|$)}) && line.include?("@#{@avd}")
             }
          raise Unavailable, "An unaccounted emulator runs #{@avd}; inspect its owner first"
        end
        create_avd unless File.file?(File.join(@registry, "#{@avd}.ini"))
        argv = [
          File.join(@sdk, "emulator/emulator"),
          "@#{@avd}",
          "-port",
          @port.to_s,
          "-gpu",
          @profile.fetch("renderer", "auto"),
          "-no-snapshot",
          "-no-audio",
          "-no-boot-anim",
          "-no-metrics"
        ]
        argv << "-no-window" unless @profile["visible"]
        @process = Owned.new(argv, log: File.join(evidence, "emulator.log"), env: @env)
        cleanup.add { close }
        Journal.write(
          @journal,
          "pid" => @process.pid,
          "signature" => Dieter.process_signature(@process.pid),
          "controller_pid" => Process.pid,
          "controller_signature" => Dieter.process_signature(Process.pid),
          "warm" => warm,
          "serial" => @serial,
          "avd" => @avd,
          "log" => @process.log
        )
      end
      await_boot
      puts "Emulator #{@serial} ready (#{running ? "borrowed" : "owned"}, #{(Dieter.clock - began).round}s)"
      self
    end

    # Keeps a warm owned emulator until this process is signalled; the
    # caller's cleanup then closes it.
    def run
      raise Unavailable, "The emulator is borrowed; its owner keeps it" unless @process
      sleep 1 while @process.running?
      raise Unavailable, "The managed emulator exited; see #{@process.log}"
    end

    # Asks a verified warm controller to clean up its own emulator.
    def stop_warm
      owner = Journal.read(@journal) or raise Unavailable, "No warm emulator journal for #{@avd}"
      unless owner["warm"] == true && owner["serial"] == @serial && owner["avd"] == @avd
        raise Unavailable, "Journal is not a warm emulator"
      end
      unless Dieter.process_signature(owner["controller_pid"]) == owner["controller_signature"] &&
               Dieter.process_signature(owner["pid"]).split.first(5) ==
                 owner["signature"].to_s.split.first(5)
        raise Unavailable, "Warm owner identity changed; preserve #{@journal} and inspect"
      end
      exact_avd!
      Process.kill("TERM", owner["controller_pid"])
      deadline = Dieter.clock + 90
      sleep 1 until (!File.file?(@journal) && state.empty?) || Dieter.clock > deadline
      if File.file?(@journal)
        raise "Warm shutdown did not complete; inspect #{owner["log"]} and keep the journal"
      end
      puts "Warm emulator #{@serial} closed by its owner"
    end

    def close
      return unless @process
      died = !@process.running?
      @process.stop(grace: 30)
      unless state.empty?
        raise "#{@serial} is still attached after owned shutdown; keep #{@journal}"
      end
      Journal.delete(@journal)
      @process = nil
      raise "The managed emulator exited unexpectedly" if died
    end

    # The guest is this exact AVD, booted, unlocked and without an ANR dialog.
    def await_boot
      deadline = Dieter.clock + @profile.fetch("boot_timeout", 180)
      loop do
        if @process && !@process.running?
          raise Unavailable, "The emulator exited during boot; see #{@process.log}"
        end
        if state == "device" && shell("getprop", "sys.boot_completed").strip == "1" &&
             shell("getprop", "init.svc.bootanim").strip == "stopped" &&
             shell("pm", "path", "android").include?("package:")
          exact_avd!
          shell("input", "keyevent", "KEYCODE_WAKEUP")
          shell("wm", "dismiss-keyguard")
          return if focused_window&.include?("Window{")
        end
        raise Unavailable, "Emulator boot exceeded its deadline" if Dieter.clock > deadline
        sleep 2
      end
    end

    def focused_window
      focus =
        shell("dumpsys", "window", "displays").lines.find { |line| line.include?("mCurrentFocus=") }
      if focus&.match?(/Application (?:Not Responding|Error):/)
        raise Unavailable, "A system error dialog blocks #{@serial}: #{focus.strip}"
      end
      focus
    end

    def exact_avd!
      actual = adb("emu", "avd", "name").delete("\r").lines.first.to_s.strip
      unless actual == @avd
        raise Unavailable, "#{@serial} runs AVD #{actual.inspect}, expected #{@avd}"
      end
    end

    private

    def system_image
      image = @profile["system_image"] or raise Unavailable, "Configure system_image for #{@avd}"
      image.sub(
        /;native\z/,
        RbConfig::CONFIG["host_cpu"].match?(/arm|aarch64/) ? ";arm64-v8a" : ";x86_64"
      )
    end

    # Creates a missing test AVD (Pixel 2 hardware at 720p, 4 GiB userdata).
    def create_avd
      manager = File.join(@sdk, "cmdline-tools/latest/bin/avdmanager")
      unless File.executable?(manager)
        raise Unavailable, "Install Android SDK command-line tools (latest)"
      end
      FileUtils.mkdir_p(@registry, mode: 0o700)
      IO.popen(
        @env,
        [
          manager,
          "create",
          "avd",
          "--name",
          @avd,
          "--package",
          system_image,
          "--device",
          "pixel_2"
        ],
        "r+"
      ) do |io|
        io.puts("no")
        io.close_write
        io.read
      end
      raise "avdmanager could not create #{@avd}" unless $?.success?
      config = File.join(@registry, "#{@avd}.avd/config.ini")
      settings = {
        "disk.dataPartition.size" => "4G",
        "hw.lcd.width" => "720",
        "hw.lcd.height" => "1280",
        "hw.lcd.density" => "280"
      }
      lines = File.readlines(config).reject { |line| settings.key?(line.split("=", 2).first.strip) }
      File.write(config, lines.join + settings.map { |key, value| "#{key}=#{value}\n" }.join)
    end

    # A journal from an earlier run: borrow from a live warm controller, drop it
    # when its emulator is gone, otherwise stop and ask for inspection.
    def recover(borrow:)
      owner = Journal.read(@journal) or return
      alive =
        Dieter.process_signature(owner["pid"]).split.first(5) ==
          owner["signature"].to_s.split.first(5) && !owner["signature"].to_s.empty?
      if borrow && alive &&
           Dieter.process_signature(owner["controller_pid"]) == owner["controller_signature"]
        return
      end
      return Journal.delete(@journal) if !alive && state.empty?
      raise Unavailable,
            "Unfinished emulator session #{owner["pid"]}; keep #{@journal} and inspect #{owner["log"]}"
    end
  end
end
