# frozen_string_literal: true

require "shellwords"
require "digest"
require_relative "../fixtures/gateway"
require_relative "../pipeline/contract"
require_relative "../pipeline/artifacts"
require_relative "emulator"

module Dieter
  # The Android app: a Material shell (apps/android) hosting the shared Compose UI.
  class Android
    # Journeys install this separate application, preserving the operator's app.
    APP = "com.dbpprt.dieter.e2e"
    RUNNER = "androidx.test.runner.AndroidJUnitRunner"

    def initialize(context, actions: nil)
      @context, @root, @actions = context, context.root, actions
      sdk = context.environment["ANDROID_HOME"] || ENV["ANDROID_HOME"] || ENV["ANDROID_SDK_ROOT"]
      raise Unavailable, "Configure Android SDK in fastlane/local.json or ANDROID_HOME" unless sdk
      @sdk, @adb = sdk, File.join(sdk, "platform-tools/adb")
      @contract = Contract.new(context)
      @products = {}
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

    def admit_preparation(_target, _plan)
      @context.lease("android-build")
    end

    def admit(target, plan)
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
      @context.lease("android-build")
    end

    def prepare(_target, _plan)
      source = @contract.call("android-digest").fetch("sha256")
      java = @context.environment["JAVA_HOME"] || ENV["JAVA_HOME"]
      unless java && File.executable?(File.join(java, "bin/java"))
        raise Unavailable, "JAVA_HOME must select the Android JDK"
      end
      toolchain = @context.command([File.join(java, "bin/java"), "-version"], timeout: 30)
      paths = [
        File.join(@root, "apps/android/app/build/outputs/apk/e2e/app-e2e.apk"),
        File.join(
          @root,
          "apps/android/app/build/outputs/apk/androidTest/e2e/app-e2e-androidTest.apk"
        )
      ]
      cache = File.join(@root, "tmp/e2e-cache/android-e2e.json")
      inputs = [
        source,
        toolchain,
        @sdk,
        java,
        *%w[
          DIETER_RELEASE_VERSION
          DIETER_RELEASE_VERSION_CODE
          GRADLE_OPTS
          JAVA_TOOL_OPTIONS
        ].map { |key| ENV[key] || "" }
      ]
      debug_key = File.join(Dir.home, ".android/debug.keystore")
      inputs << Digest::SHA256.file(debug_key).hexdigest if File.file?(debug_key)
      key = Digest::SHA256.hexdigest(inputs.join("\0"))
      previous = File.file?(cache) ? JSON.parse(File.read(cache)) : {}
      valid =
        previous["key"] == key && paths.all? { |path| File.file?(path) } &&
          previous["hashes"] ==
            paths.map { |path| File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil }
      unless valid
        gradle(%w[:app:assembleE2e :app:assembleE2eAndroidTest -Pdieter.testBuildType=e2e])
        Atomic.json(
          cache,
          { key: key, hashes: paths.map { |path| Digest::SHA256.file(path).hexdigest } }
        )
      end
      @products = paths
      GatewayFixture.compile(@context)
    end

    def execute_case(_target, test_case)
      @emulator&.verify_ui!
      dir = File.join(@context.output, test_case.fetch("id"))
      FileUtils.mkdir_p(dir, mode: 0o700)
      state = Dir.mktmpdir("android-case-", @context.private_dir)
      started = monotonic
      result = { "status" => "failed", "reason" => "", "setupMs" => 0, "executionMs" => 0 }
      fixture, port, token, app_owned, reverse_owned = nil, nil, nil, false, false
      begin
        install
        arguments = { "additionalTestOutputDir" => "/sdcard/Android/data/#{APP}/files" }
        if test_case.fetch("fixture") == "gateway"
          fixture = GatewayFixture.new(@context, "mobile", state, evidence: dir)
          values = fixture.start
          port = values.fetch("DIETER_ISOLATED_ADDR").split(":").last
          token = values.fetch("DIETER_ISOLATED_TOKEN")
          adb(["reverse", "--no-rebind", "tcp:#{port}", "tcp:#{port}"])
          reverse_owned = true
        end
        unless shell(["pm", "clear", APP]).include?("Success")
          raise PipelineError, "Cannot reset isolated E2E package"
        end
        app_owned = true
        if token
          # The fixture session stays in the app's private files, never in instrumentation argv.
          shell(["run-as", APP, "mkdir", "-p", "files"])
          shell(
            ["run-as", APP, "tee", "files/fixture.json"],
            input: JSON.generate({ port: port, token: token })
          )
        end
        native = test_case.fetch("native")
        invocation = [
          "am",
          "instrument",
          "-w",
          "-r",
          "-e",
          "class",
          native.fetch("methods").map { |method| "#{native.fetch("class")}##{method}" }.join(",")
        ]
        arguments.each { |name, value| invocation += ["-e", name, value] }
        invocation << "#{APP}.test/#{RUNNER}"
        result["setupMs"] = ((monotonic - started) * 1000).round
        began = monotonic
        shell(invocation, timeout: 1200, log: File.join(dir, "instrumentation.log"))
        result["executionMs"] = ((monotonic - began) * 1000).round
        result.merge!(
          @contract.call(
            "qualify",
            { platform: "android", path: File.join(dir, "instrumentation.log"), case: test_case }
          )
        )
      rescue StandardError => error
        result["status"] = error.is_a?(Unavailable) ?
          "unavailable" :
          error.is_a?(Interrupted) ? "interrupted" : "failed"
        result["reason"] = error.message
      ensure
        problems = []
        @context.during_cleanup do
          if app_owned
            capture(dir)
            attempt(problems) { shell(["am", "force-stop", APP], timeout: 15) }
            attempt(problems) do
              unless shell(["pidof", APP], timeout: 10, check: false).strip.empty?
                raise CleanupError, "Owned E2E app did not stop"
              end
            end
          end
          if reverse_owned
            attempt(problems) { adb(["reverse", "--remove", "tcp:#{port}"], timeout: 15) }
          end
          attempt(problems) { fixture.close } if fixture
          FileUtils.remove_entry_secure(state) if problems.empty?
        end
        result["cleanupError"] = problems.join("; ")
      end
      result
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

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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

    def install
      @products.each_with_index do |path, index|
        pkg = APP + (index == 1 ? ".test" : "")
        installed = shell(["pm", "path", pkg], check: false).strip.delete_prefix("package:")
        if installed.start_with?("/data/app/") && !installed.match?(/[\r\n]/)
          remote_hash = shell(["sha256sum", installed], check: false).split.first
          next if remote_hash == Digest::SHA256.file(path).hexdigest
        end
        unless adb(["install", "-r", "-t", path], timeout: 180).include?("Success")
          raise PipelineError, "Install failed for isolated #{pkg}"
        end
        # Avoid first-run dex compilation consuming the emulator's process-start deadline.
        shell(["cmd", "package", "compile", "-m", "speed", "-f", pkg], timeout: 180)
      end
    end

    def attempt(problems)
      yield
    rescue StandardError => error
      problems << error.message
    end

    def capture(dir)
      # Instrumentation owns these isolated external artifacts, including the
      # journey's screenshots; a passing case is qualified by its native result.
      adb(
        ["pull", "/sdcard/Android/data/#{APP}/files", File.join(dir, "captures")],
        timeout: 30,
        check: false
      )
      return if File.file?(File.join(dir, "failure.png"))
      attempt([]) do
        png = adb(%w[exec-out screencap -p], timeout: 15, binary: true)
        Atomic.write(File.join(dir, "final.png"), png) if png.start_with?("\x89PNG".b)
      end
    end
  end
end
