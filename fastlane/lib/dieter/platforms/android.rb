# frozen_string_literal: true

require "shellwords"
require "digest"
require_relative "../pipeline/artifacts"
require_relative "emulator"

module Dieter
  # The Android app: a Material shell (apps/android) hosting the shared Compose UI.
  class Android
    APP = "com.dbpprt.dieter.e2e"

    def initialize(context, actions: nil)
      @context, @root, @actions = context, context.root, actions
      sdk = context.environment["ANDROID_HOME"] || ENV["ANDROID_HOME"] || ENV["ANDROID_SDK_ROOT"]
      raise Unavailable, "Configure Android SDK in fastlane/local.json or ANDROID_HOME" unless sdk
      @sdk, @adb = sdk, File.join(sdk, "platform-tools/adb")
    end

    def unit(_options)
      @context.lease("android-build")
      gradle(%w[:app:lintDebug])
    end

    def build(options)
      @context.lease("android-build")
      configuration = options.fetch("configuration", "debug")
      configure_release_signing if configuration == "release"
      gradle([":app:assemble#{configuration.capitalize}"])
      artifact =
        File.join(
          @root,
          "apps/android/app/build/outputs/apk",
          configuration,
          "app-#{configuration}.apk"
        )
      source = @context.command(%w[git rev-parse HEAD], timeout: 30).strip
      ArtifactSet.new(
        component: "android",
        source: source,
        configuration: configuration,
        products: {
          "apk" => artifact
        }
      ).write(File.join(@context.output, "artifacts.json"))
      artifact
    end

    # Maestro flows install this separate application, preserving the operator's app.
    def e2e_build
      @context.lease("android-build")
      gradle(%w[:app:assembleE2e])
      File.join(@root, "apps/android/app/build/outputs/apk/e2e/app-e2e.apk")
    end

    def admit(target)
      @target, @serial = target, target.fetch("serial")
      @context.lease("android-device", identity: @serial)
      @emulator = AndroidEmulator.new(@context, @sdk, target).start if target["kind"] == "emulator"
      state = adb(%w[get-state], check: false).strip
      raise Unavailable, "Android #{@serial} is unavailable (#{state})" unless state == "device"
      if target["kind"] == "emulator"
        name = adb(%w[emu avd name]).delete("\r").lines.first&.strip
        unless name == target.fetch("avd")
          raise Unavailable, "#{@serial} is AVD #{name}; expected #{target.fetch("avd")}"
        end
      end
      { "sys.boot_completed" => "1", "init.svc.bootanim" => "stopped" }.each do |property, value|
        unless shell(["getprop", property]).strip == value
          raise Unavailable, "Android has not completed boot: #{property}"
        end
      end
      unless shell(["pidof", APP], check: false).strip.empty?
        raise Unavailable, "#{APP} already running; preserving its owner"
      end
      @emulator&.verify_ui!
      @serial
    end

    def install(path)
      installed = shell(["pm", "path", APP], check: false).strip.delete_prefix("package:")
      if installed.start_with?("/data/app/") && !installed.match?(/[\r\n]/)
        remote_hash = shell(["sha256sum", installed], check: false).split.first
        return if remote_hash == Digest::SHA256.file(path).hexdigest
      end
      unless adb(["install", "-r", "-t", path], timeout: 180).include?("Success")
        raise PipelineError, "Install failed for isolated #{APP}"
      end
      # Avoid first-run dex compilation consuming the first flow's launch deadline.
      shell(["cmd", "package", "compile", "-m", "speed", "-f", APP], timeout: 180)
    end

    # The emulator reaches the host's loopback fixture through an owned reverse port.
    def reverse(port)
      adb(["reverse", "--no-rebind", "tcp:#{port}", "tcp:#{port}"])
      @context.cleanup { adb(["reverse", "--remove", "tcp:#{port}"], timeout: 15) }
    end

    def stop_app
      shell(["am", "force-stop", APP], timeout: 15)
      unless shell(["pidof", APP], timeout: 10, check: false).strip.empty?
        raise CleanupError, "Owned E2E app did not stop"
      end
    end

    private

    def configure_release_signing
      profile = @context.config.data.fetch("signing").fetch("android-release")
      path =
        @context.config.path(
          @context.environment["DIETER_ANDROID_KEYSTORE_PATH"] ||
            ENV["DIETER_ANDROID_KEYSTORE_PATH"] || profile["keystore_file"]
        )
      unless path && File.file?(path)
        raise Unavailable, "Android release requires a configured existing keystore"
      end
      values = { "DIETER_ANDROID_KEYSTORE_PATH" => File.realpath(path) }
      {
        "DIETER_ANDROID_KEYSTORE_PASSWORD" => "keystore_password_env",
        "DIETER_ANDROID_KEY_ALIAS" => "key_alias_env",
        "DIETER_ANDROID_KEY_PASSWORD" => "key_password_env"
      }.each do |name, field|
        value = @context.environment[name] || ENV[profile.fetch(field)]
        unless value && !value.empty?
          raise Unavailable, "Missing Android signing environment reference #{profile.fetch(field)}"
        end
        @context.secrets << value
        values[name] = value
      end
      @context.environment.merge!(values)
    end

    def adb(args, **options)
      @context.command([@adb, "-s", @serial, *args], **options)
    end

    def shell(args, **options)
      adb(["shell", Shellwords.join(args)], **options)
    end

    def gradle(tasks)
      @context.command(
        [
          File.join(@root, "apps/android/gradlew"),
          "--project-dir",
          "apps/android",
          "--console=plain",
          *tasks
        ],
        timeout: 2400,
        log: File.join(@context.output, "build.log")
      )
    end
  end
end
