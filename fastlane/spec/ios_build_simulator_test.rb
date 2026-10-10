# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "minitest/mock"
require_relative "../lib/dieter/platforms/ios"

class IOSBuildSimulatorTest < Minitest::Test
  OWNED = "11111111-2222-3333-4444-555555555555"
  RUNTIMES = [
    {
      "platform" => "iOS",
      "isAvailable" => true,
      "version" => "26.5",
      "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
      "supportedDeviceTypes" => [{ "productFamily" => "iPhone", "identifier" => "iPhone-17-Pro" }]
    },
    {
      "platform" => "iOS",
      "isAvailable" => true,
      "version" => "27.0",
      "identifier" => "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "supportedDeviceTypes" => [
        { "productFamily" => "iPad", "identifier" => "iPad-Pro" },
        { "productFamily" => "iPhone", "identifier" => "iPhone-18-Pro" }
      ]
    },
    {
      "platform" => "watchOS",
      "isAvailable" => true,
      "version" => "30.0",
      "identifier" => "com.apple.CoreSimulator.SimRuntime.watchOS-30-0",
      "supportedDeviceTypes" => [{ "productFamily" => "Apple Watch", "identifier" => "Watch" }]
    }
  ].freeze

  def adapter(root, devices)
    commands = []
    context = Struct.new(:root, :output, :private_dir, :environment).new(root, root, root, {})
    context.define_singleton_method(:command) do |argv, **|
      commands << argv
      case argv[0..3]
      when %w[xcrun simctl list -j]
        JSON.generate({ "devices" => devices, "runtimes" => RUNTIMES })
      when %w[xcrun simctl list devices]
        JSON.generate({ "devices" => devices })
      else
        raise "Unexpected command: #{argv.inspect}" unless argv[0..1] == %w[xcrun simctl]
        argv[2] == "create" ? "#{OWNED}\n" : ""
      end
    end
    [Dieter::IOS.new(context), commands]
  end

  def test_without_an_ios_simulator_the_build_owns_one_for_its_duration
    Dir.mktmpdir do |root|
      ios, commands =
        adapter(
          root,
          {
            "com.apple.CoreSimulator.SimRuntime.watchOS-30-0" => [
              { "udid" => "w", "isAvailable" => true }
            ]
          }
        )
      journal = File.join(root, "tmp/e2e-cache/ios-build-simulator.json")
      ios.send(:with_detectable_simulator) do
        owner = JSON.parse(File.read(journal))
        assert_equal OWNED, owner.fetch("ID")
        assert_match(/\ADieter Pipeline build /, owner.fetch("Name"))
      end
      create = commands.find { |argv| argv[2] == "create" }
      assert_equal %w[iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0], create[4..]
      assert_equal [%w[xcrun simctl shutdown] + [OWNED], %w[xcrun simctl delete] + [OWNED]],
                   commands.last(2)
      refute File.exist?(journal)
    end
  end

  def test_a_failed_build_still_deletes_its_simulator
    Dir.mktmpdir do |root|
      ios, commands = adapter(root, {})
      assert_raises(Dieter::PipelineError) do
        ios.send(:with_detectable_simulator) { raise Dieter::PipelineError, "build failed" }
      end
      assert_equal %w[xcrun simctl delete] + [OWNED], commands.last
      refute File.exist?(File.join(root, "tmp/e2e-cache/ios-build-simulator.json"))
    end
  end

  def test_existing_simulators_are_only_read
    Dir.mktmpdir do |root|
      ios, commands =
        adapter(
          root,
          {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" => [
              { "udid" => "operator", "isAvailable" => true }
            ]
          }
        )
      built = false
      ios.send(:with_detectable_simulator) { built = true }
      assert built
      assert_equal [%w[xcrun simctl list -j]], commands
    end
  end

  def test_a_simulator_left_by_a_crashed_build_is_recovered_first
    Dir.mktmpdir do |root|
      name = "Dieter Pipeline build leftover"
      ios, commands =
        adapter(
          root,
          {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" => [
              { "udid" => OWNED, "name" => name, "isAvailable" => true }
            ]
          }
        )
      journal = File.join(root, "tmp/e2e-cache/ios-build-simulator.json")
      Dieter::Atomic.json(journal, { "ID" => OWNED, "Name" => name })
      ios.send(:with_detectable_simulator) {}
      assert_equal [
                     %w[xcrun simctl list devices -j],
                     %w[xcrun simctl shutdown] + [OWNED],
                     %w[xcrun simctl delete] + [OWNED]
                   ],
                   commands.first(3)
      refute File.exist?(journal)
    end
  end

  def test_simulator_build_compiles_the_compose_app_with_the_ios_package_graph
    Dir.mktmpdir do |root|
      commands, leases, seen = [], [], {}
      context =
        Struct.new(:root, :output, :private_dir, :environment).new(
          root,
          root,
          root,
          { "DIETER_RELEASE_VERSION" => "0.4.413" }
        )
      context.define_singleton_method(:lease) { |name| leases << name }
      context.define_singleton_method(:command) do |argv, **|
        commands << argv
        case argv[0..1]
        when %w[xcrun simctl]
          JSON.generate(
            {
              "devices" => {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5" => [
                  { "udid" => "operator", "isAvailable" => true }
                ]
              },
              "runtimes" => RUNTIMES
            }
          )
        when %w[git rev-parse]
          "a" * 40
        when %w[git ls-files]
          ""
        when %w[xcodebuild -version]
          "Xcode 26.5"
        else
          raise "Unexpected command: #{argv.inspect}"
        end
      end
      framework = Object.new
      framework.define_singleton_method(:build) { |**options| seen[:framework] = options }
      products = File.join(root, "apps/ios/.build/DerivedData/Build/Products")
      action =
        lambda do |action_context, name, options, timeout:, log:|
          seen[:action] = [name, options, action_context.environment.dup]
          FileUtils.mkdir_p(products)
          File.write(File.join(products, "Dieter_iphonesimulator26.5-arm64.xctestrun"), "plan")
        end
      ios = Dieter::IOS.new(context)
      plan =
        Dieter::SharedFramework.stub(:new, ->(_context) { framework }) do
          Dieter::NativeAction.stub(:run, action) { ios.build({}) }
        end

      assert_equal File.join(products, "Dieter_iphonesimulator26.5-arm64.xctestrun"), plan
      assert_includes leases, "apple-build"
      assert_equal({ configuration: "debug", platforms: "ios-simulator" }, seen[:framework])
      name, options, environment = seen.fetch(:action)
      assert_equal "run_tests", name
      assert_equal "apps/ios/Dieter.xcodeproj", options.fetch(:project)
      assert_equal "Dieter", options.fetch(:scheme)
      assert_equal "generic/platform=iOS Simulator", options.fetch(:destination)
      assert options.fetch(:build_for_testing)
      assert_equal "ios", environment.fetch("DIETER_SWIFT_PACKAGE")
      settings = Shellwords.split(options.fetch(:xcargs))
      assert_includes settings, "CODE_SIGN_IDENTITY=-"
      assert_includes settings, "DIETER_IOS_BUNDLE_ID=com.dbpprt.dieter.ios.e2e"
      assert_includes settings, "DIETER_RELEASE_VERSION=0.4.413"
      # The simulator app and Share extension share an E2E-only app group.
      assert_includes settings, "DIETER_IOS_APP_GROUP_ID=group.com.dbpprt.dieter.ios.e2e"
      refute settings.any? { |value| value.include?("SHARE_PROFILE") }
      manifest = JSON.parse(File.read(File.join(root, "artifacts.json")))
      assert_equal "ios", manifest.fetch("component")
      assert_equal "iphonesimulator", manifest.fetch("toolchain").fetch("sdk")
    end
  end
end
