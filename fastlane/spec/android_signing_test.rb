# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ostruct"
require "minitest/mock"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/platforms/android"

class AndroidLocalSigningTest < Minitest::Test
  class Adapter < Dieter::Android
    attr_reader :builds
    def gradle(tasks)
      (@builds ||= []) << [tasks, @context.environment.dup]
      configuration = tasks.first.delete_prefix(":app:assemble").downcase
      file =
        File.join(
          @root,
          "apps/android/app/build/outputs/apk",
          configuration,
          "app-#{configuration}.apk"
        )
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "built APK fixture")
    end
  end

  def setup
    @root = Dir.mktmpdir("android-signing-")
    FileUtils.mkdir_p(File.join(@root, "fastlane"))
    %w[config.json config.schema.json release-policy.json].each do |name|
      FileUtils.cp(File.expand_path("../#{name}", __dir__), File.join(@root, "fastlane", name))
    end
    File.write(File.join(@root, "fixture.jks"), "keystore fixture")
    override = {
      signing: {
        "android-release" => {
          keystore_file: "fixture.jks",
          keystore_password_env: "PIPELINE_SPEC_STORE_PASSWORD",
          key_alias_env: "PIPELINE_SPEC_KEY_ALIAS",
          key_password_env: "PIPELINE_SPEC_KEY_PASSWORD"
        }
      }
    }
    File.write(File.join(@root, "fastlane/local.json"), JSON.generate(override))
    @variables = %w[
      DIETER_ANDROID_KEYSTORE_PATH
      PIPELINE_SPEC_STORE_PASSWORD
      PIPELINE_SPEC_KEY_ALIAS
      PIPELINE_SPEC_KEY_PASSWORD
    ]
    @previous = @variables.to_h { |key| [key, ENV[key]] }
    ENV.delete("DIETER_ANDROID_KEYSTORE_PATH")
    @variables.drop(1).each { |key| ENV[key] = "fixture-#{key}" }
    config = Dieter::Config.new(@root, ci: false)
    @context =
      OpenStruct.new(
        root: @root,
        output: @root,
        private_dir: @root,
        config: config,
        environment: {
          "ANDROID_HOME" => @root
        },
        secrets: []
      )
    @context.define_singleton_method(:lease) { |*| nil }
    @context.define_singleton_method(:command) { |*, **| "a" * 40 }
    @adapter = Adapter.new(@context)
  end

  def teardown
    @previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.remove_entry_secure(@root)
  end

  def test_release_build_resolves_the_local_keystore_and_named_secret_references
    @adapter.build("configuration" => "release")
    environment = @adapter.builds.last.last
    assert_equal File.realpath(File.join(@root, "fixture.jks")),
                 environment.fetch("DIETER_ANDROID_KEYSTORE_PATH")
    assert_equal ENV.fetch("PIPELINE_SPEC_STORE_PASSWORD"),
                 environment.fetch("DIETER_ANDROID_KEYSTORE_PASSWORD")
    assert_equal ENV.fetch("PIPELINE_SPEC_KEY_ALIAS"), environment.fetch("DIETER_ANDROID_KEY_ALIAS")
    assert_equal ENV.fetch("PIPELINE_SPEC_KEY_PASSWORD"),
                 environment.fetch("DIETER_ANDROID_KEY_PASSWORD")
    assert_includes @context.secrets, ENV.fetch("PIPELINE_SPEC_STORE_PASSWORD")
    refute File.read(File.join(@root, "artifacts.json")).include?(
             ENV.fetch("PIPELINE_SPEC_STORE_PASSWORD")
           )
  end

  def test_missing_credentials_fail_before_release_build_but_debug_requires_none
    ENV.delete("PIPELINE_SPEC_KEY_PASSWORD")
    assert_raises(Dieter::Unavailable) { @adapter.build("configuration" => "release") }
    assert_nil @adapter.builds
    @adapter.build("configuration" => "debug")
    refute @adapter.builds.last.last.key?("DIETER_ANDROID_KEYSTORE_PASSWORD")
  end

  def test_candidate_material_is_preserved_without_reading_local_signing_references
    ENV.delete("PIPELINE_SPEC_KEY_PASSWORD")
    injected = {
      "DIETER_ANDROID_KEYSTORE_PATH" => File.realpath(File.join(@root, "fixture.jks")),
      "DIETER_ANDROID_KEYSTORE_PASSWORD" => "candidate-store",
      "DIETER_ANDROID_KEY_ALIAS" => "candidate-key",
      "DIETER_ANDROID_KEY_PASSWORD" => "candidate-password"
    }
    @context.environment.merge!(injected)
    @adapter.build("configuration" => "release")
    assert_equal injected, @adapter.builds.last.last.slice(*injected.keys)
  end
