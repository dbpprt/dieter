# frozen_string_literal: true

require_relative "runtime"

module Dieter
  # Small local tools use the same configuration, leases, ownership and evidence
  # as test/build compositions. They never carry their own host-side test loop.
  module Operations
    def self.invoke(component, options)
      values = options.transform_keys(&:to_s)
      raise PipelineError, "Unknown local options" unless (values.keys - %w[action profile output filter configuration platforms]).empty?
      action = values.fetch("action", "status")
      context = RunContext.new(Config.new(Runtime::ROOT), output: values["output"])
      signals = {}
      begin
        if component == "android" && action == "emulator_run"
          %w[INT TERM].each { |name| signals[name] = Signal.trap(name) { raise Interrupt, "Emulator run stopped" } }
        end
        case component
        when "mac" then mac(context, action, values)
        when "android" then android(context, action, values)
        when "core"
          raise PipelineError, "Core local action must be framework" unless action == "framework"
          SharedFramework.new(context).build(configuration: values.fetch("configuration", "debug"), platforms: values.fetch("platforms", "macos"))
        else raise PipelineError, "Unknown local component #{component}"
        end
      rescue Interrupt
        raise unless component == "android" && action == "emulator_run"
        puts "Closing managed warm emulator."
      ensure
        begin
          context.close
        ensure
          signals.each { |name, handler| Signal.trap(name, handler) }
        end
      end
    end

    def self.mac(context, action, values)
      code = "from fastlane.lib.dieter.native import mac_lifecycle as app; "
      case action
      when "status" then puts context.command(["python3", "-c", code + "print(app.describe(app.app_processes()) or 'Dieter is stopped')"], timeout: 30)
      when "run"
        stopped = context.command(["python3", "-c", code + "print(len(app.owned_processes()))"], timeout: 30).strip
        raise Unavailable, "Multiple canonical app processes; preserve their owner" unless %w[0 1].include?(stopped)
        if stopped == "0"
          context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
          Mac.new(context).build(values)
        end
        context.command(["python3", "-c", code + "app.assert_single_or_stopped(); app.activate(); app.wait_for_count(1)"], timeout: 30)
      when "quit" then context.command(["python3", "-c", code + "app.quit_app()"], timeout: 30)
      when "verify" then context.command(["bash", "apps/mac/scripts/verify-bundle.sh", "apps/mac/build/Dieter.app"], timeout: 120)
      when "format", "format_check" then context.command(["bash", "apps/mac/scripts/format-swift.sh", action == "format_check" ? "--check" : "--write"], timeout: 300)
      when "proto_generate", "proto_check" then context.command(["bash", "apps/mac/scripts/sync-proto.sh", *(action == "proto_check" ? ["--check"] : [])], timeout: 600)
      else raise PipelineError, "Unknown Mac local action #{action}"
      end
    end

    def self.android(context, action, values)
      target = context.config.profile(values["profile"] || context.config.default_profile("android"), component: "android", physical_explicit: values.key?("profile"))
      sdk = context.environment.fetch("ANDROID_HOME")
      adb = [File.join(sdk, "platform-tools/adb"), "-s", target.fetch("serial")]
      if action == "emulator_setup"
        raise PipelineError, "Emulator setup requires an emulator profile" unless target.fetch("kind") == "emulator"
        AndroidEmulator.new(context, sdk, target).setup
        return
      end
      if action == "emulator_run"
        raise PipelineError, "Emulator run requires an emulator profile" unless target.fetch("kind") == "emulator"
        emulator = AndroidEmulator.new(context, sdk, target)
        context.with_lease("android-device", identity: target.fetch("serial")) { emulator.start(warm: true) }
        puts "Warm emulator ready; other runs may borrow it. Use action:emulator_stop for owned cleanup."
        emulator.run
        return
      end
      context.lease("android-device", identity: target.fetch("serial"))
      if action == "emulator_stop"
        raise PipelineError, "Emulator stop requires an emulator profile" unless target.fetch("kind") == "emulator"
        AndroidEmulator.new(context, sdk, target).stop
        return
      end
      if action == "emulator_check"
        raise PipelineError, "Emulator health requires an emulator profile" unless target.fetch("kind") == "emulator"
        AndroidEmulator.new(context, sdk, target).start
        puts "Emulator is healthy; owned lifecycle will close. Evidence: #{context.output}"
        return
      end
      if action == "status"
        puts context.command([*adb, "get-state"], timeout: 15, check: false)
        return
      end
      raise Unavailable, "Selected Android device is unavailable" unless context.command([*adb, "get-state"], timeout: 15, check: false).strip == "device"
      if target["kind"] == "emulator"
        AndroidEmulator.new(context, sdk, target).verify_target!
      end
      shell = ->(args) { context.command([*adb, "shell", Shellwords.join(args)], timeout: 30) }
      case action
      when "install"
        context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
        apk = Android.new(context).build({})
        puts context.command([*adb, "install", "-r", apk], timeout: 180)
      when "launch" then shell.call(%w[am start -n com.dbpprt.dieter/.MainActivity])
      when "app_stop" then shell.call(%w[am force-stop com.dbpprt.dieter])
      when "ui_dump"
        shell.call(%w[uiautomator dump /sdcard/dieter-ui.xml])
        Atomic.write(File.join(context.output, "ui.xml"), context.command([*adb, "exec-out", "cat", "/sdcard/dieter-ui.xml"], timeout: 30, binary: true))
      when "screenshot"
        data = context.command([*adb, "exec-out", "screencap", "-p"], timeout: 30, binary: true)
        raise PipelineError, "Android returned an invalid screenshot" unless data.start_with?("\x89PNG\r\n\x1a\n".b)
        Atomic.write(File.join(context.output, "screen.png"), data)
      when "logs" then puts context.command([*adb, "logcat", "-d", "-t", "300"], timeout: 30)
      else raise PipelineError, "Unknown Android local action #{action}"
      end
      puts "Local evidence: #{context.output}"
    end
  end
end
