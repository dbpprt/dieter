# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/pipeline/evidence"

class EvidenceTest < Minitest::Test
  def test_summary_includes_shared_build_cost_and_bounds_operation_rows
    previous = ENV["GITHUB_STEP_SUMMARY"]
    Dir.mktmpdir do |root|
      dir = File.join(root, "tmp/app-pipelines/shared")
      FileUtils.mkdir_p(dir)
      operations = 20.times.map { |i| {name: "command #{i}", durationMs: i * 1000, status: "passed"} }
      operations << {name: "Fastlane run_tests | <build>", durationMs: 1091237, status: "passed"}
      File.write(File.join(dir, "timings.json"), JSON.generate(operations: operations))
      ENV["GITHUB_STEP_SUMMARY"] = File.join(root, "summary.md")
      Dieter::Evidence.collect(root, output: "tmp/evidence")
      summary = File.read(ENV.fetch("GITHUB_STEP_SUMMARY"))
      assert_includes summary, "Fastlane run_tests &#124; &lt;build&gt;"
      assert_includes summary, "1091.2"
      assert_includes summary, "tmp/app-pipelines/shared"
      assert_equal 10, summary.lines.count { |line| line.start_with?("| command", "| Fastlane") }
    end
  ensure
    ENV["GITHUB_STEP_SUMMARY"] = previous
  end

  def test_evidence_keeps_reports_and_failure_images_without_archives_checkpoints_or_escaping_links
    Dir.mktmpdir do |root|
      dir = File.join(root, "tmp/candidate")
      FileUtils.mkdir_p(File.join(dir, "Dieter.xcarchive"))
      FileUtils.mkdir_p(File.join(dir, "producer"))
      %w[build.log candidate-ios.json failure.png Dieter.ipa].each { |name| File.write(File.join(dir, name), "evidence") }
      File.write(File.join(dir, "Dieter.xcarchive/private.json"), "private")
      File.write(File.join(dir, "producer/candidate-ios.json"), "checkpoint")
      File.symlink(File.join(dir, "Dieter.ipa"), File.join(dir, "escape.log"))
      File.open(File.join(dir, "large.mp4"), "w") { |file| file.truncate(17 * 1024 * 1024) }
      manifest = Dieter::Evidence.collect(root, output: "tmp/evidence")
      assert_equal %w[build.log candidate-ios.json failure.png], manifest[:files].map { |entry| File.basename(entry[:path]) }.sort
      assert_equal 24, manifest[:bytes]
      assert manifest[:omitted].any? { |entry| entry[:path].end_with?("escape.log") && entry[:reason] == "symlink" }
      assert manifest[:omitted].any? { |entry| entry[:path].end_with?("large.mp4") }
      refute File.exist?(File.join(root, "tmp/evidence/tmp/candidate/producer"))
      assert_raises(Dieter::PipelineError) { Dieter::Evidence.collect(root, output: "../escape") }
    end
  end

  def test_rejects_symlinked_source_and_destination_ancestors
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "tmp/actual"))
      File.symlink(File.join(root, "tmp/actual"), File.join(root, "tmp/link"))
      assert_raises(Dieter::PipelineError) { Dieter::Evidence.collect(root, output: "tmp/link/evidence") }
      assert_raises(Dieter::PipelineError) { Dieter::Evidence.collect(root, output: "tmp/evidence", sources: ["tmp/link/subdir"]) }
    end
  end

  def test_preserves_reports_when_bulk_logs_fill_upload_budget
    Dir.mktmpdir do |root|
      dir = File.join(root, "tmp/app-pipelines/run")
      FileUtils.mkdir_p(dir)
      17.times { |i| File.open(File.join(dir, "a#{i}.log"), "w") { |file| file.truncate(4 * 1024 * 1024) } }
      File.write(File.join(dir, "results.json"), '{"results":[]}')
      manifest = Dieter::Evidence.collect(root, output: "tmp/evidence")
      assert_equal "results.json", File.basename(manifest[:files].first[:path])
      assert_operator manifest[:bytes], :<=, Dieter::Evidence::MAX_BYTES
      assert manifest[:omitted].any? { |entry| entry[:reason].start_with?("upload exceeds") }
    end
  end
end
