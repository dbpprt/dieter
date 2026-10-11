# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dieter/e2e"

class E2EFlowTest < Minitest::Test
  def test_tags_select_flows_and_explicit_names_override_them
    smoke = Dieter::E2E.flows("android", tags: "smoke").map { |flow| flow.fetch("id") }
    full = Dieter::E2E.flows("ios", tags: "full").map { |flow| flow.fetch("id") }
    assert_includes smoke, "board"
    refute_includes smoke, "tools"
    assert_operator full.length, :>, smoke.length
    assert_equal %w[tools],
                 Dieter::E2E.flows("android", names: %w[tools]).map { |flow| flow.fetch("id") }
    assert_raises(Dieter::PipelineError) { Dieter::E2E.flows("android", names: %w[missing]) }
    assert_raises(Dieter::PipelineError) { Dieter::E2E.flows("mac", tags: "functional") }
  end

  def test_every_repository_flow_parses_and_resolves_its_subflows
    assert_operator Dieter::E2E.lint, :>=, 4
  end

  def test_mac_plan_keeps_source_lines_and_rejects_commands_the_app_cannot_run
    Dir.mktmpdir do |root|
      path = File.join(root, "flow.yaml")
      File.write(path, <<~YAML)
        # A comment line
        appId: com.dbpprt.dieter
        name: Example
        tags: [smoke]
        ---
        - launchApp
        - tapOn:
            id: sidebar.inbox
        - assertVisible: "Inbox"
      YAML
      plan = Dieter::E2E.mac_plan(Dieter::E2E.flow(path))
      assert_equal 1, plan.fetch("version")
      assert_equal(
        [
          { "launchApp" => true, "line" => 6 },
          { "tapOn" => { "id" => "sidebar.inbox" }, "line" => 7 },
          { "assertVisible" => "Inbox", "line" => 9 }
        ],
        plan.fetch("steps")
      )
      File.write(path, "name: Example\ntags: [smoke]\n---\n- scrollUntilVisible:\n    element: x\n")
      error = assert_raises(Dieter::PipelineError) { Dieter::E2E.mac_plan(Dieter::E2E.flow(path)) }
      assert_match(/:4: Unsupported Maestro command scrollUntilVisible on macOS/, error.message)
      File.write(path, "name: Example\ntags: [nightly]\n---\n- launchApp\n")
      assert_raises(Dieter::PipelineError) { Dieter::E2E.flow(path) }
    end
  end
end

class E2EQualificationTest < Minitest::Test
  def runner = Dieter::E2E.allocate

  def test_mac_reports_require_every_planned_step_and_nothing_else
    plan = { "source" => "flow.yaml", "steps" => [{ "line" => 5 }, { "line" => 6 }] }
    assert_equal ["passed", ""],
                 runner.send(:qualify, { "step-0" => "passed", "step-1" => "passed" }, plan)
    assert_equal "failed", runner.send(:qualify, { "step-0" => "passed" }, plan).first
    assert_match(
      /flow.yaml:6: no result/,
      runner.send(:qualify, { "step-0" => "passed" }, plan).last
    )
    assert_equal "failed",
                 runner.send(
                   :qualify,
                   { "step-0" => "passed", "step-1" => "passed", "step-2" => "passed" },
                   plan
                 ).first
    assert_equal ["failed", "failed: boom"],
                 runner.send(
                   :qualify,
                   { "step-0" => "passed", "step-1" => "passed", "flow" => "failed: boom" },
                   plan
                 )
  end

  def test_junit_cases_map_flow_files_to_results
    Dir.mktmpdir do |root|
      path = File.join(root, "junit.xml")
      File.write(path, <<~XML)
        <?xml version='1.0' encoding='UTF-8'?>
        <testsuites><testsuite name="Test Suite" tests="2" failures="1">
          <testcase id="Board" name="Board" file="tests/maestro/mobile/board.yaml" time="35.2" status="SUCCESS"/>
          <testcase id="Task" name="Task" file="task.yaml" time="61.0" status="ERROR"><failure>Element not found</failure></testcase>
        </testsuite></testsuites>
      XML
      cases = runner.send(:junit_cases, path)
      assert_equal ["passed", "", 35.2], cases.fetch("board.yaml")
      assert_equal ["failed", "Element not found", 61.0], cases.fetch("task.yaml")
      assert_empty runner.send(:junit_cases, File.join(root, "missing.xml"))
    end
  end

  def test_evidence_redacts_fixture_tokens
    Dir.mktmpdir do |root|
      token = "isolated_#{"a" * 48}"
      File.write(File.join(root, "commands.json"), %({"arguments":{"fixture_token":"#{token}"}}))
      runner.send(:redact, root)
      refute_includes File.read(File.join(root, "commands.json")), token
    end
  end
end
