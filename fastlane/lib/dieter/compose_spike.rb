# frozen_string_literal: true

require_relative "runtime"

module Dieter
  # Opt-in mobile experiment. Uses the production ownership and native-result contracts.
  module ComposeSpike
    IOS_CASE = {
      "id" => "compose.ios",
      "timeout" => "15m",
      "fixture" => "gateway",
      "native" => {
        "target" => "DieterComposeSpikeUITests",
        "class" => "ComposeSpikeUITests",
        "methods" => ["testSharedTaskJourney"]
      }
    }.freeze

    def self.invoke(options)
      values = options.transform_keys(&:to_s)
      unless (values.keys - %w[action profile profiles output]).empty?
        raise PipelineError, "Unknown Compose spike option"
      end
      action = values.fetch("action", "test")
      unless %w[test android_build ios_build ios_e2e ios_qualify android_e2e].include?(action)
        raise PipelineError, "Unknown Compose spike action"
      end
      context = RunContext.new(Config.new(Runtime::ROOT), output: values["output"])
      puts "Compose spike evidence: #{context.output}"
      begin
        context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
        case action
        when "test"
          gradle(context, "apps/core", %w[:mobile:jvmTest])
        when "android_build"
          android_build(context)
        when "ios_build"
          ComposeSpikeIOS.new(context).build({})
        when "ios_e2e", "ios_qualify"
          profiles =
            (
              if action == "ios_e2e"
                values.fetch("profile", "ios-iphone")
              else
                values.fetch("profiles", "ios-iphone,ios-ipad")
              end
            )
          ios_qualify(context, profiles: profiles)
        when "android_e2e"
          android_e2e(context, values)
        end
      ensure
        context.close
      end
    end

    def self.android_build(context)
      context.lease("android-build")
      gradle(context, "apps/mobile/android", %w[:app:assembleDebug :app:assembleDebugAndroidTest])
      ArtifactSet.new(
        component: "compose-android",
        source: context.command(%w[git rev-parse HEAD], timeout: 30).strip,
        configuration: "debug",
        toolchain: {
          "version" => context.environment.fetch("DIETER_RELEASE_VERSION")
        },
        products: {
          "apk" =>
            File.join(
              context.root,
              "apps/mobile/android/app/build/outputs/apk/debug/app-debug.apk"
            ),
          "test-apk" =>
            File.join(
              context.root,
              "apps/mobile/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
            )
        }
      ).write(File.join(context.output, "artifacts.json"))
    end

    def self.ios_qualify(context, profiles: "ios-iphone,ios-ipad")
      Runtime.ios_qualify(
        { profiles: profiles },
        parent: context,
        adapter_class: ComposeSpikeIOS,
        planned_cases: [IOS_CASE]
      )
    end

    def self.gradle(context, directory, tasks)
      context.command(
        [
          File.join(context.root, "apps/core/gradlew"),
          "--project-dir",
          directory,
          "--console=plain",
          "--max-workers=2",
          "-Pdieter.composeSpike=true",
          *tasks
        ],
        timeout: 3600,
        log: File.join(context.output, "gradle.log")
      )
    end

    def self.android_e2e(context, values)
      context.lease("android-build")
      gradle(context, "apps/mobile/android", %w[:app:assembleDebug :app:assembleDebugAndroidTest])
      target =
        context.config.profile(values.fetch("profile", "android-emulator"), component: "android")
      unless target["kind"] == "emulator"
        raise PipelineError, "Compose spike requires an isolated emulator"
      end
      sdk = context.environment.fetch("ANDROID_HOME")
      serial = target.fetch("serial")
      context.lease("android-device", identity: serial)
      AndroidEmulator.new(context, sdk, target).start
      adb = [File.join(sdk, "platform-tools/adb"), "-s", serial]
      pkg = "com.dbpprt.dieter.compose.spike"
      unless context.command([*adb, "shell", "pidof", pkg], check: false).strip.empty?
        raise Unavailable, "Spike app is already running; preserve its owner"
      end
      fixture =
        GatewayFixture.new(context, "compose", context.private_dir, evidence: context.output)
      port = nil
      context.cleanup { fixture.close }
      begin
        data = fixture.start
        port = data.fetch("DIETER_ISOLATED_ADDR").split(":").last
        context.command([*adb, "reverse", "--no-rebind", "tcp:#{port}", "tcp:#{port}"])
        context.cleanup { context.command([*adb, "reverse", "--remove", "tcp:#{port}"]) }
        %w[
          app/build/outputs/apk/debug/app-debug.apk
          app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
        ].each do |path|
          context.command(
            [*adb, "install", "-r", File.join(context.root, "apps/mobile/android", path)],
            timeout: 180
          )
          installed = path.include?("androidTest") ? "#{pkg}.test" : pkg
          context.cleanup { context.command([*adb, "uninstall", installed]) }
        end
        context.cleanup { context.command([*adb, "shell", "am", "force-stop", pkg]) }
        context.command([*adb, "shell", "pm", "clear", pkg])
        # Avoid first-run dex compilation consuming the emulator's process-start deadline.
        [pkg, "#{pkg}.test"].each do |package|
          context.command(
            [*adb, "shell", "cmd", "package", "compile", "-m", "speed", "-f", package],
            timeout: 180
          )
        end
        args = [
          "am",
          "instrument",
          "-w",
          "-r",
          "-e",
          "class",
          "com.dbpprt.dieter.spike.ComposeSpikeTest#sharedTaskJourney",
          "-e",
          "fixture_url",
          "http://127.0.0.1:#{port}",
          "-e",
          "fixture_token",
          data.fetch("DIETER_ISOLATED_TOKEN"),
          "#{pkg}.test/androidx.test.runner.AndroidJUnitRunner"
        ]
        log = File.join(context.output, "instrumentation.log")
        context.command([*adb, "shell", Shellwords.join(args)], timeout: 600, log: log)
        native = {
          "class" => "com.dbpprt.dieter.spike.ComposeSpikeTest",
          "methods" => ["sharedTaskJourney"]
        }
        result =
          Contract.new(context).call(
            "qualify",
            { platform: "android", path: log, case: { id: "compose.android", native: native } }
          )
        Atomic.json(File.join(context.output, "result.json"), result)
        raise PipelineError, result["reason"] unless result["status"] == "passed"
      ensure
        context.command(
          [*adb, "logcat", "-d", "-t", "1200"],
          timeout: 30,
          log: File.join(context.output, "android-logcat.log"),
          stream: false,
          check: false
        )
        context.command(
          [*adb, "pull", "/sdcard/Android/data/#{pkg}/files/compose-screenshots", context.output],
          timeout: 60,
          check: false
        )
      end
      %w[board task new-task conversation review machines].each do |screen|
        path = File.join(context.output, "compose-screenshots", "android-#{screen}.png")
        raise PipelineError, "Missing Android screenshot: #{screen}" unless File.size?(path)
      end
    end
  end

  class ComposeSpikeIOS < IOS
    def initialize(context, actions: nil)
      super(
        context,
        actions: actions,
        project: "apps/mobile/ios/DieterComposeSpike.xcodeproj",
        scheme: "DieterComposeSpike",
        screenshots: true,
        fixture_suite: "compose"
      )
      @derived = File.join(context.root, "apps/mobile/ios/.build/DerivedData")
      @products = File.join(@derived, "Build/Products")
      @bundle_id = "com.dbpprt.dieter.compose.spike.ios"
      @context.environment["DIETER_SWIFT_TEST_SCOPE"] = "compose-spike"
    end

    def product_component = "compose-ios"
    def build_input_paths = BuildInputs::COMPOSE_IOS
    def simulator_bundle_id = "com.dbpprt.dieter.compose.spike.ios"

    def build(_options)
      @context.lease("apple-build")
      ComposeSpike.gradle(@context, "apps/core", %w[:mobile:linkDebugFrameworkIosSimulatorArm64])
      framework = File.join(@root, "apps/mac/Frameworks/DieterComposeSpike.xcframework")
      FileUtils.rm_rf(framework) if File.directory?(framework)
      @context.command(
        [
          "xcodebuild",
          "-create-xcframework",
          "-framework",
          File.join(
            @root,
            "apps/core/mobile/build/bin/iosSimulatorArm64/debugFramework/DieterShared.framework"
          ),
          "-output",
          framework
        ],
        timeout: 120
      )
      Dir.glob(File.join(@products, "*.xctestrun")).each { |path| File.unlink(path) }
      @context.environment["DIETER_SWIFT_TEST_SCOPE"] = "compose-spike"
      with_detectable_simulator do
        NativeAction.run(
          @context,
          "run_tests",
          {
            project: @project,
            scheme: @scheme,
            configuration: "Debug",
            destination: "generic/platform=iOS Simulator",
            derived_data_path: @derived,
            build_for_testing: true,
            skip_build: true,
            skip_detect_devices: true,
            skip_slack: true,
            output_types: "",
            output_directory: @context.private_dir,
            buildlog_path: @context.private_dir,
            xcargs:
              "-jobs 2 ARCHS=arm64 CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DIETER_RELEASE_VERSION=#{@context.environment.fetch("DIETER_RELEASE_VERSION")}"
          },
          timeout: 2400,
          log: File.join(@context.output, "ios-build.log")
        )
      end
      candidates = Dir.glob(File.join(@products, "*.xctestrun"))
      raise PipelineError, "Missing spike test products" unless candidates.length == 1
      record_products(configuration: "debug", sdk: "iphonesimulator", xctestrun: candidates.first)
    end
  end
end
