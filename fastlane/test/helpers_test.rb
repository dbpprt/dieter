# frozen_string_literal: true

# bundle exec ruby -Ifastlane/test fastlane/test/helpers_test.rb  (or: just pipeline-test)
require "minitest/autorun"
require "tmpdir"
require_relative "../helpers/dieter"
require_relative "../helpers/changes"
require_relative "../helpers/e2e"
require_relative "../helpers/release"
require_relative "../helpers/swift"

class LeaseTest < Minitest::Test
  def test_lease_is_exclusive_and_reports_its_owner
    serial = "test-#{SecureRandom.hex(4)}"
    first = Dieter::Lease.new("android-device", serial)
    error = assert_raises(Dieter::Unavailable) { Dieter::Lease.new("android-device", serial) }
    assert_includes error.message, %("pid":#{Process.pid})
    other = Dieter::Lease.new("android-device", "#{serial}-other")
    other.release
    first.release
    Dieter::Lease.new("android-device", serial).release
  end

  def test_device_leases_are_per_exact_serial
    refute_equal Dieter::Lease.path("android-device", "emulator-5554"),
                 Dieter::Lease.path("android-device", "emulator-5556")
    assert_equal Dieter::Lease.path("mac-desktop"), Dieter::Lease.path("mac-desktop", "ignored")
  end

  def test_journal_round_trip_is_private
    Dir.mktmpdir do |directory|
      file = File.join(directory, "journal.json")
      Dieter::Journal.write(file, "ID" => "x")
      assert_equal({ "ID" => "x" }, Dieter::Journal.read(file))
      assert_equal 0o600, File.stat(file).mode & 0o777
      Dieter::Journal.delete(file)
      assert_nil Dieter::Journal.read(file)
    end
  end

  def test_owned_process_group_stops_and_cleanup_reports_every_failure
    Dir.mktmpdir do |directory|
      process = Dieter::Owned.new(["sh", "-c", "sleep 30 & wait"], log: File.join(directory, "log"))
      assert process.running?
      process.stop(grace: 2)
      refute process.running?
      ran = []
      error =
        assert_raises(RuntimeError) do
          Dieter.with_cleanup do |cleanup|
            cleanup.add { ran << :first }
            cleanup.add { raise "second broke" }
            cleanup.add { ran << :third }
          end
        end
      assert_equal %i[third first], ran
      assert_includes error.message, "second broke"
    end
  end
end

class ProfileTest < Minitest::Test
  def setup =
    Dieter.instance_variable_set(
      :@config,
      JSON.parse(File.read(Dieter.path("fastlane/config.json")))
    )
  def teardown = Dieter.instance_variable_set(:@config, nil)

  def test_physical_devices_are_never_a_default
    assert_equal "android-emulator", Dieter.profile("android")["name"]
    assert_raises(Dieter::Unavailable) { Dieter.profile("android", "android-device") }
    config = Dieter.config
    config["profiles"]["android-device"]["serial"] = "EXACT"
    config["defaults"]["android"] = "android-device"
    assert_raises(ArgumentError) { Dieter.profile("android") }
    assert_equal "EXACT", Dieter.profile("android", "android-device")["serial"]
    assert_raises(ArgumentError) { Dieter.profile("ios", "android-emulator") }
  end
end

class VersionTest < Minitest::Test
  def test_apple_build_encoding_is_monotonic_and_bounded
    {
      1 => "1.0.0",
      413 => "1.4.12",
      10_000 => "1.99.99",
      10_001 => "2.0.0",
      99_990_000 => "9999.99.99"
    }.each { |counter, expected| assert_equal expected, Dieter.apple_build(counter) }
    builds =
      [1, 99, 100, 101, 9_999, 10_000, 10_001, 20_000].map do |counter|
        Gem::Version.new(Dieter.apple_build(counter))
      end
    assert_equal builds.sort, builds
    assert_raises(ArgumentError) { Dieter.apple_build(0) }
    assert_raises(ArgumentError) { Dieter.apple_build(99_990_001) }
  end

  def test_next_release_counts_across_lines_and_ignores_other_tags
    reserved =
      Dieter.next_release(
        %w[v0.4.9 v0.4.413 v0.4.413^{} v0.3.999 v0.4.x pipeline-claims/a v0.40.1-rc.1],
        line: "0.4"
      )
    assert_equal(
      { "version" => "0.4.1000", "tag" => "v0.4.1000", "build" => 1000, "apple_build" => "1.9.99" },
      reserved
    )
    moved = Dieter.next_release(%w[v0.4.399 v0.4.12], line: "0.5")
    assert_equal ["0.5.400", 400], [moved["version"], moved["build"]]
    assert_equal "0.5.1", Dieter.next_release([], line: "0.5")["version"]
  end
end

class ChangesTest < Minitest::Test
  def test_globs_follow_paths_filter_semantics
    assert Dieter::Changes.match?("internal/**", "internal/a/b/c.go")
    assert Dieter::Changes.match?("internal/**", "internal/x.go")
    refute Dieter::Changes.match?("internal/**", "internalx/y.go")
    assert Dieter::Changes.match?("**/*.md", "docs/a/b.md")
    assert Dieter::Changes.match?("**/*.md", "README.md")
    assert Dieter::Changes.match?(".github/**", ".github/workflows/ci.yml")
    assert Dieter::Changes.match?("go.mod", "go.mod")
    refute Dieter::Changes.match?("go.mod", "tools/go.mod")
  end

  def test_repository_filters_select_components_with_checks
    filters = Dieter::Changes.filters
    selected =
      Dieter::Changes.select(
        %w[
          internal/engine/turn.go
          apps/kotlin/ui/src/A.kt
          tests/maestro/mobile/task.yaml
          deploy/gateway/scripts/render.py
        ],
        filters
      )
    assert_includes selected.keys, "go"
    assert_includes selected.keys, "android"
    assert_includes selected.keys, "apple"
    assert_includes selected.keys, "maestro"
    assert_includes selected.keys, "deploy-gateway"
    refute_includes selected.keys, "site"
    (filters.keys - %w[format]).each do |name|
      assert Dieter::Changes::CHECKS.key?(name), "#{name} has no local check"
    end
  end
end

class SwiftCountTest < Minitest::Test
  def test_counts_swift_testing_and_xctest_totals
    output = <<~LOG
      \t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
      \t Executed 1 test, with 0 failures (0 unexpected) in 0.004 (0.018) seconds
      ✔ Test run with 455 tests in 31 suites passed after 422.581 seconds.
    LOG
    assert_equal 456, Dieter::Swift.count(output)
    refute Dieter::Swift.failed?(output)
    assert Dieter::Swift.failed?(
             "✘ Test run with 456 tests in 31 suites failed after 4.2 seconds with 1 issue."
           )
    assert Dieter::Swift.failed?("Executed 3 tests, with 1 failure (0 unexpected)")
    assert_equal 0, Dieter::Swift.count("Build complete!\n")
  end
end

class FlowsTest < Minitest::Test
  def test_every_repository_flow_parses
    assert_operator Dieter::Flows.lint, :>=, 3
    smoke = Dieter::Flows.select("android", tags: "smoke").map { |flow| flow["id"] }
    full = Dieter::Flows.select("android", tags: "full").map { |flow| flow["id"] }
    assert_operator full.length, :>, smoke.length
    assert_equal ["task"], Dieter::Flows.select("ios", names: "task").map { |flow| flow["id"] }
    assert_raises(ArgumentError) { Dieter::Flows.select("ios", names: "missing") }
    assert_raises(ArgumentError) { Dieter::Flows.select("ios", tags: "nightly") }
  end

  def test_mac_plans_reject_unsupported_commands_with_their_line
    Dir.mktmpdir do |directory|
      file = File.join(directory, "flow.yaml")
      File.write(
        file,
        "appId: x\nname: Example\ntags: [smoke]\n---\n- launchApp\n- swipe:\n    direction: UP\n"
      )
      flow = Dieter::Flows.parse(file)
      assert_equal [5, 6], flow["lines"]
      error = assert_raises(ArgumentError) { Dieter::Flows.mac_plan(flow) }
      assert_match(/:6: unsupported Maestro command swipe/, error.message)
      plan = Dieter::Flows.mac_plan(flow.merge("steps" => ["launchApp"], "lines" => [5]))
      assert_equal ["passed", ""], Dieter::Flows.qualify_mac({ "step-0" => "passed" }, plan)
      assert_equal "failed", Dieter::Flows.qualify_mac({}, plan).first
      assert_equal "failed",
                   Dieter::Flows.qualify_mac(
                     { "step-0" => "passed", "step-9" => "passed" },
                     plan
                   ).first
    end
  end

  def test_missing_junit_results_fail_the_run
    Dir.mktmpdir do |directory|
      flows = Dieter::Flows.select("android", tags: "full")
      junit = File.join(directory, "junit.xml")
      first = File.basename(flows.first["path"])
      File.write(
        junit,
        %(<testsuites><testsuite><testcase name="a" file="/x/#{first}" time="1.5"/></testsuite></testsuites>)
      )
      results = Dieter::Results.new("android", flows, directory)
      out, = capture_io { results.record_junit(junit) }
      assert_includes out, "missing from the Maestro JUnit report"
      error = assert_raises(RuntimeError) { results.finish }
      assert_match(%r{#{flows.length - 1}/#{flows.length} android flows failed}, error.message)
      assert File.file?(File.join(directory, "results.json"))
    end
  end

  def test_fixture_token_is_redacted_from_evidence
    Dir.mktmpdir do |directory|
      file = File.join(directory, "maestro.log")
      File.write(file, "token=isolated_#{"a" * 48}\n")
      Dieter::Fixture.redact(directory)
      assert_equal "token=<redacted>\n", File.read(file)
    end
  end
end

class ReleaseTest < Minitest::Test
  def test_changelog_section_must_exist
    text = "# Changelog\n\n## [0.4.2] - 2026-10-01\n\n- Fix.\n\n## 0.4.1\n\n- Old.\n"
    assert_equal "- Fix.", Dieter::Release.changelog_section(text, "0.4.2")
    assert_equal "- Old.", Dieter::Release.changelog_section(text, "0.4.1")
    assert_raises(Dieter::Unavailable) { Dieter::Release.changelog_section(text, "0.4.3") }
  end

  def test_homebrew_files_render_from_the_identity_and_release
    identity = {
      "repository" => "owner/dieter",
      "homebrew_tap" => "owner/homebrew-tap",
      "bundle_prefix" => "org.example"
    }
    formula =
      Dieter::Release.homebrew(
        "dieter.rb.erb",
        version: "0.5.9",
        sha256: "f" * 64,
        identity: identity
      )
    assert_includes formula,
                    %(url "https://github.com/owner/dieter/releases/download/v0.5.9/dieter-darwin-arm64.tar.gz")
    assert_includes formula, %(version "0.5.9")
    assert_includes formula, %(sha256 "#{"f" * 64}")
    cask =
      Dieter::Release.homebrew(
        "dieter-app.rb.erb",
        version: "0.5.9",
        sha256: "e" * 64,
        identity: identity
      )
    assert_includes cask,
                    %(url "https://github.com/owner/dieter/releases/download/v\#{version}/Dieter-macOS-arm64.zip")
    assert_includes cask, %("~/Library/Application Support/org.example.mac")
    refute_match(/<%|dbpprt|getdieter/, formula + cask)
    Dieter::Release::HOMEBREW.each_value do |template, _asset|
      assert File.file?(Dieter.path("deploy/homebrew", template)), template
    end
    assert_raises(ArgumentError) do
      Dieter::Release.homebrew("dieter.rb.erb", version: "1", sha256: "a", identity: identity)
    end
  end

  def test_daemon_ldflags_pin_the_harness_runtime_archive
    package = "github.com/dbpprt/dieter/internal/platform/buildinfo"
    plain = Dieter::Release.ldflags("0.5.9", "abc123")
    assert_includes plain, "-X #{package}.ReleaseVersion=0.5.9"
    assert_includes plain, "-X #{package}.SourceRevision=abc123"
    refute_includes plain, "HarnessRuntimeSHA256"
    pinned = Dieter::Release.ldflags("0.5.9", "abc123", harness_runtime_sha256: "a" * 64)
    assert pinned.start_with?(plain)
    assert pinned.end_with?(" -X #{package}.HarnessRuntimeSHA256=#{"a" * 64}")
    assert_raises(ArgumentError) do
      Dieter::Release.ldflags("0.5.9", "abc123", harness_runtime_sha256: "a" * 63)
    end
    assert_raises(ArgumentError) do
      Dieter::Release.ldflags("0.5.9", "abc123", harness_runtime_sha256: "a" * 64 + " -X x=y")
    end
    assert_equal "dieter-harness-runtime-linux-arm64.tar.gz",
                 Dieter::Release.harness_runtime_archive("linux", "arm64")
  end

  def test_retention_keeps_recent_and_newest_dev_releases_only
    now = Time.utc(2026, 10, 11)
    releases =
      (1..25).map do |day|
        {
          "id" => day,
          "prerelease" => true,
          "draft" => false,
          "published_at" => (now - day * 86_400).iso8601
        }
      end
    releases << {
      "id" => 99,
      "prerelease" => false,
      "draft" => false,
      "published_at" => (now - 400 * 86_400).iso8601
    }
    expired =
      Dieter::Release
        .expired(releases, count: 20, days: 14, now: now)
        .map { |release| release["id"] }
    assert_equal (21..25).to_a, expired
  end
end

class WorkflowContractTest < Minitest::Test
  def workflow(name) =
    YAML.safe_load(File.read(Dieter.path(".github/workflows", name)), aliases: true)

  # Installed updaters and install.sh verify exactly this signer; renaming the
  # workflow is a protocol break.
  def test_release_workflow_is_the_frozen_signer
    assert_includes File.read(Dieter.path("tools/identity/main.go")),
                    %(ReleaseWorkflow = ".github/workflows/release.yml")
    publish = workflow("release.yml").fetch("jobs").fetch("publish")
    assert_equal "write", publish.fetch("permissions").fetch("id-token")
    steps = publish.fetch("steps").map { |step| step["run"].to_s }.join("\n")
    assert_includes steps, "cosign sign-blob --yes --bundle dist/release/SHA256SUMS.sigstore.json"
    assert_includes File.read(Dieter.path("deploy/install/install.sh")), Dieter::Release.signer
  end

  # Release daemons download their platform's harness runtime archive from
  # their own release; every daemon builder must publish its archive. Building
  # an archive runs third-party installers, so no job that does holds secrets.
  def test_daemon_builders_publish_their_harness_runtime_archives
    server = workflow("_build-server.yml").fetch("jobs").fetch("linux")
    assert_equal %w[amd64 arm64],
                 server.dig("strategy", "matrix", "include").map { |item| item["arch"] }
    apple = workflow("_build-apple.yml").fetch("jobs")
    archive = Dieter::Release.harness_runtime_archive("darwin", "arm64")
    {
      server => "dist/server/*.tar.gz",
      apple.fetch("harness-runtime") => "dist/harness-runtime/#{archive}"
    }.each do |job, path|
      refute job.key?("environment")
      steps = job.fetch("steps")
      setup = steps.find { |step| step["uses"] == "./.github/actions/setup" }
      assert_includes setup.dig("with", "tools").split, "node"
      upload = steps.find { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
      assert_includes upload.dig("with", "path").split, path
    end
    daemon = apple.fetch("daemon")
    assert_equal "harness-runtime", daemon.fetch("needs")
    { server => "dist/server/*.tar.gz", daemon => "dist/daemon/#{archive}" }.each do |job, path|
      upload =
        job.fetch("steps").find { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
      assert_includes upload.dig("with", "path").split, path
      assert upload.dig("with", "name").start_with?("release-")
    end
    publish = workflow("release.yml").fetch("jobs").fetch("publish").fetch("steps")
    assert_includes publish.map { |step| step["run"].to_s }.join("\n"), "cp dist/built/*.tar.gz"
  end

  # CI and the secret-free builders run third-party code that could poison a
  # cache, so jobs holding signing secrets or a write token restore only
  # release-scoped caches, which only such jobs write.
  def test_privileged_jobs_use_release_caches
    Dir
      .glob(Dieter.path(".github/workflows/*.yml"))
      .each do |file|
        workflow = YAML.safe_load(File.read(file), aliases: true)
        workflow
          .fetch("jobs")
          .each do |name, job|
            setup = Array(job["steps"]).find { |step| step["uses"] == "./.github/actions/setup" }
            next unless setup
            permissions =
              (job["permissions"] || workflow["permissions"]).to_h.except("security-events")
            privileged = job.key?("environment") || permissions.value?("write")
            assert_equal privileged,
                         setup.dig("with", "cache-scope") == "release",
                         "#{File.basename(file)}: #{name}"
          end
      end
  end

  def test_ci_ok_gates_every_job_and_every_job_has_a_timeout
    jobs = workflow("ci.yml").fetch("jobs")
    assert_equal (jobs.keys - ["ci-ok"]).sort, jobs.fetch("ci-ok").fetch("needs").sort
    Dir
      .glob(Dieter.path(".github/workflows/*.yml"))
      .each do |file|
        YAML
          .safe_load(File.read(file), aliases: true)
          .fetch("jobs")
          .each do |name, job|
            next if job.key?("uses")
            assert job.key?("timeout-minutes"),
                   "#{File.basename(file)}: #{name} has no timeout-minutes"
          end
      end
  end

  def test_checkouts_do_not_persist_credentials_unless_they_push
    Dir
      .glob(Dieter.path(".github/workflows/*.yml"))
      .each do |file|
        YAML
          .safe_load(File.read(file), aliases: true)
          .fetch("jobs")
          .each do |name, job|
            Array(job["steps"])
              .select { |step| step["uses"].to_s.start_with?("actions/checkout@") }
              .each do |step|
                persist = step.dig("with", "persist-credentials")
                assert(
                  persist == false || (name == "version" && persist == true),
                  "#{File.basename(file)}: #{name}"
                )
              end
          end
      end
  end
end

class SwiftWebRTCCacheTest < Minitest::Test
  def test_only_invalidates_webrtc_modules_when_the_binary_artifact_changes
    Dir.mktmpdir do |directory|
      manifest = File.join(directory, "Package.swift")
      artifact = ->(version) do
        %(.binaryTarget(\n    name: "WebRTC",\n    url: "https://example.com/#{version}.zip",\n    checksum: "#{version}"\n))
      end
      File.write(manifest, artifact.call("old"))
      modules = File.join(directory, "Build/Intermediates.noindex/SwiftExplicitPrecompiledModules")
      FileUtils.mkdir_p(modules)
      webrtc = File.join(modules, "WebRTC-cached.pcm")
      unrelated = File.join(modules, "AppKit-cached.pcm")
      File.write(webrtc, "old module")
      File.write(unrelated, "keep")

      Dieter::Swift.prepare_xcode_webrtc_cache(directory, manifest: manifest)
      refute File.exist?(webrtc)
      assert_equal "keep", File.read(unrelated)
      File.write(webrtc, "current module")
      Dieter::Swift.prepare_xcode_webrtc_cache(directory, manifest: manifest)
      assert_equal "current module", File.read(webrtc)

      File.write(manifest, artifact.call("new"))
      Dieter::Swift.prepare_xcode_webrtc_cache(directory, manifest: manifest)
      refute File.exist?(webrtc)
      assert_equal "keep", File.read(unrelated)
    end
  end
end
