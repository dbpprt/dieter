# frozen_string_literal: true

require_relative "runtime"
require_relative "checks"

module Dieter
  module CI
    COMPONENTS = %w[portable report core core-apple android mac ios daemon gateway distribution].freeze

    def self.invoke(options)
      unknown = options.keys.map(&:to_s) - %w[action component fixture native output]
      raise PipelineError, "Unknown CI options: #{unknown.join(', ')}" unless unknown.empty?
      component = options.fetch(:component, "portable")
      raise PipelineError, "Unknown CI component #{component}" unless COMPONENTS.include?(component)
      context = RunContext.new(Config.new(Runtime::ROOT), output: options[:output])
      begin
        case options.fetch(:action, "check")
        when "setup" then setup(context, component, options.fetch(:fixture, "false"), options.fetch(:native, "false"))
        when "check" then check(context, component)
        when "result"
          raise PipelineError, "Required component check failed: #{ENV['PIPELINE_CHECK_RESULT']}" unless ENV["PIPELINE_CHECK_RESULT"] == "success"
        else raise PipelineError, "Unknown CI action"
        end
      ensure
        context.close
      end
    end

    def self.setup(context, component, fixture, native)
      raise PipelineError, "CI setup requires a disposable Actions runner" unless ENV["GITHUB_ACTIONS"] == "true"
      fixture = boolean_option(fixture, "fixture")
      native = boolean_option(native, "native")
      if RUBY_PLATFORM.include?("darwin")
        developer = ENV["RUNNER_ENVIRONMENT"] == "self-hosted" ? context.environment.fetch("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer") : "/Applications/Xcode_26.5.app/Contents/Developer"
        raise Unavailable, "Pinned Xcode 26.5 is unavailable on the runner" unless File.directory?(developer)
        append_env("DEVELOPER_DIR", developer)
        context.environment["DEVELOPER_DIR"] = developer
        if component == "ios"
          sdk = context.command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], timeout: 30).strip
          raise PipelineError, "Invalid pinned simulator SDK" unless sdk.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
          append_env("DIETER_CI_IOS_RUNTIME", "com.apple.CoreSimulator.SimRuntime.iOS-#{sdk.tr('.', '-')}")
          if native == "true" && ENV["RUNNER_ENVIRONMENT"] != "self-hosted"
            runtimes = JSON.parse(context.command(["xcrun", "simctl", "list", "runtimes", "-j"], timeout: 120, binary: true)).fetch("runtimes")
            unless runtimes.any? { |runtime| runtime["version"] == sdk && runtime["isAvailable"] }
              context.command(["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", sdk], timeout: 1800, log: File.join(context.output, "runtime-download.log"))
            end
          end
        end
        context.command(["swift", "fastlane/lib/dieter/native/mac_ci_desktop.swift"], timeout: 120) if component == "mac"
      elsif %w[portable daemon].include?(component) && ENV["RUNNER_ENVIRONMENT"] != "self-hosted"
        packages = %w[build-essential pkg-config ripgrep libglib2.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libjson-glib-dev libx11-dev libxtst-dev libxrandr-dev gstreamer1.0-tools gstreamer1.0-x gstreamer1.0-pipewire gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly xvfb x11-utils]
        context.command(%w[sudo apt-get update], timeout: 300)
        context.command(["sudo", "apt-get", "install", "-y", "--no-install-recommends", *packages], timeout: 600)
      end
      if component == "android" && !RUBY_PLATFORM.include?("darwin") && ENV["RUNNER_ENVIRONMENT"] != "self-hosted"
        context.command(["sdkmanager", "platforms;android-37.1", "build-tools;37.0.0"], timeout: 600)
      end
      if component == "distribution" || component == "gateway"
        %w[cosign oras].each { |tool| context.command(["python3", "deploy/gateway/scripts/install_tools.py", tool, "bin/#{tool}"], timeout: 300) }
        File.open(ENV.fetch("GITHUB_PATH"), "a") { |file| file.puts(File.join(context.root, "bin")) }
      end
      context.command(["npm", "--prefix", "internal/harness/runtime", "ci"], timeout: 300) if fixture == "true" || component == "portable"
    end

    # Fastlane's CLI parser turns literal true/false lane values into booleans;
    # direct composition callers can still supply their JSON/string values.
    def self.boolean_option(value, name)
      return value.to_s if value == true || value == false || %w[true false].include?(value)
      raise PipelineError, "#{name} must be true or false"
    end

    def self.check(context, component)
      context.environment["DIETER_RELEASE_VERSION"] = SourceIdentity.version(context)
      case component
      when "portable"
        Checks.perform(context, "portable", "justfile_check")
        Checks.perform(context, "portable", "workflow_check")
        context.command(["bash", "scripts/generate-proto.sh"], timeout: 600)
        # Integration packages each launch real subprocesses. Bound package
        # concurrency so host CPU count cannot exhaust their readiness budgets.
        context.command(["go", "test", "-race", "-p", "2", "./..."], timeout: 3600, log: File.join(context.output, "go-tests.log"))
        context.command(["go", "vet", "./..."], timeout: 1200, log: File.join(context.output, "go-vet.log"))
        context.command(["npm", "--prefix", "internal/harness/runtime", "test"], timeout: 1200, log: File.join(context.output, "harness-tests.log"))
        Checks.perform(context, "portable", "contracts")
        %w[daemon gateway].each { |name| adapter = Server.new(context, component: name); adapter.build({}); adapter.vulncheck }
        Checks.perform(context, "portable", "support_tests")
        Checks.markdown(context)
        LinuxCapture.new(context).test if RUBY_PLATFORM.include?("linux")
      when "core"
        Core.new(context).unit({})
      when "core-apple"
        Core.new(context).apple_test({})
      when "android"
        adapter = Android.new(context)
        adapter.unit({})
        adapter.build({})
        context.command([File.join(context.root, "apps/android/gradlew"), "--project-dir", "apps/android", "--console=plain", ":app:lintDebug"], timeout: 2400, log: File.join(context.output, "android-lint.log"))
        # Compile both E2E variants without pretending to execute an emulator.
        %w[e2e performance].each do |variant|
          context.command([File.join(context.root, "apps/android/gradlew"), "--project-dir", "apps/android", "--console=plain", "-Pdieter.testBuildType=#{variant}", ":app:assemble#{variant.capitalize}", ":app:assemble#{variant.capitalize}AndroidTest"], timeout: 2400, log: File.join(context.output, "#{variant}-build.log"))
        end
      when "ios"
        adapter = IOS.new(context)
        adapter.unit({})
        adapter.build({})
      when "mac"
        context.command(["bash", "apps/mac/scripts/format-swift.sh", "--check"], timeout: 300)
        context.command(["bash", "apps/mac/scripts/sync-proto.sh", "--check"], timeout: 300)
        adapter = Mac.new(context)
        adapter.unit({})
        adapter.build({})
        adapter.core_test
      when "daemon", "gateway"
        adapter = Server.new(context, component: component)
        adapter.unit({})
        adapter.vulncheck
      else raise PipelineError, "#{component} has no component check composition"
      end
    end

    def self.append_env(name, value)
      raise PipelineError, "Invalid generated environment" if value.match?(/[\r\n\0]/)
      File.open(ENV.fetch("GITHUB_ENV"), "a") { |file| file.puts("#{name}=#{value}") }
    end
  end
end
