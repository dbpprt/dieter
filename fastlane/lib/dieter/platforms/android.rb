# frozen_string_literal: true

require "shellwords"
require "digest"
require_relative "../fixtures/gateway"
require_relative "../fixtures/screen"
require_relative "../pipeline/contract"
require_relative "../pipeline/artifacts"
require_relative "emulator"

module Dieter
  class Android
    APP = "com.dbpprt.dieter.e2e"

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
      gradle(%w[:app:testDebugUnitTest :app:lintDebug])
    end

    def build(options)
      @context.lease("android-build")
      configuration = options.fetch("configuration", "debug")
      configure_release_signing if configuration == "release"
      gradle([":app:assemble#{configuration.capitalize}"])
      artifact = File.join(@root, "apps/android/app/build/outputs/apk", configuration, "app-#{configuration}.apk")
      source = @context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip
      ArtifactSet.new(component: "android", source: source, configuration: configuration, products: {"apk" => artifact}).write(File.join(@context.output, "artifacts.json"))
      artifact
    end

    def admit(target, plan)
      @target, @serial = target, target.fetch("serial")
      @context.lease("android-device", identity: @serial)
      AndroidEmulator.new(@context, @sdk, target).start if target["kind"] == "emulator"
      if plan.any? { |test_case| test_case["build"] == "performance" } && target["kind"] != "emulator"
        raise Unavailable, "Performance qualification requires the selected emulator"
      end
      state = adb(%w[get-state], check: false).strip
      raise Unavailable, "Android #{@serial} is unavailable (#{state})" unless state == "device"
      if target["kind"] == "emulator"
        name = adb(%w[emu avd name]).delete("\r").lines.first&.strip
        raise Unavailable, "#{@serial} is AVD #{name}; expected #{target.fetch('avd')}" unless name == target.fetch("avd")
      end
      {"sys.boot_completed" => "1", "init.svc.bootanim" => "stopped"}.each do |property, value|
        raise Unavailable, "Android has not completed boot: #{property}" unless shell(["getprop", property]).strip == value
      end
      plan.map { |test_case| package(test_case) }.uniq.each do |id|
        raise Unavailable, "#{id} already running; preserving its owner" unless shell(["pidof", id], check: false).strip.empty?
      end
      ScreenFixture.admit(@context, input: true) if plan.any? { |test_case| test_case["fixture"] == "screen" }
      @context.lease("android-build")
    end

    def prepare(_target, plan)
      source = @contract.call("android-digest").fetch("sha256")
      java = @context.environment["JAVA_HOME"] || ENV["JAVA_HOME"]
      raise Unavailable, "JAVA_HOME must select the Android JDK" unless java && File.executable?(File.join(java, "bin/java"))
      toolchain = @context.command([File.join(java, "bin/java"), "-version"], timeout: 30)
      plan.map { |test_case| build_type(test_case) }.uniq.each do |variant|
        paths = [File.join(@root, "apps/android/app/build/outputs/apk/#{variant}/app-#{variant}.apk"), File.join(@root, "apps/android/app/build/outputs/apk/androidTest/#{variant}/app-#{variant}-androidTest.apk")]
        cache = File.join(@root, "tmp/e2e-cache/android-#{variant}.json")
        inputs = [source, toolchain, @sdk, variant, java, *%w[DIETER_RELEASE_VERSION DIETER_RELEASE_VERSION_CODE GRADLE_OPTS JAVA_TOOL_OPTIONS].map { |key| ENV[key] || "" }]
        debug_key = File.join(Dir.home, ".android/debug.keystore")
        inputs << Digest::SHA256.file(debug_key).hexdigest if File.file?(debug_key)
        key = Digest::SHA256.hexdigest(inputs.join("\0"))
        previous = File.file?(cache) ? JSON.parse(File.read(cache)) : {}
        valid = previous["key"] == key && paths.all? { |path| File.file?(path) } && previous["hashes"] == paths.map { |path| File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil }
        unless valid
          gradle([":app:assemble#{variant.capitalize}", ":app:assemble#{variant.capitalize}AndroidTest", "-Pdieter.testBuildType=#{variant}"])
          Atomic.json(cache, {key: key, hashes: paths.map { |path| Digest::SHA256.file(path).hexdigest }})
        end
        @products[variant] = paths
      end
      GatewayFixture.compile(@context)
    end

    def execute_case(_target, test_case)
      dir = File.join(@context.output, test_case.fetch("id"))
      FileUtils.mkdir_p(dir, mode: 0o700)
      state = Dir.mktmpdir("android-case-", @context.private_dir)
      started = monotonic
      result = {"status" => "failed", "reason" => "", "setupMs" => 0, "executionMs" => 0}
      fixture, screen, port, app_owned, reverse_owned = nil, nil, nil, false, false
      pkg = package(test_case)
      begin
        install(test_case)
        arguments = {"additionalTestOutputDir" => "/sdcard/Android/data/#{pkg}/files"}.merge(test_case.fetch("arguments", {}))
        if %w[gateway activity].include?(test_case.fetch("fixture"))
          fixture = GatewayFixture.new(@context, "android", state, evidence: dir, usage: test_case["id"] == "widget.usage")
          values = fixture.start
          port = values.fetch("DIETER_ISOLATED_ADDR").split(":").last
          arguments.merge!("isolatedGatewayPort" => port, "isolatedGatewayToken" => values.fetch("DIETER_ISOLATED_TOKEN"), "isolatedMachineId" => values.fetch("DIETER_ISOLATED_DAEMON"), "isolatedBoardId" => values.fetch("DIETER_ISOLATED_BOARD"))
        elsif test_case.fetch("fixture") == "screen"
          screen = ScreenFixture.new(@context, state, dir)
          screen_values, port = screen.start
          arguments.merge!(screen_values)
        end
        arguments.merge!(test_case.fetch("arguments", {}))
        if port
          adb(["reverse", "--no-rebind", "tcp:#{port}", "tcp:#{port}"])
          reverse_owned = true
        end
        raise PipelineError, "Cannot reset isolated E2E package" unless shell(["pm", "clear", pkg]).include?("Success")
        app_owned = true
        native = test_case["native"] || {"class" => "com.dbpprt.dieter.e2e.FlowTest", "methods" => ["runFlow"]}
        invocation = ["am", "instrument", "-w", "-r", "-e", "class", native.fetch("methods").map { |method| "#{native.fetch('class')}##{method}" }.join(",")]
        if test_case["build"] == "performance"
          arguments.each { |key, value| invocation += ["-e", key, value] }
        else
          shell(["run-as", pkg, "mkdir", "-p", "files"])
          plan = JSON.generate({version: 1, case: test_case, arguments: arguments})
          shell(["run-as", pkg, "tee", "files/plan.json"], input: plan)
          invocation += ["-e", "e2ePlan", "plan.json"]
        end
        result["setupMs"] = ((monotonic - started) * 1000).round
        invocation << "#{pkg}.test/com.dbpprt.dieter.e2e.DieterTestRunner"
        began = monotonic
        output = shell(invocation, timeout: 1200, log: File.join(dir, "instrumentation.log"))
        result["executionMs"] = ((monotonic - began) * 1000).round
        result.merge!(@contract.call("qualify", {platform: "android", path: File.join(dir, "instrumentation.log"), case: test_case}))
      rescue StandardError => error
        result["status"] = error.is_a?(Unavailable) ? "unavailable" : error.is_a?(Interrupted) ? "interrupted" : "failed"
        result["reason"] = error.message
      ensure
        problems = []
        @context.during_cleanup do
          if app_owned
            capture(test_case, pkg, dir, problems)
            attempt(problems) { shell(["am", "force-stop", pkg], timeout: 15) }
            attempt(problems) { raise CleanupError, "Owned E2E app did not stop" unless shell(["pidof", pkg], timeout: 10, check: false).strip.empty? }
          end
          attempt(problems) { adb(["reverse", "--remove", "tcp:#{port}"], timeout: 15) } if reverse_owned
          attempt(problems) { screen.close } if screen
          attempt(problems) { fixture.close } if fixture
          attempt(problems) { @contract.call("screen-normalize", {output: dir, case: test_case}, json: false) } if result["status"] == "passed"
          FileUtils.remove_entry_secure(state) if problems.empty?
        end
        result["cleanupError"] = problems.join("; ")
      end
      result
    end

    private

    def configure_release_signing
      profile = @context.config.data.fetch("signing").fetch("android-release")
      path = @context.config.path(@context.environment["DIETER_ANDROID_KEYSTORE_PATH"] || ENV["DIETER_ANDROID_KEYSTORE_PATH"] || profile["keystore_file"])
      raise Unavailable, "Android release requires a configured existing keystore" unless path && File.file?(path)
      values = {"DIETER_ANDROID_KEYSTORE_PATH" => File.realpath(path)}
      {"DIETER_ANDROID_KEYSTORE_PASSWORD" => "keystore_password_env", "DIETER_ANDROID_KEY_ALIAS" => "key_alias_env", "DIETER_ANDROID_KEY_PASSWORD" => "key_password_env"}.each do |name, field|
        value = @context.environment[name] || ENV[profile.fetch(field)]
        raise Unavailable, "Missing Android signing environment reference #{profile.fetch(field)}" unless value && !value.empty?
        @context.secrets << value
        values[name] = value
      end
      @context.environment.merge!(values)
    end

    def build_type(test_case) = test_case["build"] == "performance" ? "performance" : "e2e"
    def package(test_case) = APP + (test_case["build"] == "performance" ? ".performance" : "")
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def adb(args, **options)
      @context.command([@adb, "-s", @serial, *args], **options)
    end

    def shell(args, **options)
      adb(["shell", Shellwords.join(args)], **options)
    end

    def gradle(tasks)
      @context.command([File.join(@root, "apps/android/gradlew"), "--project-dir", "apps/android", "--console=plain", *tasks], timeout: 2400, log: File.join(@context.output, "build.log"))
    end

    def install(test_case)
      @products.fetch(build_type(test_case)).each_with_index do |path, index|
        pkg = package(test_case) + (index == 1 ? ".test" : "")
        installed = shell(["pm", "path", pkg], check: false).strip.delete_prefix("package:")
        if installed.start_with?("/data/app/") && !installed.match?(/[\r\n]/)
          remote_hash = shell(["sha256sum", installed], check: false).split.first
          next if remote_hash == Digest::SHA256.file(path).hexdigest
        end
        raise PipelineError, "Install failed for isolated #{pkg}" unless adb(["install", "-r", "-t", path], timeout: 180).include?("Success")
      end
    end

    def attempt(problems)
      yield
    rescue StandardError => error
      problems << error.message
    end

    def capture(test_case, pkg, dir, problems)
      # Instrumentation owns these isolated external artifacts. A missing pull
      # is qualified by the required native/flow evidence rather than its status.
      adb(["pull", "/sdcard/Android/data/#{pkg}/files", File.join(dir, "captures")], timeout: 30, check: false)
      unless test_case["native"]
        attempt(problems) do
          data = adb(["exec-out", "run-as", pkg, "tar", "-cf", "-", "-C", "files", "e2e"], timeout: 15, binary: true)
          archive = File.join(@context.private_dir, "#{test_case.fetch('id')}.tar")
          Atomic.write(archive, data)
          @contract.call("extract", {path: archive, output: dir}, json: false)
          raise PipelineError, "Missing flow step events" unless File.file?(File.join(dir, "e2e/events.jsonl"))
        end
      end
      unless File.file?(File.join(dir, "failure.png"))
        attempt([]) do
          png = adb(["exec-out", "screencap", "-p"], timeout: 15, binary: true)
          Atomic.write(File.join(dir, "final.png"), png) if png.start_with?("\x89PNG".b)
        end
      end
    end
  end
end
