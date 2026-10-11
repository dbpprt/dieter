# frozen_string_literal: true

require "securerandom"
require "shellwords"
require_relative "framework"
require_relative "apple_build"
require_relative "../pipeline/action"
require_relative "../pipeline/artifacts"
require_relative "../pipeline/inputs"

module Dieter
  # The iOS app: a UIKit shell (apps/ios) hosting the shared Compose UI.
  class IOS
    UUID = /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/
    PROJECT = "apps/ios/Dieter.xcodeproj"
    SCHEME = "Dieter"
    # Selects the iOS graph of apps/mac/Package.swift during package resolution.
    PACKAGE = { "DIETER_SWIFT_PACKAGE" => "ios" }.freeze
    # Maestro flows install a separate application, preserving the operator's app.
    E2E_BUNDLE_ID = "com.dbpprt.dieter.ios.e2e"

    def initialize(context, actions: nil)
      @context, @root, @actions = context, context.root, actions
      @derived = File.join(@root, "apps/ios/.build/DerivedData")
      @journal = File.join(@root, "tmp/e2e-cache/ios-simulator.json")
      @context.environment.merge!(PACKAGE)
    end

    # Builds only the simulator app; Maestro drives it from outside.
    def build(options)
      configuration = options.fetch("configuration", "debug")
      unless %w[debug release].include?(configuration)
        raise PipelineError, "configuration must be debug or release"
      end
      @context.lease("apple-build")
      SharedFramework.new(@context).build(configuration: configuration, platforms: "ios-simulator")
      xcargs = [
        *AppleBuild.jobs(@context, tool: :xcode),
        "-skipPackagePluginValidation",
        "ARCHS=arm64",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        "DIETER_RELEASE_VERSION=#{@context.environment.fetch("DIETER_RELEASE_VERSION")}",
        "DIETER_IOS_BUNDLE_ID=#{E2E_BUNDLE_ID}",
        "DIETER_IOS_APP_GROUP_ID=group.#{E2E_BUNDLE_ID}"
      ]
      NativeAction.run(
        @context,
        "build_app",
        {
          project: PROJECT,
          scheme: SCHEME,
          configuration: configuration.capitalize,
          destination: "generic/platform=iOS Simulator",
          derived_data_path: @derived,
          package_authorization_provider: "netrc",
          skip_archive: true,
          skip_package_ipa: true,
          skip_profile_detection: true,
          output_directory: @context.private_dir,
          buildlog_path: @context.private_dir,
          xcodebuild_formatter: "",
          xcargs: Shellwords.join(xcargs)
        },
        timeout: 2400,
        log: File.join(@context.output, "build.log")
      )
      app =
        File.join(@derived, "Build/Products/#{configuration.capitalize}-iphonesimulator/Dieter.app")
      raise PipelineError, "The simulator build produced no Dieter.app" unless File.directory?(app)
      ArtifactSet.new(
        component: "ios",
        source: @context.command(%w[git rev-parse HEAD], timeout: 30).strip,
        configuration: configuration,
        toolchain: {
          "input_sha256" => BuildInputs.digest(@context),
          "sdk" => "iphonesimulator",
          "xcode" => @context.command(%w[xcodebuild -version], timeout: 30)
        },
        products: {
          "app" => app
        }
      ).write(File.join(@context.output, "artifacts.json"))
      app
    end

    def admit(target)
      unless RUBY_PLATFORM.include?("darwin")
        raise Unavailable, "iOS simulators require macOS/Xcode"
      end
      unless target.fetch("kind") == "simulator"
        raise PipelineError, "Maestro flows run on iOS simulator profiles"
      end
      @context.lease("ios-simulator")
      @context.lease("apple-build")
      recover_simulator
      inventory = JSON.parse(@context.command(%w[xcrun simctl list -j], timeout: 120, binary: true))
      unless inventory
               .fetch("runtimes")
               .any? { |entry|
                 entry["identifier"] == target.fetch("runtime") && entry["isAvailable"]
               }
        raise Unavailable, "Configured iOS runtime is not installed: #{target.fetch("runtime")}"
      end
      unless inventory
               .fetch("devicetypes")
               .any? { |entry| entry["identifier"] == target.fetch("device_type") }
        raise Unavailable, "Configured simulator type is not installed"
      end
      @target = target
    end

    # Creates the run's own simulator and starts booting it, so the boot
    # overlaps the build. Call ready before installing.
    def create_simulator
      name = "Dieter Pipeline #{SecureRandom.uuid}"
      @simulator =
        @context.command(
          [
            "xcrun",
            "simctl",
            "create",
            name,
            @target.fetch("device_type"),
            @target.fetch("runtime")
          ],
          timeout: 30,
          binary: true
        ).strip
      raise PipelineError, "Invalid owned simulator identity" unless UUID.match?(@simulator)
      Atomic.json(@journal, { "ID" => @simulator, "Name" => name })
      simulator, journal = @simulator, @journal
      @context.cleanup do
        delete_simulator(simulator)
        File.unlink(journal) if File.file?(journal)
      end
      # Hosted runners take up to about 140s to boot and the first spawn waits up to
      # about 100s more for the system apps.
      @boot =
        @context.start(
          ["xcrun", "simctl", "bootstatus", @simulator, "-b"],
          log: File.join(@context.output, "boot.log")
        )
      @simulator
    end

    def ready
      @context.wait(@boot, timeout: 300, label: "Boot simulator")
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
      @simulator
    end

    def install(app)
      @context.command(
        ["xcrun", "simctl", "install", @simulator, app],
        timeout: 300,
        label: "Install app"
      )
    end

    private

    def recover_simulator
      return unless File.file?(@journal)
      owner = JSON.parse(File.read(@journal))
      unless UUID.match?(owner.fetch("ID")) && owner.fetch("Name").start_with?("Dieter Pipeline ")
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
      File.unlink(@journal)
    end

    def delete_simulator(id)
      # Shutting down a booted simulator takes over 30s on hosted runners.
      @context.command(["xcrun", "simctl", "shutdown", id], timeout: 120, check: false)
      @context.command(["xcrun", "simctl", "delete", id], timeout: 120)
    end
  end
end
