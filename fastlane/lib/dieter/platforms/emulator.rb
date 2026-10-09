# frozen_string_literal: true

require "digest"
require "shellwords"
require "rbconfig"

module Dieter
  # Exact AVD/serial, borrowed or owned for a RunContext. Reuse userdata,
  # never load/save fragile graphics snapshots. Only signal owned processes.
  class AndroidEmulator
    def initialize(context, sdk, target)
      @context, @sdk, @source_sdk, @target = context, sdk, sdk, target
      @serial, @avd = target.fetch("serial"), target.fetch("avd")
      @port = /\Aemulator-(\d+)\z/.match(@serial.to_s)&.captures&.first&.to_i
      raise PipelineError, "Emulator serial must select an even port 5554..5682" unless @port && (5554..5682).cover?(@port) && @port.even?
      raise PipelineError, "Unsafe AVD name" unless @avd.is_a?(String) && @avd.match?(/\A[A-Za-z0-9_.-]+\z/)
      @environment = {}
      if (storage = target["storage_dir"])
        raise PipelineError, "storage_dir must name a project .android folder" unless storage.match?(/\A\.android(?:-[A-Za-z0-9_-]+)?\z/)
        @storage = File.join(File.realpath(context.root), storage)
        raise PipelineError, "Android storage must remain in the project" if File.exist?(@storage) && File.realpath(@storage) != @storage
        @sdk, @registry = File.join(@storage, "sdk"), File.join(@storage, "avd")
        [@sdk, @registry, File.join(@storage, "user")].each do |path|
          raise PipelineError, "Android storage must remain in the project" if File.exist?(path) && File.realpath(path) != path
        end
        @environment = {"ANDROID_HOME" => @sdk, "ANDROID_SDK_ROOT" => @sdk,
                        "ANDROID_USER_HOME" => File.join(@storage, "user"), "ANDROID_EMULATOR_HOME" => File.join(@storage, "user"), "ANDROID_AVD_HOME" => @registry}
      else
        @registry = File.expand_path(ENV["ANDROID_AVD_HOME"] || File.join(ENV["ANDROID_USER_HOME"] || File.join(Dir.home, ".android"), "avd"))
      end
      identity = [@registry, @avd, @serial].join("\0")
      @journal = File.join(context.root, "tmp/e2e-cache/emulator-#{Digest::SHA256.hexdigest(identity)}.json")
      @log = File.join(context.output, "emulator.log")
    end

    # Explicit, offline provisioning from the configured, licensed host SDK.
    # Keep real package bytes here; app builds continue using the host SDK.
    def setup
      raise PipelineError, "Emulator setup requires storage_dir" unless @storage
      raise PipelineError, "Borrowed emulators cannot be provisioned" if @target["lifecycle"] == "borrow"
      @context.lease("android-runtime", identity: @sdk)
      image = system_image
      raise Unavailable, "Configure system_image before emulator_setup" unless image
      packages = ["cmdline-tools/latest", "platform-tools", "emulator", image.tr(";", "/")]
      packages.each do |package|
        source, destination = File.join(@source_sdk, package), File.join(@sdk, package)
        raise PipelineError, "Project runtime package redirects outside storage: #{destination}" if File.exist?(destination) && File.realpath(destination) != destination
        next if File.file?(File.join(destination, "package.xml"))
        raise Unavailable, "Install #{package} in the configured host SDK first (#{source})" unless File.file?(File.join(source, "package.xml"))
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        raise Unavailable, "Incomplete runtime package #{destination}; inspect it before setup" if File.exist?(destination)
        staging = Dir.mktmpdir(".install-", File.dirname(destination))
        begin
          @context.command(["/bin/cp", "-R", source, File.join(staging, "package")], timeout: 300, log: File.join(@context.output, "emulator-setup.log"))
          File.rename(File.join(staging, "package"), destination)
        ensure
          FileUtils.remove_entry_secure(staging)
        end
      end
      %w[avd user].each { |folder| FileUtils.mkdir_p(File.join(@storage, folder), mode: 0o700) }
      puts "Project emulator runtime ready: #{@storage}. Run emulator_check or emulator_run to create/boot the AVD."
    end

    def verify_target! = exact_avd!
    def verify_ui! = focused_window

    def start(warm: false)
      began = clock
      state = adb(["get-state"], check: false, binary: true).strip
      recover(borrow: state == "device")
      if state == "device"
        exact_avd!
        @borrowed = true
      else
        raise Unavailable, "#{@serial} is #{state}; preserve its existing owner" unless state.empty?
        raise Unavailable, "Profile borrows an emulator which is not running" if @target["lifecycle"] == "borrow"
        @context.lease("android-avd", identity: [@registry, @avd].join("\0"))
        @context.lease("android-runtime", identity: @sdk) if @storage
        processes = @context.command(["ps", "-axo", "pid=,command="], timeout: 15)
        raise Unavailable, "Unaccounted emulator #{@avd}; inspect its owner before launching" if processes.lines.any? { |line| line.match?(/(?:qemu-system(?:-[A-Za-z0-9_-]+)?|\/emulator)(?:\s|\/)/) && line.include?(@avd) }
        resolve_avd
        argv = [File.join(@sdk, "emulator/emulator"), "@#{@avd}", "-port", @port.to_s,
                "-gpu", @target.fetch("renderer", "auto"), "-no-snapshot", "-no-audio", "-no-boot-anim", "-no-metrics"]
        argv << "-no-window" unless @target.fetch("visible", false)
        @process = @context.start(argv, log: @log, environment: @environment)
        # Register before further fallible work so a failed boot cannot leak.
        @context.cleanup { close }
        signature = @context.command(["ps", "-p", @process.pid.to_s, "-o", "lstart=,command="], timeout: 15).strip
        controller = @context.command(["ps", "-p", Process.pid.to_s, "-o", "lstart=,command="], timeout: 15).strip
        Atomic.json(@journal, {pid: @process.pid, signature: signature, controller_pid: Process.pid, controller_signature: controller, warm: warm, serial: @serial, avd: @avd, log: @log})
      end
      deadline = clock + @target.fetch("boot_timeout", 180)
      progress = clock + 30
      loop do
        Atomic.write(@log, @process.output) if @process
        raise Unavailable, "Emulator exited during boot; see #{@log}" if @process && !@process.running?
        if adb(["get-state"], check: false, binary: true).strip == "device"
          exact_avd!
          if shell(%w[getprop sys.boot_completed], check: false).strip == "1" &&
             shell(%w[getprop init.svc.bootanim], check: false).strip == "stopped" &&
             shell(%w[pm path android], check: false).include?("package:")
            shell(%w[input keyevent KEYCODE_WAKEUP])
            shell(%w[wm dismiss-keyguard])
            focus = focused_window
            break if focus&.include?("Window{")
          end
        end
        raise Unavailable, "Emulator boot timed out; see #{@log}" if clock >= deadline
        if clock >= progress
          puts "Waiting for emulator #{@serial} boot; deadline in #{(deadline - clock).round}s; #{@log}"
          progress = clock + 30
        end
        sleep 1
      end
      @ready = true
      Atomic.json(File.join(@context.output, "emulator-admission.json"), {serial: @serial, avd: @avd, borrowed: !!@borrowed,
                  visible: @borrowed ? nil : @target.fetch("visible", false), renderer: @borrowed ? nil : @target.fetch("renderer", "auto"),
                  snapshots: @borrowed ? nil : false, registry: @registry, sdk: @sdk, boot_seconds: (clock - began).round(2)})
      puts "Emulator #{@serial} ready (#{@borrowed ? 'borrowed' : 'owned'}, #{(clock - began).round(1)}s); evidence: #{@context.output}"
      self
    end

    # Run as a registered background process for warm repeated tests. The AVD
    # lease remains owned; the device lease is released between admissions.
    def run
      raise Unavailable, "Emulator is borrowed; keep using its existing owner" unless @process
      sleep 1 while @process.running?
      raise Unavailable, "Managed emulator exited unexpectedly; see #{@log}"
    end

    # A separate lane asks the verified warm controller to run its own cleanup.
    # Callers hold the device lease so an active test/inspection cannot be stopped.
    def stop
      raise Unavailable, "No managed warm emulator journal for #{@avd}" unless File.file?(@journal)
      owner = JSON.parse(File.read(@journal))
      raise Unavailable, "Journal is not a managed warm emulator" unless owner["warm"] == true && owner["serial"] == @serial && owner["avd"] == @avd && owner["controller_pid"].is_a?(Integer) && owner["controller_pid"] > 1 && owner["pid"].is_a?(Integer) && owner["pid"] > 1
      controller = @context.command(["ps", "-p", owner.fetch("controller_pid").to_s, "-o", "lstart=,command="], timeout: 15, check: false).strip
      signature = @context.command(["ps", "-p", owner.fetch("pid").to_s, "-o", "lstart=,command="], timeout: 15, check: false).strip
      raise Unavailable, "Warm owner identity changed; preserve journal" unless !controller.empty? && controller == owner["controller_signature"] && !signature.empty? && signature.split.first(5) == owner.fetch("signature").split.first(5)
      exact_avd!
      @context.command(["/bin/kill", "-TERM", owner.fetch("controller_pid").to_s], timeout: 15)
      deadline = clock + 60
      loop do
        break if !File.file?(@journal) && adb(["get-state"], check: false, binary: true).strip.empty?
        raise CleanupError, "Warm shutdown did not complete; inspect #{owner['log']} and preserve journal" if clock >= deadline
        sleep 1
      end
      puts "Managed warm emulator #{@serial} closed by its owner."
    end

    def close
      return unless @process
      died = @ready && !@process.running?
      @process.stop
      raise CleanupError, "#{@serial} remains occupied after owned shutdown; preserve #{@journal}" unless adb(["get-state"], check: false, binary: true).strip.empty?
      File.unlink(@journal) if File.file?(@journal)
      @process = nil
      raise CleanupError, "Managed emulator exited unexpectedly; see #{@log}" if died
    end

    private

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def adb(args, **options) = @context.command([File.join(@source_sdk, "platform-tools/adb"), "-s", @serial, *args], timeout: options.delete(:timeout) || 15, **options)
    def shell(args, **options) = adb(["shell", Shellwords.join(args)], **options)

    def focused_window
      focus = shell(%w[dumpsys window displays], check: false).lines.find { |line| line.include?("mCurrentFocus=") }
      raise Unavailable, "Android system error dialog blocks tests; see #{@log}" if focus&.match?(/Application (?:Not Responding|Error):/)
      focus
    end

    def resolve_avd
      ini = File.join(@registry, "#{@avd}.ini")
      unless File.file?(ini)
        image = system_image
        raise Unavailable, "Missing AVD #{ini}; configure system_image to create a test AVD" unless image
        package = File.join(@sdk, *image.split(";"), "package.xml")
        raise Unavailable, "Missing #{image} (#{package}); install in the host SDK then run android local action:emulator_setup for project storage" unless File.file?(package)
        manager = File.join(@sdk, "cmdline-tools/latest/bin/avdmanager")
        raise Unavailable, "Install Android SDK command-line tools (latest)" unless File.executable?(manager)
        FileUtils.mkdir_p(@registry, mode: 0o700)
        @context.command([manager, "create", "avd", "--name", @avd, "--package", image, "--device", "pixel_2"], input: "no\n", timeout: 120, environment: @environment)
        # Provision only this newly created AVD. Keep Pixel 2's logical layout
        # at 720p to reduce software rendering cost, with bounded test userdata.
        config = File.join(@registry, "#{@avd}.avd/config.ini")
        settings = {"disk.dataPartition.size" => "4G", "hw.lcd.width" => "720", "hw.lcd.height" => "1280",
                    "hw.lcd.density" => "280", "skin.name" => "720x1280", "skin.path" => "_no_skin"}
        lines = File.readlines(config).reject { |line| settings.key?(line.split("=", 2).first.strip) }
        Atomic.write(config, lines.join + settings.map { |key, value| "#{key}=#{value}\n" }.join)
      end
      path = ini_values(ini)["path"]
      raise Unavailable, "AVD data/config unavailable" unless path && File.readable?(File.join(path, "config.ini"))
      data = File.realpath(path)
      raise Unavailable, "Project AVD points outside #{@registry}" if @storage && !data.start_with?(File.realpath(@registry) + File::SEPARATOR)
      free = @context.command(["df", "-Pk", data], timeout: 15).lines.last.split[3].to_i
      required = 4 * 1024 * 1024
      unless File.file?(File.join(data, "userdata-qemu.img"))
        size = ini_values(File.join(data, "config.ini"))["disk.dataPartition.size"]
        match = /\A(\d+)([KMG]?)\z/.match(size.to_s)
        bytes = match ? match[1].to_i * {"" => 1, "K" => 1024, "M" => 1024**2, "G" => 1024**3}.fetch(match[2]) : 10 * 1024**3
        # Current API 35 images can raise a requested 4 GiB partition to 6 GiB.
        required = [required, [bytes / 1024, 6 * 1024 * 1024].max + 2 * 1024 * 1024].max
      end
      raise Unavailable, "AVD volume requires #{(required.to_f / 1024 / 1024).ceil} GiB free for userdata and boot" unless free >= required
    end

    def exact_avd!
      actual = adb(%w[emu avd name]).delete("\r").lines.first&.strip
      raise Unavailable, "#{@serial} is #{actual}, expected #{@avd}" unless actual == @avd
      ini = File.join(@registry, "#{@avd}.ini")
      expected = File.file?(ini) && ini_values(ini)["path"]
      actual_path = adb(%w[emu avd path]).delete("\r").lines.first&.strip
      raise Unavailable, "#{@serial} belongs to a different AVD directory; expected #{ini}" unless expected && actual_path && File.directory?(actual_path) && File.realpath(actual_path) == File.realpath(expected)
    end

    def ini_values(path)
      File.readlines(path).filter_map { |line| key, value = line.split("=", 2); [key.strip, value.strip] if value }.to_h
    end

    def system_image
      image = @target["system_image"]
      return unless image
      arch = RbConfig::CONFIG.fetch("host_cpu").match?(/arm|aarch64/) ? "arm64-v8a" : "x86_64"
      image = image.sub(/;native\z/, ";#{arch}")
      raise PipelineError, "Invalid emulator system image" unless image.match?(/\Asystem-images;android-\d+;[a-z0-9_]+;(?:arm64-v8a|x86_64)\z/)
      image
    end

    def recover(borrow: false)
      return unless File.file?(@journal)
      owner = JSON.parse(File.read(@journal))
      raise PipelineError, "Invalid emulator journal" unless owner["serial"] == @serial && owner["avd"] == @avd && owner["pid"].is_a?(Integer) && owner["pid"] > 1 && owner["signature"].is_a?(String)
      signature = @context.command(["ps", "-p", owner.fetch("pid").to_s, "-o", "lstart=,command="], timeout: 15, check: false).strip
      # The launcher execs QEMU in the same PID. Compare birth time across exec;
      # guest identity is checked separately, and the controller must still live.
      same_birth = !signature.empty? && signature.split.first(5) == owner.fetch("signature").split.first(5)
      if borrow && same_birth && owner["controller_pid"].is_a?(Integer) && owner["controller_pid"] > 1
        controller = @context.command(["ps", "-p", owner.fetch("controller_pid").to_s, "-o", "lstart=,command="], timeout: 15, check: false).strip
        return if !controller.empty? && controller == owner["controller_signature"]
      end
      if signature.empty? && adb(["get-state"], check: false, binary: true).strip.empty?
        File.unlink(@journal)
        return
      end
      raise Unavailable, "Unfinished managed emulator session #{owner['pid']}; preserve journal and inspect #{owner['log']} before recovery (identity #{signature == owner['signature'] ? 'matches' : 'changed'})"
    end
  end
end
