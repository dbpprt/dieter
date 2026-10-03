# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/dieter/distribution/apple"
require_relative "../lib/dieter/errors"
require_relative "../lib/dieter/atomic"

class TemporaryAppleSigningTest < Minitest::Test
  class Context
    attr_reader :private_dir, :output, :secrets, :commands
    attr_accessor :fail_at, :notary_status
    def initialize(path)
      @private_dir, @output, @secrets, @commands = path, path, [], []
      @notary_status = "Accepted"
    end
    def lease(*) = nil
    def during_cleanup = yield
    def command(argv, **)
      @commands << argv
      raise Dieter::PipelineError, "synthetic failure" if fail_at && argv[1] == fail_at
      return %Q(    "/original/operator.keychain-db"\n) if argv[1] == "list-keychains" && !argv.include?("-s")
      return %Q{1) abc "Developer ID Application: Fixture (TEAM)"\n} if argv[1] == "find-identity"
      return JSON.generate({"id" => "submission", "status" => notary_status}) if argv[1] == "notarytool"
      ""
    end
  end

  def setup
    @root = Dir.mktmpdir("temporary-signing-")
    @context = Context.new(@root)
    @previous = ENV.to_h.slice("GITHUB_ACTIONS", "GITHUB_REF", "NOTARY_KEY_BASE64", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID")
    ENV["GITHUB_ACTIONS"], ENV["GITHUB_REF"] = "true", "refs/heads/main"
    ENV["NOTARY_KEY_BASE64"], ENV["NOTARY_KEY_ID"], ENV["NOTARY_ISSUER_ID"] = Base64.strict_encode64("private-key"), "key", "issuer"
    @signer = Dieter::AppleSigning.new(@context)
  end

  def teardown
    %w[GITHUB_ACTIONS GITHUB_REF NOTARY_KEY_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID].each { |name| @previous.key?(name) ? ENV[name] = @previous[name] : ENV.delete(name) }
    FileUtils.remove_entry_secure(@root)
  end

  def test_signing_uses_one_owned_identity_and_restores_the_operator_search_list
    @signer.keychain(certificate: "private.p12", password: "private-password") do |path, identity|
      assert path.start_with?(@root + "/signing-")
      assert_equal "Developer ID Application: Fixture (TEAM)", identity
    end
    restored = @context.commands.select { |argv| argv[1] == "list-keychains" && argv.include?("-s") }.last
    assert_equal ["security", "list-keychains", "-d", "user", "-s", "/original/operator.keychain-db"], restored
    assert_equal "delete-keychain", @context.commands.last[1]
  end

  def test_every_failed_setup_stage_restores_and_deletes_only_the_owned_keychain
    %w[unlock-keychain import set-key-partition-list find-identity].each do |step|
      @context.commands.clear
      @context.fail_at = step
      assert_raises(Dieter::PipelineError) { @signer.keychain(certificate: "private.p12", password: "private-password") { flunk "signing cannot start" } }
      assert_equal "delete-keychain", @context.commands.last[1]
      assert @context.commands.last[2].start_with?(@root + "/signing-")
      assert_equal "/original/operator.keychain-db", @context.commands[-2].last
    end
  end

  def test_signing_body_failure_also_restores_keychains
    assert_raises(Dieter::PipelineError) { @signer.keychain(certificate: "private.p12", password: "private-password") { raise Dieter::PipelineError, "codesign failure" } }
    assert_equal "delete-keychain", @context.commands.last[1]
  end

  def test_notary_rejection_never_staples_or_claims_gatekeeper_acceptance
    @context.notary_status = "Invalid"
    assert_raises(Dieter::PipelineError) { @signer.notarize("Dieter.pkg", staple: true, type: "install") }
    refute @context.commands.any? { |argv| argv.include?("stapler") || argv.first == "spctl" }
    @context.notary_status = "Accepted"
    @signer.notarize("Dieter.pkg", staple: true, type: "install")
    assert @context.commands.any? { |argv| argv[1..2] == ["stapler", "validate"] }
    assert_equal ["spctl", "--assess", "--type", "install", "--verbose=2", "Dieter.pkg"], @context.commands.last
  end

  def test_provisioning_files_restore_bytes_and_modes_after_archive_failure
    root = File.join(@root, "profiles")
    Dir.mkdir(root)
    first, second = %w[11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222]
    existing = File.join(root, first + ".mobileprovision")
    File.write(existing, "operator profile")
    File.chmod(0o640, existing)
    input = File.join(@root, "input.mobileprovision")
    File.write(input, "temporary release profile")
    assert_raises(Dieter::PipelineError) do
      @signer.with_profiles({first => input, second => input}, root: root) do
        assert_equal "temporary release profile", File.read(existing)
        raise Dieter::PipelineError, "archive failed"
      end
    end
    assert_equal "operator profile", File.read(existing)
    assert_equal 0o640, File.stat(existing).mode & 0o777
    refute File.exist?(File.join(root, second + ".mobileprovision"))
    linked = File.join(root, second + ".mobileprovision")
    File.symlink(existing, linked)
    assert_raises(Dieter::PipelineError) { @signer.with_profiles({second => input}, root: root) { flunk "symlink admitted" } }
    assert_equal "operator profile", File.read(existing)
  end
end
