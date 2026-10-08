# frozen_string_literal: true

require "uri"
require "securerandom"
require "shellwords"
require_relative "framework"
require_relative "apple_build"
require_relative "../fixtures/gateway"
require_relative "../fixtures/screen"
require_relative "../fixtures/device_route"
require_relative "../fixtures/ios_media"
require_relative "../pipeline/contract"
require_relative "../pipeline/action"
require_relative "../pipeline/inputs"

module Dieter
  class IOS
    UUID = /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/

    def initialize(
      context,
      actions: nil,
      project: "apps/ios/DieterIOS.xcodeproj",
      scheme: "DieterIOSE2E",
      screenshots: false,
      fixture_suite: "ios"
    )
      @context, @root, @actions = context, context.root, actions
      @project, @scheme, @screenshots = project, scheme, screenshots
      @fixture_suite = fixture_suite
      @contract = Contract.new(context)
      @derived = File.join(@root, "apps/ios/.build/DerivedData")
      @products = File.join(@derived, "Build/Products")
    end

    def unit(options)
      @context.lease("apple-build")
      SharedFramework.new(@context).build
      argv = [
        "swift",
        "test",
        "--package-path",
        "apps/mac",
        "--scratch-path",
        "apps/mac/.build/dieter-ios-policy",
        "--only-use-versions-from-resolved-file",
        "--disable-index-store",
        *AppleBuild.jobs(@context, tool: :swift)
      ]
      argv += ["--filter", options.fetch("filter")] if options["filter"]
      @context.command(
        argv,
        environment: {
          "DIETER_SWIFT_TEST_SCOPE" => "ios-policy"
        },
        timeout: 1200,
        log: File.join(@context.output, "ios-policy-tests.log")
      )
    end

    def build(options)
      configuration = options.fetch("configuration", "debug")
      unless %w[debug release].include?(configuration)
        raise PipelineError, "configuration must be debug or release"
      end
      @context.lease("apple-build")
      physical = @target && @target["kind"] == "device"
      @bundle_id = physical ? @signing.fetch("app_bundle_id") : "com.dbpprt.dieter.ios.e2e"
      if physical
        @derived = File.join(@root, "apps/ios/.build/DerivedDataDevice")
        @products = File.join(@derived, "Build/Products")
      end
      SharedFramework.new(@context).build(
        configuration: configuration,
        platforms: physical ? "ios-device" : "ios-simulator"
      )
      sdk = physical ? "iphoneos" : "iphonesimulator"
      Dir.glob(File.join(@products, "*#{sdk}*.xctestrun")).each { |path| File.unlink(path) }
      argv = [
        *AppleBuild.jobs(@context, tool: :xcode),
        "-skipPackagePluginValidation",
        "ARCHS=arm64",
        "CODE_SIGNING_ALLOWED=YES",
        "ENABLE_TESTABILITY=YES",
        "DIETER_RELEASE_VERSION=#{@context.environment.fetch("DIETER_RELEASE_VERSION")}"
      ]
      argv +=
        if physical
          [
            "DIETER_IOS_BUNDLE_ID=#{@signing.fetch("app_bundle_id")}",
            "DIETER_IOS_APP_GROUP_ID=#{@signing.fetch("app_group_id")}",
            "DIETER_IOS_TEAM_ID=#{@signing.fetch("team_id")}",
            "DEVELOPMENT_TEAM=#{@signing.fetch("team_id")}",
            "DIETER_IOS_SIGN_STYLE=Manual",
            "DIETER_IOS_SIGN_IDENTITY=#{@profiles.fetch("certificate")}",
            "DIETER_IOS_PROFILE_SPECIFIER=#{@profiles.fetch("app")}",
            "DIETER_IOS_SHARE_PROFILE_SPECIFIER=#{@profiles.fetch("share")}",
            "DIETER_IOS_TEST_PROFILE_SPECIFIER=#{@profiles.fetch("runner")}"
          ]
        else
          [
            "CODE_SIGN_IDENTITY=-",
            "DIETER_IOS_BUNDLE_ID=#{@bundle_id}",
            "DIETER_IOS_APP_GROUP_ID=group.#{@bundle_id}"
          ]
        end
      with_detectable_simulator do
        NativeAction.run(
          @context,
          "run_tests",
          {
            project: @project,
            scheme: @scheme,
            configuration: configuration.capitalize,
            destination: physical ? "generic/platform=iOS" : "generic/platform=iOS Simulator",
            derived_data_path: @derived,
            package_authorization_provider: "netrc",
            build_for_testing: true,
            skip_build: true,
            skip_detect_devices: true,
            skip_slack: true,
            output_types: "",
            output_directory: @context.private_dir,
            buildlog_path: @context.private_dir,
            xcodebuild_formatter: "",
            xcargs: Shellwords.join(argv)
          },
          timeout: 2400,
          log: File.join(@context.output, "build.log")
        )
      end
      candidates = Dir.glob(File.join(@products, "*#{sdk}*.xctestrun"))
      raise PipelineError, "Expected one build-for-testing plan" unless candidates.length == 1
      record_products(configuration: configuration, sdk: sdk, xctestrun: candidates.first)
      candidates.first
    end

    def record_products(configuration:, sdk:, xctestrun:)
      source = @context.command(%w[git rev-parse HEAD], timeout: 30).strip
      ArtifactSet.new(
        component: product_component,
        source: source,
        configuration: configuration,
        toolchain: {
          "input_sha256" => BuildInputs.digest(@context, paths: build_input_paths),
          "sdk" => sdk,
          "xcode" => @context.command(%w[xcodebuild -version], timeout: 30)
        },
        products: {
          "xctestrun" => xctestrun,
          "test-products" => @products
        }
      ).write(File.join(@context.output, "artifacts.json"))
    end

    def product_component = "ios"
    def build_input_paths = BuildInputs::IOS
    def simulator_bundle_id = "com.dbpprt.dieter.ios.e2e"

    def admit(target, plan)
      raise Unavailable, "iOS tests require macOS/Xcode" unless RUBY_PLATFORM.include?("darwin")
      @target = target
      @share_files =
        target.fetch("kind") == "device" ||
          plan.any? do |test_case|
            %w[ios.share-extension ios.share-owned-file].include?(test_case["id"])
          end
      if target.fetch("kind") == "device"
        @context.lease("ios-device", identity: target.fetch("udid"))
        @context.lease("apple-build")
        @signing = @context.config.data.fetch("signing").fetch(target.fetch("signing"))
        app = @signing.fetch("app_bundle_id")
        unless app && app.end_with?(".e2e") && @signing["share_bundle_id"] == app + ".share" &&
                 @signing["app_group_id"] == "group." + app
          raise PipelineError, "Physical iOS requires isolated E2E bundle/app-group identities"
        end
        unless @signing["team_id"] && !@signing["team_id"].empty?
          raise Unavailable, "Physical iOS requires an existing development signing team"
        end
        DeviceFixtureRoute.new(@context, target, @context.private_dir)
        inventory = File.join(@context.private_dir, "ios-devices.json")
        @context.command(
          ["xcrun", "devicectl", "--timeout", "30", "--json-output", inventory, "list", "devices"],
          timeout: 45
        )
        devices = JSON.parse(File.read(inventory)).fetch("result").fetch("devices")
        matches =
          devices.select do |device|
            device.dig("hardwareProperties", "udid") == target.fetch("udid") ||
              device["identifier"] == target.fetch("udid")
          end
        unless matches.length == 1 &&
                 matches.first.dig("deviceProperties", "developerModeStatus") == "enabled"
          raise Unavailable, "Exact physical iOS device is not connected: #{target.fetch("udid")}"
        end
        unless matches.first.dig("connectionProperties", "tunnelState") == "connected"
          raise Unavailable,
                "Selected iOS device requires Developer Mode and an unlocked trusted connection"
        end
        @profiles =
          JSON.parse(
            @context.command(
              %w[python3 fastlane/lib/dieter/native/ios_development.py],
              input:
                JSON.generate(
                  {
                    team: @signing.fetch("team_id"),
                    device: target.fetch("udid"),
                    app: app,
                    share: @signing.fetch("share_bundle_id"),
                    group: @signing.fetch("app_group_id")
                  }
                ),
              timeout: 120,
              binary: true
            )
          )
        admit_device_packages
        return
      end
      @context.lease("ios-simulator")
      @context.lease("apple-build")
      @journal = File.join(@root, "tmp/e2e-cache/ios-simulator.json")
      recover_simulator
      inventory = JSON.parse(@context.command(%w[xcrun simctl list -j], timeout: 120, binary: true))
      runtime =
        inventory
          .fetch("runtimes")
          .find { |entry| entry["identifier"] == target.fetch("runtime") && entry["isAvailable"] }
      unless runtime
        raise Unavailable, "Configured iOS runtime is not installed: #{target.fetch("runtime")}"
      end
      unless inventory
               .fetch("devicetypes")
               .any? { |entry| entry["identifier"] == target.fetch("device_type") }
        raise Unavailable, "Configured simulator type is not installed"
      end
    end

    def prepare(target, _plan)
      @prepared_manifest ? reuse_products(target) : build({})
      GatewayFixture.compile(@context)
      return if target.fetch("kind") == "device"
      @simulator_name = "Dieter Pipeline #{SecureRandom.uuid}"
      @simulator =
        @context.command(
          [
            "xcrun",
            "simctl",
            "create",
            @simulator_name,
            target.fetch("device_type"),
            target.fetch("runtime")
          ],
          timeout: 30,
          binary: true
        ).strip
      raise PipelineError, "Invalid owned simulator identity" unless UUID.match?(@simulator)
      Atomic.json(@journal, { "ID" => @simulator, "Name" => @simulator_name })
      simulator, journal = @simulator, @journal
      @context.cleanup do
        delete_simulator(simulator)
        File.unlink(journal) if File.file?(journal)
      end
      # Hosted runners take up to about 140s to boot and the first spawn waits up to
      # about 100s more for the system apps.
      @context.command(
        ["xcrun", "simctl", "bootstatus", @simulator, "-b"],
        timeout: 300,
        log: File.join(@context.output, "boot.log")
      )
      @context.command(
        [
          "xcrun",
          "simctl",
          "spawn",
          @simulator,
          "defaults",
          "write",
          "com.apple.keyboard.preferences",
          "DidShowContinuousPathIntroduction",
          "-bool",
          "true"
        ],
        timeout: 300
      )
    end

    def prepared_products(manifest)
      @prepared_manifest = manifest
    end

    def execute_case(target, test_case)
      started = monotonic
      dir = File.join(@context.output, test_case.fetch("id"))
      FileUtils.mkdir_p(dir, mode: 0o700)
      state = Dir.mktmpdir("ios-case-", @context.private_dir)
      fixture, screen, route = nil, nil, nil
      result = { "status" => "failed", "reason" => "", "setupMs" => 0, "executionMs" => 0 }
      begin
        environment = { "DIETER_IOS_TEST_LANDSCAPE" => target["layout"] == "ipad" ? "1" : "0" }
        if test_case.fetch("fixture") == "gateway"
          offline = File.join(state, "offline")
          fixture =
            GatewayFixture.new(
              @context,
              @fixture_suite,
              state,
              evidence: dir,
              offline_trigger: offline
            )
          values = fixture.start
          %w[TOKEN DAEMON INCOMPATIBLE_DAEMON PROJECT BOARD].each do |key|
            value = values.fetch("DIETER_ISOLATED_#{key}")
            raise PipelineError, "Gateway missing #{key}" if value.empty?
            environment["DIETER_IOS_TEST_#{key}"] = value
          end
          environment["DIETER_IOS_TEST_GATEWAY"] = "http://#{values.fetch("DIETER_ISOLATED_ADDR")}"
          environment["DIETER_IOS_TEST_OFFLINE_TRIGGER"] = offline
          if target["kind"] == "device"
            route = DeviceFixtureRoute.new(@context, target, state)
            endpoint =
              route.start(
                upstream: environment.fetch("DIETER_IOS_TEST_GATEWAY"),
                token: values.fetch("DIETER_ISOLATED_TOKEN"),
                offline_file: offline
              )
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
            descriptor["url"] = route.start(
              upstream: descriptor.fetch("url"),
              token: descriptor.fetch("token"),
              offline_file: File.join(state, "unused-offline")
            )
            descriptor["certificate"] = Base64.strict_encode64(route.certificate_pem)
            environment["DIETER_IOS_TEST_SCREEN_FIXTURE"] = Base64.strict_encode64(
              JSON.generate(descriptor)
            )
            @context.secrets << environment.fetch("DIETER_IOS_TEST_SCREEN_FIXTURE")
          end
        end
        if test_case.fetch("id") == "ios.https-auth"
          endpoint = ENV.fetch("DIETER_IOS_TEST_HTTPS_GATEWAY", "")
          uri = URI.parse(endpoint)
          unless uri.scheme == "https" && uri.host && !uri.user && !uri.query && !uri.fragment
            raise Unavailable, "ios.https-auth requires a credential-free HTTPS endpoint"
          end
          environment["DIETER_IOS_TEST_HTTPS_GATEWAY"] = endpoint
        end
        reset_owned_packages
        if %w[ios.share-extension ios.share-owned-file].include?(test_case["id"])
          sdk = target["kind"] == "device" ? "iphoneos" : "iphonesimulator"
          media =
            IOSMediaFixture.new(
              @context,
              target,
              app: File.join(@products, "Debug-#{sdk}/Dieter.app"),
              bundle_id: @bundle_id,
              journal: target["kind"] == "device" ? @device_journal : @journal,
              simulator: @simulator,
              evidence: dir
            )
          environment["DIETER_IOS_TEST_SHARE_FILE"] = media.stage
        end
        spec = private_test_run(state, environment, test_case.fetch("native").fetch("target"))
        bundle = File.join(state, "result.xcresult")
        native = test_case.fetch("native")
        destination =
          (
            if target["kind"] == "device"
              "platform=iOS,id=#{target.fetch("udid")}"
            else
              "platform=iOS Simulator,id=#{@simulator}"
            end
          )
        result["setupMs"] = ((monotonic - started) * 1000).round
        began = monotonic
        process =
          NativeAction.start(
            @context,
            "run_tests",
            {
              project: @project,
              scheme: @scheme,
              derived_data_path: @derived,
              xctestrun: spec,
              destination: destination,
              test_without_building: true,
              skip_build: true,
              skip_detect_devices: true,
              parallel_testing: false,
              disable_concurrent_testing: true,
              only_testing:
                native
                  .fetch("methods")
                  .map { |method| "#{native.fetch("target")}/#{native.fetch("class")}/#{method}" },
              result_bundle_path: bundle,
              output_directory: state,
              buildlog_path: state,
              output_types: "",
              skip_slack: true,
              number_of_retries: 0,
              xcodebuild_formatter: "",
              xcargs: "-destination-timeout 30 -collect-test-diagnostics never"
            },
            log: File.join(dir, "tests.log")
          )
        @context.wait(process, timeout: 1200, check: false)
        result["executionMs"] = ((monotonic - began) * 1000).round
        @context.during_cleanup do
          nodes =
            @context.command(
              [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "tests",
                "--path",
                bundle,
                "--compact"
              ],
              timeout: 60
            )
          Atomic.write(File.join(dir, "test-results.json"), nodes)
          result.merge!(
            @contract.call(
              "qualify",
              { platform: "ios", path: File.join(dir, "test-results.json"), case: test_case }
            )
          )
          if result["status"] == "passed" && !process.status.success?
            result.merge!(
              "status" => "failed",
              "reason" => "XCTest process failed despite passing result fragments"
            )
          end
          if @screenshots || result["status"] != "passed"
            @context.command(
              [
                "xcrun",
                "xcresulttool",
                "export",
                "attachments",
                "--path",
                bundle,
                *(@screenshots ? [] : ["--only-failures"]),
                "--output-path",
                File.join(dir, "attachments")
              ],
              timeout: 60,
              check: false
            )
          end
        end
      rescue StandardError => error
        result["status"] = error.is_a?(Unavailable) ?
          "unavailable" :
          error.is_a?(Interrupted) ? "interrupted" : "failed"
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

    def reuse_products(target)
      unless target.fetch("kind") == "simulator"
        raise PipelineError, "Prepared simulator products cannot target a physical device"
      end
      manifest =
        ArtifactSet.load(
          @prepared_manifest,
          component: product_component,
          source: @context.command(%w[git rev-parse HEAD], timeout: 30).strip
        ).manifest
      toolchain = manifest.fetch("toolchain")
      unless manifest["configuration"] == "debug" && toolchain["sdk"] == "iphonesimulator" &&
               toolchain["input_sha256"] ==
                 BuildInputs.digest(@context, paths: build_input_paths) &&
               toolchain["xcode"] == @context.command(%w[xcodebuild -version], timeout: 30)
        raise PipelineError, "Prepared iOS inputs or toolchain changed"
      end
      product = manifest.fetch("products").find { |entry| entry["kind"] == "test-products" }
      raise PipelineError, "Prepared iOS test products are missing" unless product
      @products = product.fetch("path")
      @bundle_id = simulator_bundle_id
      puts "Reusing verified iOS test products for #{target.fetch("name")}"
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Fastlane's run_tests resolves an installed iOS simulator for every iOS
    # project, even for a generic build-for-testing destination, and fails when
    # none exists. Without one, the build owns a disposable simulator that is
    # never booted and deletes it afterwards. Other simulators are only read.
    def with_detectable_simulator
      journal = File.join(@root, "tmp/e2e-cache/ios-build-simulator.json")
      recover_simulator(journal)
      inventory = JSON.parse(@context.command(%w[xcrun simctl list -j], timeout: 120, binary: true))
      installed =
        inventory
          .fetch("devices")
          .any? do |runtime, devices|
            runtime.include?(".SimRuntime.iOS-") && devices.any? { |device| device["isAvailable"] }
          end
      return yield if installed
      runtime =
        inventory
          .fetch("runtimes")
          .select { |entry| entry["platform"] == "iOS" && entry["isAvailable"] }
          .max_by { |entry| Gem::Version.new(entry.fetch("version")) }
      raise Unavailable, "iOS builds require an installed iOS simulator runtime" unless runtime
      type =
        runtime
          .fetch("supportedDeviceTypes", [])
          .find { |entry| entry["productFamily"] == "iPhone" }
      raise Unavailable, "The installed iOS simulator runtime supports no iPhone" unless type
      name = "Dieter Pipeline build #{SecureRandom.uuid}"
      simulator =
        @context.command(
          [
            "xcrun",
            "simctl",
            "create",
            name,
            type.fetch("identifier"),
            runtime.fetch("identifier")
          ],
          timeout: 30,
          binary: true
        ).strip
      raise PipelineError, "Invalid owned simulator identity" unless UUID.match?(simulator)
      Atomic.json(journal, { "ID" => simulator, "Name" => name })
      begin
        yield
      ensure
        delete_simulator(simulator)
        File.unlink(journal)
      end
    end

    def recover_simulator(journal = @journal)
      return unless File.file?(journal)
      owner = JSON.parse(File.read(journal))
      unless UUID.match?(owner.fetch("ID")) &&
               owner.fetch("Name").match?(/\ADieter (?:Pipeline |E2E dieter-ios-case-)/)
        raise PipelineError, "Invalid simulator ownership journal"
      end
      inventory =
        JSON.parse(@context.command(%w[xcrun simctl list devices -j], timeout: 120, binary: true))
      actual =
        inventory
          .fetch("devices")
          .values
          .flatten
          .find { |device| device["udid"] == owner.fetch("ID") }
      if actual && actual["name"] != owner.fetch("Name")
        raise PipelineError, "Recorded simulator identity changed; preserve its journal"
      end
      delete_simulator(owner.fetch("ID")) if actual
      File.unlink(journal)
    end

    def delete_simulator(id)
      # Shutting down a booted simulator takes over 30s on hosted runners.
      @context.command(["xcrun", "simctl", "shutdown", id], timeout: 120, check: false)
      @context.command(["xcrun", "simctl", "delete", id], timeout: 120)
    end

    def reset_owned_packages
      if @target["kind"] == "device"
        unless @device_packages && @device_journal && File.file?(@device_journal)
          raise PipelineError, "Physical package reset requires its ownership journal"
        end
        @device_packages.each do |id|
          next unless device_package_present?(id)
          @context.command(
            [
              "xcrun",
              "devicectl",
              "--timeout",
              "30",
              "device",
              "uninstall",
              "app",
              "--device",
              @target.fetch("udid"),
              id
            ],
            timeout: 45
          )
          if device_package_present?(id)
            raise CleanupError, "Owned iOS fixture package remained installed: #{id}"
          end
        end
        return
      end
      inventory =
        @context.command(
          ["xcrun", "simctl", "listapps", @simulator],
          timeout: 120,
          binary: true,
          label: "Inspect owned simulator packages",
          log: File.join(@context.output, "simulator-packages.log")
        )
      installed =
        JSON.parse(
          @context.command(%w[plutil -convert json -o - -- -], input: inventory, timeout: 30)
        ).keys
      app = @bundle_id || "com.dbpprt.dieter.ios"
      [app, app + ".native-tests", app + ".uitests.xctrunner"].each do |id|
        next unless installed.include?(id)
        @context.command(
          ["xcrun", "simctl", "uninstall", @simulator, id],
          timeout: 120,
          label: "Reset owned simulator package #{id}"
        )
      end
    end

    def admit_device_packages
      app = @signing.fetch("app_bundle_id")
      @device_packages = [app, app + ".native-tests", app + ".uitests.xctrunner"]
      identity = { "udid" => @target.fetch("udid"), "packages" => @device_packages }
      @device_journal =
        File.join(
          @root,
          "tmp/e2e-cache/ios-device-#{Digest::SHA256.hexdigest(identity.fetch("udid"))}.json"
        )
      if File.file?(@device_journal)
        previous =
          JSON.parse(
            File.read(@device_journal),
            object_class: UniqueObject,
            allow_duplicate_key: false
          )
        unless previous.slice("udid", "packages") == identity
          raise Unavailable, "Physical iOS ownership changed; preserve the existing journal"
        end
        reset_owned_packages
      else
        existing = @device_packages.select { |id| device_package_present?(id) }
        unless existing.empty?
          raise Unavailable,
                "Physical iOS fixture apps already installed without ownership; preserve them: #{existing.join(", ")}"
        end
      end
      Atomic.json(@device_journal, identity.merge("owner_pid" => Process.pid))
      @context.cleanup do
        reset_owned_packages
        File.unlink(@device_journal)
      end
    end

    def device_package_present?(id)
      inventory = File.join(@context.private_dir, "device-apps.json")
      @context.command(
        [
          "xcrun",
          "devicectl",
          "--timeout",
          "30",
          "--json-output",
          inventory,
          "device",
          "info",
          "apps",
          "--device",
          @target.fetch("udid"),
          "--include-all-apps",
          "--bundle-id",
          id
        ],
        timeout: 45
      )
      result =
        JSON
          .parse(File.read(inventory), object_class: UniqueObject, allow_duplicate_key: false)
          .fetch("result")
          .fetch("apps")
      unless result.is_a?(Array) && result.length <= 1 &&
               result.all? { |app| app["bundleIdentifier"] == id }
        raise PipelineError, "Unexpected device application inventory"
      end
      !result.empty?
    end

    def private_test_run(state, environment, target)
      sdk = @target["kind"] == "device" ? "iphoneos" : "iphonesimulator"
      candidates = Dir.glob(File.join(@products, "*#{sdk}*.xctestrun"))
      raise PipelineError, "Expected one build-for-testing plan" unless candidates.length == 1
      original =
        @context.command(
          ["plutil", "-convert", "json", "-o", "-", candidates.first],
          timeout: 30,
          binary: true
        )
      input = File.join(state, "original.json")
      output = File.join(state, "DieterIOS.xctestrun")
      Atomic.write(input, original)
      @contract.call(
        "xctestrun",
        { path: input, output: output, products: @products, values: environment, target: target },
        json: false
      )
      @context.command(["plutil", "-convert", "xml1", output], timeout: 30)
      output
    end
  end
end
