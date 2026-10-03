# frozen_string_literal: true

require "uri"
require "securerandom"
require_relative "framework"
require_relative "../fixtures/gateway"
require_relative "../fixtures/screen"
require_relative "../fixtures/device_route"
require_relative "../pipeline/contract"

module Dieter
  class IOS
    UUID = /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/

    def initialize(context, actions: nil)
      @context, @root, @actions = context, context.root, actions
      @contract = Contract.new(context)
      @derived = File.join(@root, "apps/ios/.build/DerivedData")
      @products = File.join(@derived, "Build/Products")
    end

    def unit(options)
      Mac.new(@context).unit(options.merge("filter" => options.fetch("filter", "DieterIOSTests")))
    end

    def build(options)
      @context.lease("apple-build")
      physical = @target && @target["kind"] == "device"
      if physical
        @derived = File.join(@root, "apps/ios/.build/DerivedDataDevice")
        @products = File.join(@derived, "Build/Products")
      end
      SharedFramework.new(@context).build(configuration: "debug", platforms: physical ? "all" : "ios-simulator")
      sdk = physical ? "iphoneos" : "iphonesimulator"
      Dir.glob(File.join(@products, "*#{sdk}*.xctestrun")).each { |path| File.unlink(path) }
      argv = ["xcodebuild", "-skipPackagePluginValidation", "-project", "apps/ios/DieterIOS.xcodeproj", "-scheme", physical ? "DieterIOSE2E" : "DieterIOS", "-configuration", "Debug", "-destination", physical ? "generic/platform=iOS" : "generic/platform=iOS Simulator", "-derivedDataPath", @derived, "build-for-testing", "ARCHS=arm64", "CODE_SIGNING_ALLOWED=YES", "DIETER_RELEASE_VERSION=#{@context.environment.fetch('DIETER_RELEASE_VERSION')}"]
      argv += if physical
                ["DIETER_IOS_BUNDLE_ID=#{@signing.fetch('app_bundle_id')}", "DIETER_IOS_APP_GROUP_ID=#{@signing.fetch('app_group_id')}", "DIETER_IOS_TEAM_ID=#{@signing.fetch('team_id')}", "DEVELOPMENT_TEAM=#{@signing.fetch('team_id')}", "DIETER_IOS_SIGN_STYLE=Manual", "DIETER_IOS_SIGN_IDENTITY=#{@profiles.fetch('certificate')}", "DIETER_IOS_PROFILE_SPECIFIER=#{@profiles.fetch('app')}", "DIETER_IOS_SHARE_PROFILE_SPECIFIER=#{@profiles.fetch('share')}", "DIETER_IOS_TEST_PROFILE_SPECIFIER=#{@profiles.fetch('runner')}"]
              else
                ["CODE_SIGN_IDENTITY=-"]
              end
      @context.command(argv, timeout: 2400, log: File.join(@context.output, "build.log"))
      candidates = Dir.glob(File.join(@products, "*#{sdk}*.xctestrun"))
      raise PipelineError, "Expected one build-for-testing plan" unless candidates.length == 1
      source = @context.command(["git", "rev-parse", "HEAD"], timeout: 30).strip
      ArtifactSet.new(component: "ios", source: source, configuration: "debug", products: {"xctestrun" => candidates.first, "app" => File.join(@products, "Debug-#{sdk}/Dieter.app")}).write(File.join(@context.output, "artifacts.json"))
      candidates.first
    end

    def admit(target, _plan)
      raise Unavailable, "iOS tests require macOS/Xcode" unless RUBY_PLATFORM.include?("darwin")
      @target = target
      if target.fetch("kind") == "device"
        @context.lease("ios-device", identity: target.fetch("udid"))
        @context.lease("apple-build")
        @signing = @context.config.data.fetch("signing").fetch(target.fetch("signing"))
        app = @signing.fetch("app_bundle_id")
        raise PipelineError, "Physical iOS requires isolated E2E bundle/app-group identities" unless app && app.end_with?(".e2e") && @signing["share_bundle_id"] == app + ".share" && @signing["app_group_id"] == "group." + app
        raise Unavailable, "Physical iOS requires an existing development signing team" unless @signing["team_id"] && !@signing["team_id"].empty?
        DeviceFixtureRoute.new(@context, target, @context.private_dir)
        inventory = File.join(@context.private_dir, "ios-devices.json")
        @context.command(["xcrun", "devicectl", "--timeout", "30", "--json-output", inventory, "list", "devices"], timeout: 45)
        devices = JSON.parse(File.read(inventory)).fetch("result").fetch("devices")
        matches = devices.select { |device| device.dig("hardwareProperties", "udid") == target.fetch("udid") || device["identifier"] == target.fetch("udid") }
        raise Unavailable, "Exact physical iOS device is not connected: #{target.fetch('udid')}" unless matches.length == 1 && matches.first.dig("deviceProperties", "developerModeStatus") == "enabled"
        raise Unavailable, "Selected iOS device requires Developer Mode and an unlocked trusted connection" unless matches.first.dig("connectionProperties", "tunnelState") == "connected"
        @profiles = JSON.parse(@context.command(["python3", "fastlane/lib/dieter/native/ios_development.py"], input: JSON.generate({team: @signing.fetch("team_id"), device: target.fetch("udid"), app: app, share: @signing.fetch("share_bundle_id"), group: @signing.fetch("app_group_id")}), timeout: 120, binary: true))
        admit_device_packages
        return
      end
      @context.lease("ios-simulator")
      @context.lease("apple-build")
      @journal = File.join(@root, "tmp/e2e-cache/ios-simulator.json")
      recover_simulator
      inventory = JSON.parse(@context.command(["xcrun", "simctl", "list", "-j"], timeout: 120, binary: true))
      runtime = inventory.fetch("runtimes").find { |entry| entry["identifier"] == target.fetch("runtime") && entry["isAvailable"] }
      raise Unavailable, "Configured iOS runtime is not installed: #{target.fetch('runtime')}" unless runtime
      raise Unavailable, "Configured simulator type is not installed" unless inventory.fetch("devicetypes").any? { |entry| entry["identifier"] == target.fetch("device_type") }
    end

    def prepare(target, _plan)
      build({})
      GatewayFixture.compile(@context)
      return if target.fetch("kind") == "device"
      @simulator_name = "Dieter Pipeline #{SecureRandom.uuid}"
      @simulator = @context.command(["xcrun", "simctl", "create", @simulator_name, target.fetch("device_type"), target.fetch("runtime")], timeout: 30, binary: true).strip
      raise PipelineError, "Invalid owned simulator identity" unless UUID.match?(@simulator)
      Atomic.json(@journal, {"ID" => @simulator, "Name" => @simulator_name})
      @context.cleanup { delete_simulator(@simulator); File.unlink(@journal) if File.file?(@journal) }
      @context.command(["xcrun", "simctl", "bootstatus", @simulator, "-b"], timeout: 180, log: File.join(@context.output, "boot.log"))
      @context.command(["xcrun", "simctl", "spawn", @simulator, "defaults", "write", "com.apple.keyboard.preferences", "DidShowContinuousPathIntroduction", "-bool", "true"], timeout: 120)
    end

    def execute_case(target, test_case)
      started = monotonic
      dir = File.join(@context.output, test_case.fetch("id"))
      FileUtils.mkdir_p(dir, mode: 0o700)
      state = Dir.mktmpdir("ios-case-", @context.private_dir)
      fixture, screen, route = nil, nil, nil
      result = {"status" => "failed", "reason" => "", "setupMs" => 0, "executionMs" => 0}
      begin
        environment = {"DIETER_IOS_TEST_LANDSCAPE" => target["layout"] == "ipad" ? "1" : "0"}
        if test_case.fetch("fixture") == "gateway"
          offline = File.join(state, "offline")
          fixture = GatewayFixture.new(@context, "ios", state, evidence: dir, offline_trigger: offline)
          values = fixture.start
          %w[TOKEN DAEMON INCOMPATIBLE_DAEMON PROJECT BOARD].each do |key|
            value = values.fetch("DIETER_ISOLATED_#{key}")
            raise PipelineError, "Gateway missing #{key}" if value.empty?
            environment["DIETER_IOS_TEST_#{key}"] = value
          end
          environment["DIETER_IOS_TEST_GATEWAY"] = "http://#{values.fetch('DIETER_ISOLATED_ADDR')}"
          environment["DIETER_IOS_TEST_OFFLINE_TRIGGER"] = offline
          if target["kind"] == "device"
            route = DeviceFixtureRoute.new(@context, target, state)
            endpoint = route.start(upstream: environment.fetch("DIETER_IOS_TEST_GATEWAY"), token: values.fetch("DIETER_ISOLATED_TOKEN"), offline_file: offline)
            environment["DIETER_IOS_TEST_GATEWAY"] = endpoint
            environment["DIETER_IOS_TEST_OFFLINE_TRIGGER"] = endpoint + "/_fixture/offline"
            environment["DIETER_IOS_TEST_CONTROL_TOKEN"] = route.control_token
          end
        elsif test_case.fetch("fixture") == "screen"
          screen = ScreenFixture.new(@context, state, dir, native_only: true)
          values, = screen.start
          environment["DIETER_IOS_TEST_SCREEN_FIXTURE"] = values.fetch("screenFixture")
          if target["kind"] == "device"
            descriptor = JSON.parse(Base64.strict_decode64(values.fetch("screenFixture")))
            route = DeviceFixtureRoute.new(@context, target, state)
            descriptor["url"] = route.start(upstream: descriptor.fetch("url"), token: descriptor.fetch("token"), offline_file: File.join(state, "unused-offline"))
            descriptor["certificate"] = Base64.strict_encode64(route.certificate_pem)
            environment["DIETER_IOS_TEST_SCREEN_FIXTURE"] = Base64.strict_encode64(JSON.generate(descriptor))
            @context.secrets << environment.fetch("DIETER_IOS_TEST_SCREEN_FIXTURE")
          end
        end
        if test_case.fetch("id") == "ios.https-auth"
          endpoint = ENV.fetch("DIETER_IOS_TEST_HTTPS_GATEWAY", "")
          uri = URI.parse(endpoint)
          raise Unavailable, "ios.https-auth requires a credential-free HTTPS endpoint" unless uri.scheme == "https" && uri.host && !uri.user && !uri.query && !uri.fragment
          environment["DIETER_IOS_TEST_HTTPS_GATEWAY"] = endpoint
        end
        reset_owned_packages
        if test_case["id"] == "ios.share-extension"
          raise Unavailable, "Physical share-extension qualification requires its owned media fixture setup" if target["kind"] == "device"
          @context.command(["xcrun", "simctl", "addmedia", @simulator, File.join(@root, "apps/android/design/reference/phone-board.png")], timeout: 30)
        end
        spec = private_test_run(state, environment, test_case.fetch("native").fetch("target"))
        bundle = File.join(state, "result.xcresult")
        native = test_case.fetch("native")
        destination = target["kind"] == "device" ? "platform=iOS,id=#{target.fetch('udid')}" : "platform=iOS Simulator,id=#{@simulator}"
        argv = ["xcodebuild", "test-without-building", "-xctestrun", spec, "-destination", destination, "-parallel-testing-enabled", "NO", "-destination-timeout", "30", "-collect-test-diagnostics", "never", "-resultBundlePath", bundle]
        argv += native.fetch("methods").map { |method| "-only-testing:#{native.fetch('target')}/#{native.fetch('class')}/#{method}" }
        result["setupMs"] = ((monotonic - started) * 1000).round
        began = monotonic
        process = @context.start(argv, log: File.join(dir, "tests.log"))
        @context.wait(process, timeout: 1200, check: false)
        result["executionMs"] = ((monotonic - began) * 1000).round
        @context.during_cleanup do
          nodes = @context.command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle, "--compact"], timeout: 60)
          Atomic.write(File.join(dir, "test-results.json"), nodes)
          result.merge!(@contract.call("qualify", {platform: "ios", path: File.join(dir, "test-results.json"), case: test_case}))
          if result["status"] == "passed" && !process.status.success?
            result.merge!("status" => "failed", "reason" => "XCTest process failed despite passing result fragments")
          end
          @context.command(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", File.join(dir, "attachments")], timeout: 60, check: false)
        end
      rescue StandardError => error
        result["status"] = error.is_a?(Unavailable) ? "unavailable" : error.is_a?(Interrupted) ? "interrupted" : "failed"
        result["reason"] = error.message
      ensure
        problems = []
        @context.during_cleanup do
          [route, screen, fixture].compact.each do |owned|
            owned.close
          rescue StandardError => error
            problems << error.message
          end
          if target["kind"] == "device"
            begin
              reset_owned_packages
            rescue StandardError => error
              problems << error.message
            end
          end
          FileUtils.remove_entry_secure(state) if problems.empty?
        end
        result["cleanupError"] = problems.join("; ")
      end
      result
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def recover_simulator
      return unless File.file?(@journal)
      owner = JSON.parse(File.read(@journal))
      raise PipelineError, "Invalid simulator ownership journal" unless UUID.match?(owner.fetch("ID")) && owner.fetch("Name").match?(/\ADieter (?:Pipeline |E2E dieter-ios-case-)/)
      inventory = JSON.parse(@context.command(["xcrun", "simctl", "list", "devices", "-j"], timeout: 120, binary: true))
      actual = inventory.fetch("devices").values.flatten.find { |device| device["udid"] == owner.fetch("ID") }
      raise PipelineError, "Recorded simulator identity changed; preserve its journal" if actual && actual["name"] != owner.fetch("Name")
      delete_simulator(owner.fetch("ID")) if actual
      File.unlink(@journal)
    end

    def delete_simulator(id)
      @context.command(["xcrun", "simctl", "shutdown", id], timeout: 30, check: false)
      @context.command(["xcrun", "simctl", "delete", id], timeout: 30)
    end

    def reset_owned_packages
      if @target["kind"] == "device"
        raise PipelineError, "Physical package reset requires its ownership journal" unless @device_packages && @device_journal && File.file?(@device_journal)
        @device_packages.each do |id|
          next unless device_package_present?(id)
          @context.command(["xcrun", "devicectl", "--timeout", "30", "device", "uninstall", "app", "--device", @target.fetch("udid"), id], timeout: 45)
          raise CleanupError, "Owned iOS fixture package remained installed: #{id}" if device_package_present?(id)
        end
        return
      end
      %w[com.dbpprt.dieter.ios com.dbpprt.dieter.ios.native-tests com.dbpprt.dieter.ios.uitests.xctrunner].each do |id|
        process = @context.start(["xcrun", "simctl", "get_app_container", @simulator, id])
        process.wait(timeout: 30, check: false)
        @context.command(["xcrun", "simctl", "uninstall", @simulator, id], timeout: 30) if process.status.success?
      end
    end

    def admit_device_packages
      app = @signing.fetch("app_bundle_id")
      @device_packages = [app, app + ".native-tests", app + ".uitests.xctrunner"]
      identity = {"udid" => @target.fetch("udid"), "packages" => @device_packages}
      @device_journal = File.join(@root, "tmp/e2e-cache/ios-device-#{Digest::SHA256.hexdigest(identity.fetch('udid'))}.json")
      if File.file?(@device_journal)
        previous = JSON.parse(File.read(@device_journal), object_class: UniqueObject, allow_duplicate_key: false)
        raise Unavailable, "Physical iOS ownership changed; preserve the existing journal" unless previous.slice("udid", "packages") == identity
        reset_owned_packages
      else
        existing = @device_packages.select { |id| device_package_present?(id) }
        raise Unavailable, "Physical iOS fixture apps already installed without ownership; preserve them: #{existing.join(', ')}" unless existing.empty?
      end
      Atomic.json(@device_journal, identity.merge("owner_pid" => Process.pid))
      @context.cleanup do
        reset_owned_packages
        File.unlink(@device_journal)
      end
    end

    def device_package_present?(id)
      inventory = File.join(@context.private_dir, "device-apps.json")
      @context.command(["xcrun", "devicectl", "--timeout", "30", "--json-output", inventory, "device", "info", "apps", "--device", @target.fetch("udid"), "--include-all-apps", "--bundle-id", id], timeout: 45)
      result = JSON.parse(File.read(inventory), object_class: UniqueObject, allow_duplicate_key: false).fetch("result").fetch("apps")
      raise PipelineError, "Unexpected device application inventory" unless result.is_a?(Array) && result.length <= 1 && result.all? { |app| app["bundleIdentifier"] == id }
      !result.empty?
    end

    def private_test_run(state, environment, target)
      sdk = @target["kind"] == "device" ? "iphoneos" : "iphonesimulator"
      candidates = Dir.glob(File.join(@products, "*#{sdk}*.xctestrun"))
      raise PipelineError, "Expected one build-for-testing plan" unless candidates.length == 1
      original = @context.command(["plutil", "-convert", "json", "-o", "-", candidates.first], timeout: 30, binary: true)
      input = File.join(state, "original.json")
      output = File.join(state, "DieterIOS.xctestrun")
      Atomic.write(input, original)
      @contract.call("xctestrun", {path: input, output: output, products: @products, values: environment, target: target}, json: false)
      @context.command(["plutil", "-convert", "xml1", output], timeout: 30)
      output
    end
  end
end
