# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "ostruct"
require_relative "../lib/dieter/distribution/testflight"

class TestFlightRecoveryTest < Minitest::Test
  class Context
    attr_reader :secrets, :output, :commands, :config
    def initialize(root)
      @secrets, @output, @commands = [], root, []
      @config =
        Struct.new(:policy).new(
          JSON.parse(File.read(File.expand_path("../release-policy.json", __dir__)))
        )
    end
    def command(argv, **options)
      @commands << [argv, options]
      ""
    end
  end

  class Group
    attr_reader :id, :name, :members
    def initialize(name, internal: true)
      @id, @name, @internal, @members = "group-#{name}", name, internal, []
    end
    def is_internal_group = @internal
    def fetch_builds = members
  end

  class Build < Spaceship::ConnectAPI::Build
    attr_accessor :fail_group
    attr_reader :additions
    def initialize
      super("exact-build", { "processingState" => "VALID", "expired" => false })
      @additions = []
      self.build_beta_detail =
        Spaceship::ConnectAPI::BuildBetaDetail.new(
          "beta-detail",
          { "internalBuildState" => "READY_FOR_BETA_TESTING" }
        )
    end
    def add_beta_groups(client:, beta_groups:)
      raise Dieter::PipelineError, "group transport failed" if @fail_group
      beta_groups.each do |group|
        group.members << self
        additions << group.name
      end
      build_beta_detail.internal_build_state = "IN_BETA_TESTING"
    end
  end

  class Destination
    attr_accessor :draft, :previous
    attr_reader :records, :downloads
    def initialize(path)
      @path, @records, @downloads, @previous, @draft = path, [], [], [], false
    end
    def with_claim(*) = yield
    def release(*) = { "draft" => draft, "prerelease" => true }
    def receipts(*) = previous + records
    def receipt(_identity, _destination, value) = records << value
    def download(_identity, name, output)
      downloads << name
      FileUtils.cp(@path, output)
      output
    end
  end

  def setup
    @root = Dir.mktmpdir("testflight-recovery-")
    @context = Context.new(@root)
    @ipa = File.join(@root, "input.ipa")
    File.write(@ipa, "exact retained bytes")
    @hash = Dieter::ArtifactSet.sha256(@ipa)
    @identity =
      OpenStruct.new(version: "0.4.413", build: "413", apple_build: "1.4.12", tag: "v0.4.413")
    @github = Destination.new(@ipa)
    @group = Group.new("Developers")
    @groups, @builds, @uploads, @queries = [@group], [], [], []
    @policy = { "testflight" => true, "testflight_groups" => ["Developers"] }
    @coordinator = Object.new
    policy, hash, ios = @policy, @hash, @context.config.policy.fetch("ios")
    @coordinator.define_singleton_method(:verify_retained) do
      [
        { "policy" => { "channels" => { "dev" => policy }, "ios" => ios } },
        { "Dieter-iOS.ipa" => hash }
      ]
    end
    @app = OpenStruct.new(id: "app-1", bundle_id: ios.fetch("bundle_id"))
    groups = @groups
    @app.define_singleton_method(:get_beta_groups) { |**| groups }
    @app_model = Object.new
    app = @app
    @app_model.define_singleton_method(:find) { |*, **| app }
    @build_model = Object.new
    builds, queries = @builds, @queries
    @build_model.define_singleton_method(:all) do |**options|
      queries << options
      builds.dup
    end
    @actions = Object.new
    uploads = @uploads
    @actions.define_singleton_method(:upload_to_testflight) do |**options|
      uploads << options
      builds << Build.new
    end
    @store = OpenStruct.new
    @old_env = {}
    {
      "IOS_APP_STORE_CONNECT_KEY_BASE64" => Base64.strict_encode64("private-key"),
      "IOS_APP_STORE_CONNECT_KEY_ID" => "KEY",
      "IOS_APP_STORE_CONNECT_ISSUER_ID" => "ISSUER",
      "IOS_BUNDLE_ID" => @app.bundle_id
    }.each do |name, value|
      @old_env[name] = ENV[name]
      ENV[name] = value
    end
  end

  def teardown
    @old_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    FileUtils.remove_entry_secure(@root)
  end

  def runner
    Dieter::TestFlightDestination.new(
      @context,
      @identity,
      actions: @actions,
      store: @store,
      github: @github,
      coordinator: @coordinator,
      app_model: @app_model,
      build_model: @build_model,
      token_factory: ->(**) { "authentication-fixture" }
    )
  end

  def test_uploads_exact_ipa_then_confirms_processing_and_group_membership
    runner.deliver
    assert_equal 1, @uploads.length
    assert_equal @hash, Dieter::ArtifactSet.sha256(@uploads.first.fetch(:ipa))
    assert @uploads.first.fetch(:skip_submission)
    refute @uploads.first.fetch(:distribute_external)
    assert_equal %w[uploading accepted processing group-delivered completed],
                 @github.records.map { |value| value.fetch("state") }
    assert_equal ["exact-build"], @group.members.map(&:id)
    assert_equal "1.4.12", @queries.first.fetch(:build_number)
    assert_equal "0.4.413", @queries.first.fetch(:version)
  end

  def test_previous_account_bundle_is_rejected_before_apple_authentication
    ENV["IOS_BUNDLE_ID"] = "com.dbpprt.dieter.ios"
    assert_raises(Dieter::PipelineError) { runner.deliver }
    assert_nil @store.token
    assert_empty @uploads
    assert_empty @queries
  end

  def test_previous_account_candidate_is_rejected_before_apple_authentication
    @coordinator.define_singleton_method(:verify_retained) do
      [
        {
          "policy" => {
            "channels" => {
              "dev" => {
                "testflight" => true,
                "testflight_groups" => ["Developers"]
              }
            },
            "ios" => {
              "team_id" => "DS6N5L85E7",
              "bundle_id" => "com.dbpprt.dieter.ios"
            }
          }
        },
        {}
      ]
    end
    assert_raises(Dieter::PipelineError) { runner.deliver }
    assert_nil @store.token
    assert_empty @uploads
  end

  def test_repeated_delivery_reconciles_existing_build_without_upload_or_group_mutation
    runner.deliver
    runner.deliver
    assert_equal 1, @uploads.length
    assert_equal ["Developers"], @builds.first.additions
  end

  def test_unknown_preexisting_remote_build_cannot_be_adopted
    @builds << Build.new
    assert_raises(Dieter::PipelineError) { runner.deliver }
    assert_empty @uploads
    assert_empty @group.members
  end

  def test_accepted_upload_resumes_group_delivery_without_reupload
    @github.previous = [{ "state" => "accepted", "ipa_sha256" => @hash }]
    @builds << Build.new
    runner.deliver
    assert_empty @uploads
    assert_equal "completed", @github.records.last.fetch("state")
  end

  def test_group_failure_preserves_accepted_build_and_resumes_only_delivery
    runner.deliver
    @group.members.clear
    @builds.first.fail_group = true
    assert_raises(Dieter::PipelineError) { runner.deliver }
    @builds.first.fail_group = false
    runner.deliver
    assert_equal 1, @uploads.length
    assert_equal "completed", @github.records.last.fetch("state")
  end

  def test_remote_rejection_and_duplicate_identity_fail_without_upload
    @github.previous = [{ "state" => "accepted", "ipa_sha256" => @hash }]
    @builds << Build.new
    @builds.first.processing_state = "INVALID"
    assert_raises(Dieter::PipelineError) { runner.deliver }
    @builds << Build.new
    assert_raises(Dieter::PipelineError) { runner.deliver }
    assert_empty @uploads
  end

  def test_receipt_for_different_bytes_and_draft_release_are_rejected
    @github.previous = [{ "state" => "accepted", "ipa_sha256" => "0" * 64 }]
    assert_raises(Dieter::PipelineError) { runner.deliver }
    @github.draft = true
    assert_raises(Dieter::PipelineError) { runner.deliver }
    assert_empty @uploads
  end

  def test_only_one_internal_group_can_be_inferred_and_external_groups_are_rejected
    @policy["testflight_groups"].clear
    runner.deliver
    assert_equal ["Developers"], @github.records.last.fetch("groups")
    @groups << Group.new("Another internal group")
    assert_raises(Dieter::Unavailable) { runner.deliver }
    @policy["testflight_groups"] = ["External"]
    @groups << Group.new("External", internal: false)
    assert_raises(Dieter::Unavailable) { runner.deliver }
  end

  def test_live_promotion_verifies_receipt_identity_validity_and_actual_group_membership
    runner.deliver
    refute @builds.first.ready_for_internal_testing?
    assert_equal "IN_BETA_TESTING", @builds.first.build_beta_detail.internal_build_state
    assert_equal @builds.first, runner.verify_live_delivery!(@hash)
    assert_raises(Dieter::Unavailable) { runner.verify_live_delivery!("0" * 64) }
    @builds.first.expired = true
    assert_raises(Dieter::Unavailable) { runner.verify_live_delivery!(@hash) }
    @builds.first.expired = false
    @group.members.clear
    assert_raises(Dieter::Unavailable) { runner.verify_live_delivery!(@hash) }
    assert_equal 1, @uploads.length
    @group.members << @builds.first
    @builds.first.processing_state = "INVALID"
    assert_raises(Dieter::Unavailable) { runner.verify_live_delivery!(@hash) }
    @builds.first.processing_state = "VALID"
    @builds << Build.new
    assert_raises(Dieter::Unavailable) { runner.verify_live_delivery!(@hash) }
  end

  def test_live_promotion_rejects_unavailable_internal_testing_states
    runner.deliver
    detail = @builds.first.build_beta_detail
    %w[
      PROCESSING
      PROCESSING_EXCEPTION
      MISSING_EXPORT_COMPLIANCE
      EXPIRED
      IN_EXPORT_COMPLIANCE_REVIEW
      UNKNOWN
    ].each do |state|
      detail.internal_build_state = state
      assert_raises(Dieter::Unavailable, state) { runner.verify_live_delivery!(@hash) }
      assert_raises(Dieter::PipelineError, state) { runner.deliver }
    end
    @builds.first.build_beta_detail = nil
    assert_raises(Dieter::Unavailable) { runner.verify_live_delivery!(@hash) }
    assert_raises(Dieter::PipelineError) { runner.deliver }
    assert_equal 1, @uploads.length
  end
end
