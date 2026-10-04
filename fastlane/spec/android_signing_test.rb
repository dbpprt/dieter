# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ostruct"
require_relative "../lib/dieter/config"
require_relative "../lib/dieter/platforms/android"

class AndroidLocalSigningTest < Minitest::Test
  class Adapter < Dieter::Android
    attr_reader :builds
    def gradle(tasks)
      (@builds ||= []) << [tasks, @context.environment.dup]
      configuration = tasks.first.delete_prefix(":app:assemble").downcase
      file = File.join(@root, "apps/android/app/build/outputs/apk", configuration, "app-#{configuration}.apk")
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
    override = {signing: {"android-release" => {keystore_file: "fixture.jks", keystore_password_env: "PIPELINE_SPEC_STORE_PASSWORD", key_alias_env: "PIPELINE_SPEC_KEY_ALIAS", key_password_env: "PIPELINE_SPEC_KEY_PASSWORD"}}}
    File.write(File.join(@root, "fastlane/local.json"), JSON.generate(override))
    @variables = %w[DIETER_ANDROID_KEYSTORE_PATH PIPELINE_SPEC_STORE_PASSWORD PIPELINE_SPEC_KEY_ALIAS PIPELINE_SPEC_KEY_PASSWORD]
    @previous = @variables.to_h { |key| [key, ENV[key]] }
    ENV.delete("DIETER_ANDROID_KEYSTORE_PATH")
    @variables.drop(1).each { |key| ENV[key] = "fixture-#{key}" }
    config = Dieter::Config.new(@root, ci: false)
    @context = OpenStruct.new(root: @root, output: @root, private_dir: @root, config: config, environment: {"ANDROID_HOME" => @root}, secrets: [])
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
    assert_equal File.realpath(File.join(@root, "fixture.jks")), environment.fetch("DIETER_ANDROID_KEYSTORE_PATH")
    assert_equal ENV.fetch("PIPELINE_SPEC_STORE_PASSWORD"), environment.fetch("DIETER_ANDROID_KEYSTORE_PASSWORD")
    assert_equal ENV.fetch("PIPELINE_SPEC_KEY_ALIAS"), environment.fetch("DIETER_ANDROID_KEY_ALIAS")
    assert_equal ENV.fetch("PIPELINE_SPEC_KEY_PASSWORD"), environment.fetch("DIETER_ANDROID_KEY_PASSWORD")
    assert_includes @context.secrets, ENV.fetch("PIPELINE_SPEC_STORE_PASSWORD")
    refute File.read(File.join(@root, "artifacts.json")).include?(ENV.fetch("PIPELINE_SPEC_STORE_PASSWORD"))
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
    injected = {"DIETER_ANDROID_KEYSTORE_PATH" => File.realpath(File.join(@root, "fixture.jks")), "DIETER_ANDROID_KEYSTORE_PASSWORD" => "candidate-store", "DIETER_ANDROID_KEY_ALIAS" => "candidate-key", "DIETER_ANDROID_KEY_PASSWORD" => "candidate-password"}
    @context.environment.merge!(injected)
    @adapter.build("configuration" => "release")
    assert_equal injected, @adapter.builds.last.last.slice(*injected.keys)
  end
end
