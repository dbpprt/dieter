# frozen_string_literal: true

require "digest"
require "shellwords"

module Dieter
  # The target is borrowed when already running. Only a process launched here
  # may be shut down; a journal survives crashes and never authorizes a broad kill.
  class AndroidEmulator
    ERRORS = /software GL rendering|gles_mode_selected:swangle|failed to find ColorBuffer|bad color buffer handle|failed to (?:load|save) snapshot|different renderer configured|snapshot (?:restore|save) error/i

    def initialize(context, sdk, target)
      @context, @sdk, @target = context, sdk, target
      @serial, @avd = target.fetch("serial"), target.fetch("avd")
      port = /\Aemulator-(\d+)\z/.match(@serial)&.captures&.first&.to_i
      raise PipelineError, "Emulator serial must select an even port 5554..5682" unless port && (5554..5682).cover?(port) && port.even?
      @port = port
      @journal = File.join(context.root, "tmp/e2e-cache/emulator-#{Digest::SHA256.hexdigest(@serial)}.json")
      @log = File.join(context.output, "emulator.log")
    end

    def start
      resolve_avd
      recover
      state = adb(["get-state"], check: false, binary: true).strip
      if state == "device"
        exact_avd!
        @borrowed = true
        legacy = File.join(@context.root, "apps/android/build/emulator/screenlog.0")
        raise Unavailable, "Borrowed emulator requires its host-renderer launch evidence" unless File.file?(legacy)
        @borrowed_log = File.read(legacy).byteslice(-4 * 1024 * 1024, 4 * 1024 * 1024) || File.read(legacy)
      else
        raise Unavailable, "#{@serial} is not healthy; preserve its existing owner" unless state.empty?
        processes = @context.command(["ps", "-axo", "pid=,command="], timeout: 15)
        raise Unavailable, "Unaccounted emulator #{@avd}; inspect its owner before launching" if processes.lines.any? { |line| line.match?(/(?:qemu-system|\/emulator)(?:\s|\/)/) && line.include?(@avd) }
        raise Unavailable, "Profile borrows an emulator which is not running" if @target["lifecycle"] == "borrow"
        argv = [File.join(@sdk, "emulator/emulator"), "@#{@avd}", "-port", @port.to_s, "-gpu", "host"]
        @process = @context.start(argv, environment: {"ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL" => "180"}, log: @log)
        signature = @context.command(["ps", "-p", @process.pid.to_s, "-o", "lstart=,command="], timeout: 15).strip
        Atomic.json(@journal, {"pid" => @process.pid, "signature" => signature, "serial" => @serial, "avd" => @avd, "log" => @log})
        @context.cleanup { close }
      end
      deadline = clock + 180
      loop do
        break if adb(["get-state"], check: false, binary: true).strip == "device" && shell(%w[getprop sys.boot_completed]).strip == "1" && shell(%w[getprop init.svc.bootanim]).strip == "stopped"
        raise Unavailable, "Emulator did not complete boot; see #{@log}" if clock >= deadline || (@process && !@process.running?)
        sleep 2
      end
      sleep 3
      exact_avd!
      renderer!
      if @process && @snapshot_expected
        raise Unavailable, "Launch did not restore default_boot" unless launch_log.include?("Loading snapshot 'default_boot'")
        snapshot_list!
      end
      launcher!
      shell(%w[uiautomator dump /sdcard/dieter-avd-health.xml], timeout: 30)
      hierarchy = adb(%w[exec-out cat /sdcard/dieter-avd-health.xml], timeout: 30)
      raise Unavailable, "Emulator launcher accessibility hierarchy unavailable" unless hierarchy.include?("<hierarchy") && hierarchy.match?(/package="(?:com.google.android.apps.nexuslauncher|com.android.launcher3)"/)
      Atomic.write(File.join(@context.output, "emulator-health.xml"), hierarchy)
      png = adb(%w[exec-out screencap -p], binary: true, timeout: 30)
      raise Unavailable, "Emulator health capture is invalid" unless png.start_with?("\x89PNG\r\n\x1a\n".b)
      Atomic.write(File.join(@context.output, "emulator-health.png"), png)
      Atomic.json(File.join(@context.output, "emulator-admission.json"), {serial: @serial, avd: @avd, borrowed: !!@borrowed, renderer: "host", snapshot_expected: @snapshot_expected})
    end

    def close
      return unless @process
      unless @process.running?
        raise CleanupError, "Owned emulator exited before a healthy snapshot could be saved; preserve #{@journal} and #{@log}: #{@process.output[-1800..]}"
      end
      exact_avd!
      renderer!
      launcher!
      # Emulator 37.1 disables console saves together with automatic saves when
      # -no-snapshot-save is set. Save only after owned cases have stopped and
      # the launcher is focused, with normal snapshot restoration enabled.
      previous = %w[ram.bin snapshot.pb textures.bin].to_h { |name| path = File.join(@data, "snapshots/default_boot", name); [name, File.exist?(path) ? File.mtime(path) : nil] }
      offset = launch_log.bytesize
      adb(%w[emu avd snapshot save default_boot], timeout: 120)
      sleep 2
      snapshot_list!
      snapshot_files!
      raise CleanupError, "Snapshot save was ignored; preserve journal" if launch_log.byteslice(offset..)&.match?(/save request is ignored|Snapshots have been disabled/i)
      raise CleanupError, "Snapshot metadata was not freshly saved" if previous["snapshot.pb"] && File.mtime(File.join(@data, "snapshots/default_boot/snapshot.pb")) <= previous["snapshot.pb"]
      raise CleanupError, "Emulator snapshot save failed; preserve journal" if launch_log.byteslice(offset..)&.match?(ERRORS)
      adb(%w[emu kill], timeout: 30)
      @context.wait(@process, timeout: 240, check: false)
      raise CleanupError, "Emulator remained visible after owned shutdown" unless adb(["get-state"], check: false, binary: true).strip.empty?
      snapshot_files!
      raise CleanupError, "Emulator shutdown reported snapshot errors" if launch_log.byteslice(offset..)&.match?(ERRORS)
      File.unlink(@journal)
      @process = nil
    end

    private

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def adb(args, **options) = @context.command([File.join(@sdk, "platform-tools/adb"), "-s", @serial, *args], timeout: options.delete(:timeout) || 15, **options)
    def shell(args, **options) = adb(["shell", Shellwords.join(args)], **options)
    def launch_log = @process ? @process.output : @borrowed_log.to_s

    def resolve_avd
      registry = ENV["ANDROID_AVD_HOME"] || File.join(ENV["ANDROID_USER_HOME"] || File.join(Dir.home, ".android"), "avd")
      raise PipelineError, "Unsafe AVD name" unless @avd.match?(/\A[A-Za-z0-9_.-]+\z/)
      ini = File.join(registry, "#{@avd}.ini")
      raise Unavailable, "Missing AVD registry #{ini}" unless File.readable?(ini)
      path = File.readlines(ini).find { |line| line.start_with?("path=") }&.delete_prefix("path=")&.strip
      raise Unavailable, "AVD data/config unavailable" unless path && File.readable?(File.join(path, "config.ini"))
      @data = File.realpath(path)
      free = @context.command(["df", "-Pk", @data], timeout: 15).lines.last.split[3].to_i
      raise Unavailable, "AVD volume requires 10 GiB free" unless free >= 10 * 1024 * 1024
      @snapshot_expected = File.directory?(File.join(@data, "snapshots/default_boot"))
    end

    def exact_avd!
      actual = adb(%w[emu avd name]).delete("\r").lines.first&.strip
      raise Unavailable, "#{@serial} is #{actual}, expected #{@avd}" unless actual == @avd
    end

    def renderer!
      log = launch_log
      Atomic.write(@log, log)
      raise Unavailable, "Emulator renderer/snapshot errors; preserve evidence" if log.match?(ERRORS)
      raise Unavailable, "Launch does not prove host GLES" unless log.lines.grep(/gles_mode_selected:/).last&.include?("gles_mode_selected:host") && log.lines.grep(/Graphics Adapter Android Emulator/).last&.include?("OpenGL ES Translator (")
      raise Unavailable, "Guest renderer unresponsive" unless shell(%w[dumpsys SurfaceFlinger]).lines.any? { |line| line.start_with?("GLES:") }
    end

    def launcher!
      shell(%w[input keyevent KEYCODE_WAKEUP])
      shell(%w[wm dismiss-keyguard])
      shell(%w[input keyevent KEYCODE_HOME])
      sleep 2
      raise Unavailable, "Emulator has no focused launcher" unless shell(%w[dumpsys window]).lines.grep(/mCurrentFocus|mFocusedApp|topResumedActivity/).join.match?(/NexusLauncherActivity|launcher3/)
    end

    def snapshot_list!
      raise CleanupError, "default_boot snapshot is missing" unless adb(%w[emu avd snapshot list]).match?(/(?:\A|\s)default_boot(?:\s|\z)/)
    end

    def snapshot_files!
      %w[ram.bin snapshot.pb textures.bin].each do |name|
        raise CleanupError, "Saved snapshot has empty #{name}" unless File.size?(File.join(@data, "snapshots/default_boot", name))
      end
    end

    def recover
      return unless File.file?(@journal)
      owner = JSON.parse(File.read(@journal))
      raise PipelineError, "Invalid emulator journal" unless owner["serial"] == @serial && owner["avd"] == @avd && owner["pid"].is_a?(Integer) && owner["pid"] > 1
      signature = @context.command(["ps", "-p", owner.fetch("pid").to_s, "-o", "lstart=,command="], timeout: 15, check: false).strip
      if signature.empty? && adb(["get-state"], check: false, binary: true).strip.empty?
        File.unlink(@journal)
        return
      end
      raise Unavailable, "Unfinished managed emulator session #{owner['pid']}; preserve journal and inspect #{owner['log']} before recovery (identity #{signature == owner['signature'] ? 'matches' : 'changed'})"
    end
  end
end
