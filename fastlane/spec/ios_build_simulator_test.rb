# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
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
end
