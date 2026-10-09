# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/pipeline/identity"
require_relative "../lib/dieter/pipeline/candidate"
require_relative "../lib/dieter/distribution/retention"
require_relative "../lib/dieter/runtime"

class ReleaseContractsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("release-contract-")
    @policy = JSON.parse(File.read(File.expand_path("../release-policy.json", __dir__)))
    @value = {"schema_version" => 1, "repository" => @policy.fetch("repository"), "source_revision" => "a" * 40, "version" => "0.4.413", "tag" => "v0.4.413", "native_build" => 413, "reserved_at" => "2026-10-03T21:00:00Z", "policy_sha256" => Digest::SHA256.hexdigest(JSON.generate(@policy))}
    @identity = Dieter::ReleaseIdentity.new(@value, policy: @policy)
  end

  def teardown = FileUtils.remove_entry_secure(@root)

  def manifest
    path = File.join(@root, "Dieter-iOS.ipa")
    File.write(path, "retained signed IPA fixture")
    {"schema_version" => 1, "component" => "ios", "identity_sha256" => @identity.digest, "source_revision" => @identity.source, "release_version" => @identity.version, "native_build" => @identity.build, "qualification" => "passed", "artifacts" => [{"name" => File.basename(path), "sha256" => Dieter::ArtifactSet.sha256(path), "bytes" => File.size(path)}]}
  end

  def test_numeric_canonical_identity_and_counter_are_fixed_across_components
    environment = @identity.environment
    assert_equal "0.4.413", environment.fetch("DIETER_RELEASE_VERSION")
    assert_equal "1.4.12", environment.fetch("IOS_BUILD_NUMBER")
    assert_equal "413", environment.fetch("DIETER_RELEASE_VERSION_CODE")
    assert_equal environment.fetch("IOS_VERSION"), environment.fetch("RELEASE_VERSION")
    path = File.join(@root, "identity.json")
    @identity.write(path)
    assert_equal @identity.data, Dieter::ReleaseIdentity.load(path, policy: @policy).data
  end

  def test_release_workflow_identity_resolves_from_repository_while_fastlane_changes_directory
    @identity.write(File.join(@root, "identity.json"))
    lane_directory = File.join(@root, "fastlane")
    FileUtils.mkdir_p(lane_directory)
    File.write(File.join(lane_directory, "identity.json"), "invalid shadow identity")
    context = Struct.new(:root, :closed) do
      def close = self.closed = true
    end.new(@root, false)
    coordinator = Object.new
    coordinator.define_singleton_method(:verify_retained) { :verified_exact_identity }
    factory = lambda do |received_context, identity|
      assert_same context, received_context
      assert_equal @identity.data, identity.data
      coordinator
    end
    Dieter::Config.stub(:new, Object.new) do
      Dieter::RunContext.stub(:new, context) do
        Dieter::GitHubDestination.stub(:new, Object.new) do
          Dieter::ReleaseCoordinator.stub(:new, factory) do
            Dir.chdir(lane_directory) do
              assert_equal :verified_exact_identity, Dieter::Runtime.release({action: "verify", identity: "identity.json"})
            end
          end
        end
      end
    end
    assert context.closed
  end

  def test_identity_rejects_invalid_semver_counter_source_and_local_policy
    [{"version" => "0.4.413-dev"}, {"tag" => "v0.4.414"}, {"native_build" => "413"}, {"native_build" => 2_100_000_001}, {"source_revision" => "main"}, {"repository" => "attacker/repo"}, {"policy_sha256" => "b" * 64}, {"upload" => true}].each do |change|
      assert_raises(Dieter::PipelineError) { Dieter::ReleaseIdentity.new(@value.merge(change), policy: @policy) }
    end
  end

  def test_identity_rejects_wrong_types_duplicate_keys_and_invalid_dates
    %w[source_revision version tag reserved_at repository policy_sha256].each do |key|
      [nil, 12, []].each { |value| assert_raises(Dieter::PipelineError) { Dieter::ReleaseIdentity.new(@value.merge(key => value)) } }
    end
    ["2026-02-30T01:00:00Z", "2026-10-03", "2026-10-03T25:00:00Z", "2026-10-03T21:00:00+00:00"].each do |value|
      assert_raises(Dieter::PipelineError) { Dieter::ReleaseIdentity.new(@value.merge("reserved_at" => value)) }
    end
    path = File.join(@root, "identity.json")
    File.write(path, JSON.generate(@value).sub('"native_build":413', '"native_build":412,"native_build":413'))
    assert_raises(Dieter::PipelineError) { Dieter::ReleaseIdentity.load(path) }
    mutable = @value.transform_values { |value| value.is_a?(String) ? value.dup : value }
    retained = Dieter::ReleaseIdentity.new(mutable)
    mutable["version"].replace("0.4.414")
    assert_equal "0.4.413", retained.version
  end

  def test_apple_counter_encoding_remains_valid_and_ordered_at_boundaries
    builds = [1, 100, 101, 10_000, 10_001, Dieter::ReleaseIdentity::MAX_COUNTER].map do |counter|
      Dieter::ReleaseIdentity.new(@value.merge("native_build" => counter)).apple_build
    end
    assert_equal %w[1.0.0 1.0.99 1.1.0 1.99.99 2.0.0 9999.99.99], builds
    assert_equal builds.map { |build| build.split(".").map(&:to_i) }.sort, builds.map { |build| build.split(".").map(&:to_i) }
    assert_raises(Dieter::PipelineError) { Dieter::ReleaseIdentity.new(@value.merge("native_build" => Dieter::ReleaseIdentity::MAX_COUNTER + 1)) }
  end

  def test_main_development_channel_cannot_advance_stable_destinations
    dev = @policy.fetch("channels").fetch("dev")
    assert dev.fetch("publish")
    assert dev.fetch("prerelease")
    assert dev.fetch("testflight")
    refute dev.fetch("make_latest")
    refute dev.fetch("homebrew")
    refute dev.fetch("deploy_gateway")
    assert @policy.fetch("channels").fetch("stable").fetch("homebrew")
  end

  def test_retained_artifact_validation_checks_source_hash_size_identity_and_component
    value = manifest
    assert_equal value, Dieter::CandidatePipeline.validate(value, @identity, @root, expected: "ios")
    [{"source_revision" => "b" * 40}, {"identity_sha256" => "b" * 64}, {"release_version" => "0.4.414"}, {"native_build" => "414"}, {"component" => "android"}, {"qualification" => "skipped"}].each do |change|
      assert_raises(Dieter::PipelineError) { Dieter::CandidatePipeline.validate(value.merge(change), @identity, @root, expected: "ios") }
    end
    File.write(File.join(@root, "Dieter-iOS.ipa"), "different bytes same reserve")
    assert_raises(Dieter::PipelineError) { Dieter::CandidatePipeline.validate(value, @identity, @root) }
  end

  def test_retained_products_reject_traversal_duplicate_and_symlink_inputs
    value = manifest
    artifact = value.fetch("artifacts").first
    [[artifact.merge("name" => "../Dieter-iOS.ipa")], [artifact, artifact], []].each do |artifacts|
      assert_raises(Dieter::PipelineError) { Dieter::CandidatePipeline.validate(value.merge("artifacts" => artifacts), @identity, @root) }
    end
    path = File.join(@root, "Dieter-iOS.ipa")
    File.rename(path, path + ".original")
    File.symlink(path + ".original", path)
    assert_raises(Dieter::PipelineError) { Dieter::CandidatePipeline.validate(value, @identity, @root) }
  end
end

class ReleaseRetentionPolicyTest < Minitest::Test
  def test_stable_and_drafts_are_never_selected_and_both_development_guards_apply
    now = Time.utc(2026, 10, 3)
    releases = 25.times.map { |number| {"tag_name" => "v0.4.#{number}", "prerelease" => true, "draft" => false, "published_at" => (now - (30 - number) * 86_400).iso8601} }
    releases += [{"tag_name" => "stable", "prerelease" => false, "draft" => false, "published_at" => (now - 90 * 86_400).iso8601}, {"tag_name" => "draft", "prerelease" => true, "draft" => true, "published_at" => (now - 90 * 86_400).iso8601}]
    selected = Dieter::ReleaseRetention.eligible(releases, {"dev_count" => 20, "dev_days" => 14}, now: now)
    assert_equal 5, selected.length
    assert_equal %w[v0.4.4 v0.4.3 v0.4.2 v0.4.1 v0.4.0], selected.map { |value| value.fetch("tag_name") }
    recent = releases.map { |release| release.merge("published_at" => (now - 5 * 86_400).iso8601) }
    assert_empty Dieter::ReleaseRetention.eligible(recent, {"dev_count" => 20, "dev_days" => 14}, now: now)
  end
end
