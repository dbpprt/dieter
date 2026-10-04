# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/platforms/framework"
require_relative "../lib/dieter/errors"
require_relative "../lib/dieter/atomic"

class SharedFrameworkCacheTest < Minitest::Test
  class Context
    attr_reader :root, :output, :environment, :commands, :leases
    def initialize(root)
      @root, @output, @environment, @commands, @leases = root, root, {}, [], []
    end
    def lease(name) = leases << name
    def command(argv, **)
      commands << argv
      if argv[0..1] == %w[git ls-files]
        return Dir.glob(File.join(root, "apps/core/**/*" )).select { |path| File.file?(path) }.map { |path| path.delete_prefix(root + "/") }.sort.join("\0")
      end
      return "pinned-toolchain" if argv.last == "-version"
      return "" if argv.first.end_with?("gradlew")
      if argv[0..1] == %w[xcodebuild -create-xcframework]
        path = argv.last
        Dir.mkdir(path)
        source = File.read(File.join(root, "apps/core/shared/src/commonMain/Domain.kt"))
        File.write(File.join(path, "slices"), argv.grep(/DieterShared.framework/).join("\n") + source)
        return ""
      end
      if argv.first == "python3" && argv[2].include?("exchange(")
        FileUtils.rm_rf(argv.last)
        FileUtils.mv(argv[-2], argv.last)
        return ""
      end
      raise "Unexpected framework command: #{argv.inspect}"
    end
    def start(argv, **)
      commands << argv
      same = Dieter::ArtifactSet.sha256(argv[-2]) == Dieter::ArtifactSet.sha256(argv[-1])
      process = Object.new
      process.define_singleton_method(:wait) { |**| "" }
      status = Object.new
      status.define_singleton_method(:success?) { same }
      process.define_singleton_method(:status) { status }
      process
    end
  end

  def setup
    @root = Dir.mktmpdir("framework-cache-")
    %w[commonMain commonTest].each { |name| FileUtils.mkdir_p(File.join(@root, "apps/core/shared/src", name)) }
    File.write(File.join(@root, "apps/core/shared/src/commonMain/Domain.kt"), "domain-one")
    File.write(File.join(@root, "apps/core/shared/src/commonTest/DomainTest.kt"), "test-one")
    @context = Context.new(@root)
    @runner = Dieter::SharedFramework.new(@context)
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def publications = @context.commands.count { |argv| argv.first == "python3" && argv[2].include?("exchange(") }

  def test_documentation_and_test_changes_do_not_replace_framework_but_production_changes_do
    path = @runner.build
    timestamp = File.mtime(path)
    assert_equal 1, publications
    File.write(File.join(@root, "apps/core/shared/src/commonTest/DomainTest.kt"), "test-two")
    File.write(File.join(@root, "apps/core/README.md"), "updated docs")
    assert_equal path, @runner.build
    assert_equal 1, publications
    assert_equal timestamp, File.mtime(path)
    File.write(File.join(@root, "apps/core/shared/src/commonMain/Domain.kt"), "domain-two")
    @runner.build
    assert_equal 2, publications
  end

  def test_simulator_refresh_retains_mac_and_device_slices_and_damaged_bytes_are_rebuilt
    path = @runner.build(platforms: "all")
    File.write(File.join(path, "slices"), "corrupted cache")
    @runner.build(platforms: "ios-simulator")
    assert_equal 2, publications
    assert_includes File.read(File.join(path, "slices")), "iosArm64"
    @runner.build(platforms: "macos")
    assert_equal 2, publications
    @runner.build(configuration: "release", platforms: "macos")
    assert_equal 3, publications
    refute_includes File.read(File.join(path, "slices")), "iosArm64"
    assert_includes @context.leases, "apple-build"
    assert_includes @context.leases, "shared-framework"
  end
end
