# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "set"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/platforms/ios"

class IOSPhysicalOwnershipTest < Minitest::Test
  class Context
    attr_reader :root, :private_dir, :commands, :cleanups, :installed, :environment
    attr_accessor :fail_uninstall
    def initialize(root)
      @root, @private_dir, @commands, @cleanups, @installed = root, root, [], [], Set.new
      @environment = {}
    end
    def cleanup(&block) = cleanups << block
    def command(argv, **)
      commands << argv
      if argv.include?("--bundle-id")
        id = argv.last
        output = argv[argv.index("--json-output") + 1]
        Dieter::Atomic.json(
          output,
          { result: { apps: installed.include?(id) ? [{ bundleIdentifier: id }] : [] } }
        )
      elsif argv.include?("uninstall")
        raise Dieter::CleanupError, "device disconnected" if fail_uninstall
        installed.delete(argv.last)
      else
        raise "Unexpected device command: #{argv.inspect}"
      end
      ""
    end
  end

  def setup
    @root = Dir.mktmpdir("ios-device-ownership-")
    @context = Context.new(@root)
    @app = "com.example.dieter.e2e"
    @runner = Dieter::IOS.new(@context)
    @runner.instance_variable_set(:@target, { "kind" => "device", "udid" => "exact-device" })
    @runner.instance_variable_set(:@signing, { "app_bundle_id" => @app })
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def test_adapter_selects_the_ios_swift_package_graph
    assert_equal({ "DIETER_SWIFT_PACKAGE" => "ios" }, @context.environment)
  end

  def test_journal_owns_exactly_the_app_and_its_ui_test_runner
    @runner.send(:admit_device_packages)
    journal = JSON.parse(File.read(@runner.instance_variable_get(:@device_journal)))
    assert_equal "exact-device", journal.fetch("udid")
    assert_equal [@app, "#{@app}.uitests.xctrunner"], journal.fetch("packages")
    probed = @context.commands.select { |argv| argv.include?("--bundle-id") }.map(&:last)
    assert_equal journal.fetch("packages"), probed
  end

  def test_unowned_installed_fixture_app_is_preserved
    @context.installed << @app
    assert_raises(Dieter::Unavailable) { @runner.send(:admit_device_packages) }
    refute @context.commands.any? { |argv| argv.include?("uninstall") }
    assert_includes @context.installed, @app
  end

  def test_owned_cleanup_never_uninstalls_operator_app_and_removes_journal_after_confirmation
    @context.installed << "com.example.dieter"
    @runner.send(:admit_device_packages)
    journal = @runner.instance_variable_get(:@device_journal)
    assert File.file?(journal)
    @context.installed << @app
    @context.cleanups.each(&:call)
    refute File.exist?(journal)
    assert_equal Set["com.example.dieter"], @context.installed
    assert_equal [@app], @context.commands.select { |argv| argv.include?("uninstall") }.map(&:last)
  end

  def test_failed_cleanup_retains_journal_and_changed_bundle_identity_cannot_be_recovered
    @runner.send(:admit_device_packages)
    @context.installed << @app
    @context.fail_uninstall = true
    assert_raises(Dieter::CleanupError) { @context.cleanups.each(&:call) }
    journal = @runner.instance_variable_get(:@device_journal)
    assert File.file?(journal)
    @context.fail_uninstall = false
    @runner.instance_variable_set(:@signing, { "app_bundle_id" => "com.another.e2e" })
    assert_raises(Dieter::Unavailable) { @runner.send(:admit_device_packages) }
    assert_includes @context.installed, @app
  end
end

class IOSSimulatorOwnershipTest < Minitest::Test
  def test_simulator_inventory_resets_only_fixture_apps_and_rejects_invalid_inventory
    Dir.mktmpdir("ios-simulator-ownership-") do |root|
      commands = []
      inventory = {
        "com.apple.Preferences" => {
        },
        "com.dbpprt.dieter.ios.e2e" => {
        },
        "com.dbpprt.dieter.ios.e2e.uitests.xctrunner" => {
        },
        "com.getdieter.ios" => {
        },
        "com.example.operator" => {
        }
      }
      environment = {}
      context = Object.new
      context.define_singleton_method(:root) { root }
      context.define_singleton_method(:environment) { environment }
      context.define_singleton_method(:output) { root }
      context.define_singleton_method(:private_dir) { root }
      context.define_singleton_method(:command) do |argv, **options|
        commands << argv
        if argv.include?("listapps")
          "simulator inventory"
        elsif argv.first == "plutil"
          raise Dieter::PipelineError, "Invalid simulator inventory" unless inventory
          raise "Inventory input lost" unless options[:input] == "simulator inventory"
          JSON.generate(inventory)
        elsif argv.include?("uninstall")
          inventory.delete(argv.last)
        else
          raise "Unexpected command #{argv.inspect}"
        end
      end
      adapter = Dieter::IOS.new(context)
      adapter.instance_variable_set(:@target, { "kind" => "simulator" })
      adapter.instance_variable_set(:@simulator, "owned-simulator")
      adapter.send(:reset_owned_packages)
      # Only the E2E fixture app and its runner; the release app is the operator's.
      assert_equal %w[com.dbpprt.dieter.ios.e2e com.dbpprt.dieter.ios.e2e.uitests.xctrunner],
                   commands.select { |argv| argv.include?("uninstall") }.map(&:last)
      assert_equal %w[com.apple.Preferences com.example.operator com.getdieter.ios],
                   inventory.keys.sort
      inventory = nil
      commands.clear
      assert_raises(Dieter::PipelineError) { adapter.send(:reset_owned_packages) }
      refute commands.any? { |argv| argv.include?("uninstall") }
    end
  end
end
