# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/pipeline/context"
require_relative "../lib/dieter/platforms/android"

class ScreenFixtureAdmissionTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("screen-admission-")
    FileUtils.mkdir_p(File.join(@root, "fastlane"))
    %w[config.json config.schema.json release-policy.json].each do |name|
      FileUtils.cp(File.expand_path("../#{name}", __dir__), File.join(@root, "fastlane", name))
    end
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p(@bin)
    @contexts = []
  end

  def teardown
    @contexts.reverse_each(&:close)
    FileUtils.remove_entry_secure(@root)
  end

  def context
    value = Dieter::RunContext.new(Dieter::Config.new(@root, ci: true))
    # Keep real file locking, but give the fake desktop its own identity.
    value.define_singleton_method(:lease) do |resource, **options|
      super(resource == "mac-desktop" ? "spec-screen-desktop" : resource, **options)
    end
    value.environment["PATH"] = @bin + File::PATH_SEPARATOR + ENV.fetch("PATH")
    @contexts << value
    value
  end

  def tool(path, body)
    File.write(path, "#!#{RbConfig.ruby}\n" + body)
    File.chmod(0o755, path)
  end

  def on_mac(&block) = Dieter::ScreenFixture.stub(:supported_host?, true, &block)

  def test_build_conflict_prevents_any_capture_or_desktop_tool
    owner = context
    lease = owner.lease("apple-build")
    before = File.read(lease.path)
    contender = context
    on_mac do
      error = assert_raises(Dieter::Unavailable) { Dieter::ScreenFixture.tools(contender, contender.private_dir, input: true) }
      assert_includes error.message, "apple-build is busy"
    end
    assert_equal before, File.read(lease.path)
    assert_empty contender.instance_variable_get(:@processes)
  end

  def test_running_operator_app_prevents_capture_compilation
    tool(File.join(@bin, "pgrep"), "puts '74123'; exit 0\n")
    value = context
    on_mac do
      error = assert_raises(Dieter::Unavailable) { Dieter::ScreenFixture.tools(value, value.private_dir, input: true) }
      assert_includes error.message, "preserving the operator app"
    end
    assert_equal [["pgrep", "-x", "DieterMac"]], value.instance_variable_get(:@processes).map(&:argv)
    assert_empty Dir.children(value.private_dir)
  end

  def test_android_screen_admission_holds_the_same_desktop_lease
    tool(File.join(@bin, "pgrep"), "exit 1\n")
    sdk = File.join(@root, "sdk")
    FileUtils.mkdir_p(File.join(sdk, "platform-tools"))
    tool(File.join(sdk, "platform-tools/adb"), <<~RUBY)
      require 'shellwords'
      arguments = ARGV.drop(2)
      arguments = ['shell', *Shellwords.split(arguments.last)] if arguments.first == 'shell' && arguments.length == 2
      case arguments
      when ['get-state'] then puts 'device'
      when ['shell', 'getprop', 'sys.boot_completed'] then puts '1'
      when ['shell', 'getprop', 'init.svc.bootanim'] then puts 'stopped'
      when ['shell', 'pidof', 'com.dbpprt.dieter.e2e'] then exit 1
      else abort "Unexpected mutation during admission: #{'#{ARGV.inspect}'}"
      end
    RUBY
    value = context
    value.environment["ANDROID_HOME"] = sdk
    target = {"kind" => "device", "serial" => File.basename(@root)}
    on_mac { Dieter::Android.new(value).admit(target, [{"fixture" => "screen"}]) }
    assert_equal ["pgrep", "-x", "DieterMac"], value.instance_variable_get(:@processes).last.argv
    contender = context
    error = assert_raises(Dieter::Unavailable) { contender.lease("mac-desktop") }
    assert_includes error.message, "spec-screen-desktop is busy"
  end
end
