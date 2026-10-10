# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rbconfig"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/pipeline/context"
require_relative "../lib/dieter/fixtures/screen"

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
      error =
        assert_raises(Dieter::Unavailable) do
          Dieter::ScreenFixture.tools(contender, contender.private_dir, input: true)
        end
      assert_includes error.message, "apple-build is busy"
    end
    assert_equal before, File.read(lease.path)
    assert_empty contender.instance_variable_get(:@processes)
  end

  def test_running_operator_app_prevents_capture_compilation
    tool(File.join(@bin, "pgrep"), "puts '74123'; exit 0\n")
    value = context
    on_mac do
      error =
        assert_raises(Dieter::Unavailable) do
          Dieter::ScreenFixture.tools(value, value.private_dir, input: true)
        end
      assert_includes error.message, "preserving the operator app"
    end
    assert_equal [%w[pgrep -x DieterMac]], value.instance_variable_get(:@processes).map(&:argv)
    assert_empty Dir.children(value.private_dir)
  end
end