end

class AndroidJourneyTest < Minitest::Test
  APP = "com.dbpprt.dieter.e2e"
  E2E_APK = "apps/android/app/build/outputs/apk/e2e/app-e2e.apk"
  TEST_APK = "apps/android/app/build/outputs/apk/androidTest/e2e/app-e2e-androidTest.apk"

  class Context
    attr_reader :root, :output, :private_dir, :environment, :secrets, :commands, :leases, :inputs
    def initialize(root)
      @root, @output, @private_dir = root, File.join(root, "output"), File.join(root, "private")
      [@output, @private_dir].each { |path| FileUtils.mkdir_p(path) }
      @environment, @secrets, @commands, @leases, @inputs =
        { "ANDROID_HOME" => "/sdk" },
        [],
        [],
        [],
        {}
    end
    def lease(name, **) = leases << name
    def during_cleanup = yield
    def command(argv, input: nil, **)
      commands << argv
      inputs[argv] = input if input
      if argv.first.end_with?("gradlew")
        [E2E_APK, TEST_APK].each do |path|
          FileUtils.mkdir_p(File.dirname(File.join(root, path)))
          File.write(File.join(root, path), "#{path} bytes")
        end
        return ""
      end
      return "openjdk 21" if argv.last == "-version"
      unless argv.first(3) == %w[/sdk/platform-tools/adb -s emulator-5554]
        raise "Unexpected command: #{argv.inspect}"
      end
      arguments = argv.drop(3)
      return "Success" if arguments.first == "install"
      return "" unless arguments.first == "shell"
      shell = Shellwords.split(arguments.last)
      return "Success" if shell.first(2) == %w[pm clear]
      return "INSTRUMENTATION_CODE: -1" if shell.first(2) == %w[am instrument]
      ""
    end
    def shell_commands
      commands.select { |argv| argv[3] == "shell" }.map { |argv| Shellwords.split(argv.last) }
    end
  end

  def setup
    @root = Dir.mktmpdir("android-journey-")
    @context = Context.new(@root)
    @qualified = []
    contract = Object.new
    qualified = @qualified
    contract.define_singleton_method(:call) do |operation, request = {}, **|
      case operation
      when "qualify"
        qualified << request
        { "status" => "passed", "reason" => "" }
      when "android-digest"
        { "sha256" => "b" * 64 }
      else
        raise "Unexpected contract #{operation}"
      end
    end
    @adapter = Dieter::Contract.stub(:new, ->(*) { contract }) { Dieter::Android.new(@context) }
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def gradle =
    @context.commands.select { |argv| argv.first.end_with?("gradlew") }.map { |argv| argv.drop(4) }

  def test_unit_lints_the_debug_app
    @adapter.unit({})
    assert_equal ["android-build"], @context.leases
    assert_equal [%w[:app:lintDebug]], gradle
  end

  def test_preparation_builds_only_the_e2e_variant_and_reuses_unchanged_products
    java = File.join(@root, "jdk")
    FileUtils.mkdir_p(File.join(java, "bin"))
    File.write(File.join(java, "bin/java"), "")
    File.chmod(0o755, File.join(java, "bin/java"))
    @context.environment["JAVA_HOME"] = java
    compiled = []
    Dieter::GatewayFixture.stub(:compile, ->(context) { compiled << context }) do
      2.times { @adapter.prepare({}, []) }
    end
    assert_equal [%w[:app:assembleE2e :app:assembleE2eAndroidTest -Pdieter.testBuildType=e2e]],
                 gradle
    assert_equal [E2E_APK, TEST_APK].map { |path| File.join(@root, path) },
                 @adapter.instance_variable_get(:@products)
    assert_equal [@context, @context], compiled
  end

  def journey(fixture)
    @adapter.instance_variable_set(:@serial, "emulator-5554")
    @adapter.instance_variable_set(
      :@products,
      [E2E_APK, TEST_APK].map do |path|
        FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
        File.write(File.join(@root, path), "#{path} bytes")
        File.join(@root, path)
      end
    )
    test_case = {
      "id" => "android.journey",
      "fixture" => fixture,
      "native" => {
        "class" => "com.dbpprt.dieter.e2e.JourneyTest",
        "methods" => %w[journey]
      }
    }
    @adapter.execute_case({ "kind" => "emulator" }, test_case)
  end

  def instrumentation = @context.shell_commands.find { |argv| argv.first(2) == %w[am instrument] }

  def test_gateway_journey_runs_the_junit_runner_against_the_isolated_mobile_fixture
    fixtures = []
    factory =
      lambda do |context, suite, state, evidence:|
        fixture = Object.new
        record = { context: context, suite: suite, state: state, evidence: evidence, closed: false }
        fixture.define_singleton_method(:start) do
          {
            "DIETER_ISOLATED_ADDR" => "127.0.0.1:43123",
            "DIETER_ISOLATED_TOKEN" => "token-fixture"
          }
        end
        fixture.define_singleton_method(:close) { record[:closed] = true }
        fixtures << record
        fixture
      end
    result = Dieter::GatewayFixture.stub(:new, factory) { journey("gateway") }

    assert_equal "passed", result.fetch("status")
    assert_equal "", result.fetch("cleanupError")
    assert_equal 1, fixtures.length
    assert_equal "mobile", fixtures.first.fetch(:suite)
    assert fixtures.first.fetch(:closed)
    assert_equal [
                   "am",
                   "instrument",
                   "-w",
                   "-r",
                   "-e",
                   "class",
                   "com.dbpprt.dieter.e2e.JourneyTest#journey",
                   "-e",
                   "additionalTestOutputDir",
                   "/sdcard/Android/data/#{APP}/files",
                   "#{APP}.test/androidx.test.runner.AndroidJUnitRunner"
                 ],
                 instrumentation
    # The disposable session reaches the app's private files, never instrumentation argv.
    write =
      @context.commands.find do |argv|
        argv[3] == "shell" &&
          Shellwords.split(argv.last) == ["run-as", APP, "tee", "files/fixture.json"]
      end
    assert_equal(
      { "port" => "43123", "token" => "token-fixture" },
      JSON.parse(@context.inputs.fetch(write))
    )
    refute @context.commands.flatten.any? { |argument| argument.include?("token-fixture") }
    adb = @context.commands.map { |argv| argv.drop(3) }
    assert_includes adb, %w[reverse --no-rebind tcp:43123 tcp:43123]
    assert_includes adb, %w[reverse --remove tcp:43123]
    installs = adb.select { |argv| argv.first == "install" }.map(&:last)
    assert_equal [E2E_APK, TEST_APK].map { |path| File.join(@root, path) }, installs
    shells = @context.shell_commands
    assert_operator shells.index(["pm", "clear", APP]),
                    :<,
                    shells.index(["run-as", APP, "tee", "files/fixture.json"])
    assert_operator shells.index(["run-as", APP, "tee", "files/fixture.json"]),
                    :<,
                    shells.index(instrumentation)
    assert_includes shells, ["am", "force-stop", APP]
    assert_equal "android", @qualified.first.fetch(:platform)
    assert_equal "instrumentation.log", File.basename(@qualified.first.fetch(:path))
  end

  def test_fixture_free_journey_receives_no_gateway_route
    result =
      Dieter::GatewayFixture.stub(:new, ->(*) { flunk "fixture started without a gateway case" }) do
        journey("none")
      end
    assert_equal "passed", result.fetch("status")
    assert_equal [
                   "am",
                   "instrument",
                   "-w",
                   "-r",
                   "-e",
                   "class",
                   "com.dbpprt.dieter.e2e.JourneyTest#journey",
                   "-e",
                   "additionalTestOutputDir",
                   "/sdcard/Android/data/#{APP}/files",
                   "#{APP}.test/androidx.test.runner.AndroidJUnitRunner"
                 ],
                 instrumentation
    refute @context.commands.any? { |argv| argv[3] == "reverse" }
  end
end
