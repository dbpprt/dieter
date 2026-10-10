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
        return(
          Dir
            .glob(File.join(root, "apps/core/**/*"))
            .select { |path| File.file?(path) }
            .map { |path| path.delete_prefix(root + "/") }
            .sort
            .join("\0")
        )
      end
      return "pinned-toolchain" if argv.last == "-version"
      return "" if argv.first.end_with?("gradlew")
      if argv[0..1] == %w[xcodebuild -create-xcframework]
        path = argv.last
        Dir.mkdir(path)
        source = File.read(File.join(root, "apps/core/shared/src/commonMain/Domain.kt"))
        File.write(
          File.join(path, "slices"),
          argv.grep(/DieterShared.framework/).join("\n") + source
        )
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
    %w[commonMain commonTest].each do |name|
      FileUtils.mkdir_p(File.join(@root, "apps/core/shared/src", name))
    end
    File.write(File.join(@root, "apps/core/shared/src/commonMain/Domain.kt"), "domain-one")
    File.write(File.join(@root, "apps/core/shared/src/commonTest/DomainTest.kt"), "test-one")
    @context = Context.new(@root)
    @runner = Dieter::SharedFramework.new(@context)
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def publications =
    @context.commands.count { |argv| argv.first == "python3" && argv[2].include?("exchange(") }

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

  def gradle_tasks =
    @context.commands.select { |argv| argv.first.end_with?("gradlew") }.map { |argv| argv.drop(4) }

  def test_ios_slices_come_from_the_compose_module_as_a_separate_framework
    path = @runner.build(platforms: "ios-device")
    assert_equal File.join(@root, "apps/mac/Frameworks/DieterMobile.xcframework"), path
    assert_equal [%w[:mobile:linkDebugFrameworkIosArm64]], gradle_tasks
    # The Compose module still names its Kotlin framework module DieterShared.
    assert_includes File.read(File.join(path, "slices")),
                    File.join(
                      @root,
                      "apps/core/mobile/build/bin/iosArm64/debugFramework/DieterShared.framework"
                    )
    File.write(File.join(path, "slices"), "corrupted cache")
    @runner.build(platforms: "ios-simulator")
    assert_equal 2, publications
    assert_equal %w[:mobile:linkDebugFrameworkIosArm64 :mobile:linkDebugFrameworkIosSimulatorArm64],
                 gradle_tasks.last
    slices = File.read(File.join(path, "slices"))
    assert_includes slices, "mobile/build/bin/iosArm64"
    assert_includes slices, "mobile/build/bin/iosSimulatorArm64"

    mac = @runner.build(platforms: "macos")
    assert_equal File.join(@root, "apps/mac/Frameworks/DieterShared.xcframework"), mac
    assert_equal %w[:apple:linkDebugFrameworkMacosArm64], gradle_tasks.last
    assert_includes File.read(File.join(mac, "slices")), "apps/core/apple/build/bin/macosArm64"
    assert_equal 3, publications
    @runner.build(platforms: "ios-simulator")
    @runner.build(platforms: "macos")
    assert_equal 3, publications
    assert_equal slices, File.read(File.join(path, "slices"))

    @runner.build(configuration: "release", platforms: "ios-device")
    assert_equal 4, publications
    assert_equal %w[:mobile:linkReleaseFrameworkIosArm64], gradle_tasks.last
    refute_includes File.read(File.join(path, "slices")), "iosSimulatorArm64"
    assert_includes @context.leases, "apple-build"
    assert_includes @context.leases, "shared-framework"
  end

  def test_unknown_slice_sets_are_rejected_before_any_build
    %w[all ios macos-ios].each do |platforms|
      error = assert_raises(Dieter::PipelineError) { @runner.build(platforms: platforms) }
      assert_includes error.message, "Unknown framework slice set #{platforms}"
    end
    assert_empty @context.commands
    assert_empty @context.leases
  end
end
