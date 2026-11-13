import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { createSubagentCapabilityCollector } from "./capabilities.mjs";
import {
  createStrixProjection,
  runStrixTurn,
  strixArgs,
  strixConsoleError,
  strixEnvironment,
  strixTargets,
} from "./strix-runtime.mjs";

// A run directory in the layout Strix 1.7.1 writes (see strix/core/paths.py,
// strix/core/sessions.py and strix/report/writer.py).
async function writeRun(
  runDir,
  { status = "running", rows = [], agents, todos, findings, report, usage } = {},
) {
  await mkdir(join(runDir, ".state"), { recursive: true });
  await writeFile(
    join(runDir, "run.json"),
    JSON.stringify({
      run_name: runDir.split("/").pop(),
      status,
      llm_usage: usage || { input_tokens: 0, output_tokens: 0, total_tokens: 0, cost: 0 },
      ...(status === "completed"
        ? { scan_results: { executive_summary: "One critical issue." } }
        : {}),
    }),
  );
  await writeFile(
    join(runDir, ".state", "agents.json"),
    JSON.stringify(
      agents || {
        statuses: { root1: "running" },
        parent_of: { root1: null },
        names: { root1: "Root Agent" },
      },
    ),
  );
  if (todos) await writeFile(join(runDir, ".state", "todos.json"), JSON.stringify(todos));
  if (findings) {
    await mkdir(join(runDir, "vulnerabilities"), { recursive: true });
    await writeFile(join(runDir, "vulnerabilities.json"), JSON.stringify(findings));
    for (const finding of findings) {
      await writeFile(
        join(runDir, "vulnerabilities", `${finding.id}.md`),
        `# ${finding.title}\n\nDetails.`,
      );
    }
  }
  if (report) await writeFile(join(runDir, "penetration_test_report.md"), report);
  const db = new DatabaseSync(join(runDir, ".state", "agents.db"));
  db.exec(`CREATE TABLE IF NOT EXISTS agent_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
    message_data TEXT NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)`);
  const insert = db.prepare("INSERT INTO agent_messages (session_id, message_data) VALUES (?, ?)");
  for (const [session, item] of rows) insert.run(session, JSON.stringify(item));
  db.close();
}

const assistant = (text) => ({
  type: "message",
  role: "assistant",
  content: [{ type: "output_text", text }],
});
const call = (id, name, args) => ({
  type: "function_call",
  call_id: id,
  name,
  arguments: JSON.stringify(args),
});
const output = (id, value) => ({ type: "function_call_output", call_id: id, output: value });

function recorder() {
  const chunks = [];
  const capabilities = [];
  const collector = createSubagentCapabilityCollector({
    provider: "strix",
    adapter: "strix",
    messageId: "msg_test",
    emit: (capability) => capabilities.push(capability),
  });
  return { chunks, capabilities, collector, emit: (chunk) => chunks.push(chunk) };
}

test("projects the root agent, its children, todos and findings of a run directory", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "strix-projection-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const runDir = join(root, "strix_runs", "target_1234");
  await writeRun(runDir, {
    status: "completed",
    agents: {
      statuses: { root1: "completed", kid1: "completed" },
      parent_of: { root1: null, kid1: "root1" },
      names: { root1: "Root Agent", kid1: "Access control specialist" },
      metadata: { kid1: { task: "Review /user for IDOR" } },
    },
    rows: [
      ["root1", { role: "user", content: "task" }],
      ["root1", assistant("Mapping the service.")],
      ["root1", call("call_1", "exec_command", { cmd: "ls" })],
      ["root1", output("call_1", "app\nREADME.md")],
      ["kid1", assistant("Checking /user.")],
      ["kid1", call("call_2", "agent_finish", { result_summary: "IDOR" })],
    ],
    todos: {
      root1: {
        a1: { title: "Map the surface", status: "done" },
        b2: { title: "Test /ping", status: "pending" },
      },
    },
    findings: [
      { id: "vuln-0001", title: "Command injection", severity: "critical", cwe: "CWE-78" },
    ],
    report: "# Penetration test report\n\nOne critical issue.",
    usage: {
      input_tokens: 900,
      output_tokens: 100,
      total_tokens: 1000,
      cost: 0.25,
      agents: [
        { agent_id: "kid1", model: "openai/glm-5.3", requests: 3, total_tokens: 400, cost: 0.05 },
      ],
    },
  });
  const { chunks, capabilities, collector, emit } = recorder();
  const projection = createStrixProjection({ runsRoot: join(root, "strix_runs"), emit, collector });
  assert.equal(projection.poll(), "completed");
  projection.summarize({ budgetUSD: "10" });

  const tools = chunks.filter((chunk) => chunk.type === "tool-input-available");
  assert.deepEqual(
    tools.map((chunk) => chunk.toolName),
    ["exec_command", "strix_finding"],
    "child items stay off the transcript",
  );
  assert.deepEqual(tools[0].input, { cmd: "ls" });
  const outputs = new Set(
    chunks.filter((chunk) => chunk.type === "tool-output-available").map((c) => c.toolCallId),
  );
  for (const tool of tools)
    assert.ok(outputs.has(tool.toolCallId), `${tool.toolName} has an output`);
  const finding = chunks.find(
    (c) => c.type === "tool-output-available" && c.toolCallId === "strix-finding-vuln-0001",
  );
  assert.match(finding.output, /# Command injection/);
  const text = chunks
    .filter((c) => c.type === "text-delta")
    .map((c) => c.delta)
    .join("\n");
  assert.match(text, /Mapping the service\./);
  assert.match(text, /# Penetration test report/, "a completed scan ends with its report");
  assert.match(text, /1 finding \(1 critical\)/);
  assert.match(text, /Model cost this turn: \$0\.2500/);

  const subagent = capabilities.filter((c) => c.id === "subagents").at(-1).subagent;
  assert.equal(subagent.name, "Access control specialist");
  assert.equal(subagent.status, "completed");
  assert.equal(subagent.task, "Review /user for IDOR");
  assert.deepEqual(subagent.recentOutput, ["Checking /user.", "→ agent_finish"]);
  assert.equal(subagent.toolCount, 1);
  assert.equal(subagent.currentTool, "agent_finish");
  assert.equal(subagent.activity, "Checking /user.");
  assert.equal(subagent.requests, 3);
  assert.equal(subagent.cost, 0.05);
  assert.equal(subagent.model, "openai/glm-5.3");
  const plan = capabilities.filter((c) => c.id === "task-plan").at(-1).plan;
  assert.deepEqual(
    plan.phases[0].tasks.map((task) => [task.content, task.status]),
    [
      ["Map the surface", "completed"],
      ["Test /ping", "pending"],
    ],
  );
  assert.deepEqual(projection.cursor, { runName: "target_1234", lastRowId: 6 });
  assert.deepEqual(projection.turnUsage(), {
    inputTokens: 900,
    outputTokens: 100,
    totalTokens: 1000,
    cost: 0.25,
    runCost: 0.25,
  });
});

test("a resumed run shows only what the new turn added", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "strix-resume-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const runDir = join(root, "strix_runs", "target_1234");
  const agents = (statuses) => ({
    statuses: { root1: "running", ...statuses },
    parent_of: { root1: null, old1: "root1", cut1: "root1", new1: "root1" },
    names: {
      root1: "Root Agent",
      old1: "Finished earlier",
      cut1: "Interrupted earlier",
      new1: "Started now",
    },
  });
  await writeRun(runDir, {
    agents: agents({ old1: "completed", cut1: "running" }),
    rows: [
      ["root1", assistant("First turn.")],
      ["root1", call("call_1", "finish_scan", {})],
      ["root1", output("call_1", "done")],
    ],
    findings: [{ id: "vuln-0001", title: "Old finding", severity: "high" }],
    usage: { input_tokens: 500, output_tokens: 50, total_tokens: 550, cost: 1 },
  });
  const { chunks, capabilities, collector, emit } = recorder();
  const projection = createStrixProjection({
    runsRoot: join(root, "strix_runs"),
    emit,
    collector,
    cursor: { runName: "target_1234", lastRowId: 3 },
  });
  projection.prime();
  await writeRun(runDir, {
    agents: agents({ old1: "completed", cut1: "completed", new1: "running" }),
    rows: [["root1", assistant("Second turn.")]],
    findings: [
      { id: "vuln-0001", title: "Old finding", severity: "high" },
      { id: "vuln-0002", title: "New finding", severity: "medium" },
    ],
    usage: { input_tokens: 800, output_tokens: 70, total_tokens: 870, cost: 1.5 },
  });
  projection.poll();
  const text = chunks.filter((c) => c.type === "text-delta").map((c) => c.delta);
  assert.deepEqual(text, ["Second turn."]);
  const findings = chunks.filter((c) => c.type === "tool-input-available").map((c) => c.input.id);
  assert.deepEqual(findings, ["vuln-0002"]);
  const subagents = capabilities.filter((c) => c.id === "subagents").map((c) => c.subagent.name);
  assert.deepEqual(
    [...new Set(subagents)].sort(),
    ["Interrupted earlier", "Started now"],
    "an agent an earlier turn finished stays on that turn",
  );
  assert.equal(projection.turnUsage().inputTokens, 300);
  assert.equal(projection.turnUsage().cost, 0.5);
});

test("arguments start a scan of the checkout or resume the conversation's run", () => {
  const request = { projectPath: "/work/tree" };
  assert.deepEqual(
    strixArgs({
      request,
      configPath: "/s/c.json",
      instructionPath: "/s/i.md",
      options: {
        scan_mode: "deep",
        max_budget_usd: "5",
        targets: "https://staging.example.com, ./openapi.yaml",
      },
    }),
    [
      "-n",
      "--config",
      "/s/c.json",
      "--target",
      "/work/tree",
      "--target",
      "https://staging.example.com",
      "--target",
      "./openapi.yaml",
      "--scan-mode",
      "deep",
      "--scope-mode",
      "full",
      "--instruction-file",
      "/s/i.md",
      "--max-budget",
      "5",
    ],
  );
  // Changes only: diff scope against the worktree's base.
  const changes = strixArgs({
    request: { ...request, diffBase: "abc123" },
    configPath: "/s/c.json",
    options: { scope: "changes" },
  });
  assert.deepEqual(
    changes.slice(changes.indexOf("--scope-mode"), changes.indexOf("--scope-mode") + 4),
    ["--scope-mode", "diff", "--diff-base", "abc123"],
  );
  // A resumed run keeps its scan mode and scope; files and MCP servers apply
  // to every turn.
  assert.deepEqual(
    strixArgs({
      request,
      runName: "tree_1",
      configPath: "/s/c.json",
      options: { max_budget_usd: "nope", scan_mode: "deep", scope: "changes" },
      workspaceFiles: [{ path: "/s/a/1-spec.yaml", dest: "attached/1-spec.yaml" }],
      mcpConfig: "/home/op/.strix/mcp-servers.json",
    }),
    [
      "-n",
      "--config",
      "/s/c.json",
      "--resume",
      "tree_1",
      "--workspace-file",
      "/s/a/1-spec.yaml:attached/1-spec.yaml",
      "--mcp-config",
      "/home/op/.strix/mcp-servers.json",
    ],
  );
  assert.deepEqual(strixTargets(" a\nb ,c "), ["a", "b", "c"]);
});

test("Strix gets its credentials and Docker settings, never the turn token", () => {
  const env = strixEnvironment({
    env: {
      PATH: "/usr/bin",
      HOME: "/Users/op",
      DIETER_TURN_TOKEN: "secret-token",
      DIETER_HOME: "/Users/op/.dieter",
      LLM_API_KEY: "sk-test",
      LLM_API_BASE: "https://models.example/v1",
      DOCKER_HOST: "unix:///tmp/docker.sock",
      OPENAI_API_KEY: "sk-other",
      EXA_API_KEY: "exa-test",
    },
    request: { model: "openai/glm-5.3", effort: "high" },
    stateDir: "/state/card",
  });
  assert.equal(env.DIETER_TURN_TOKEN, undefined);
  assert.equal(env.DIETER_HOME, undefined);
  assert.equal(env.OPENAI_API_KEY, undefined);
  assert.equal(env.LLM_API_KEY, "sk-test");
  assert.equal(env.EXA_API_KEY, "exa-test", "web search keys reach Strix");
  assert.equal(env.HOME, "/state/card/home");
  assert.equal(env.DOCKER_CONFIG, "/Users/op/.docker");
  assert.equal(env.DOCKER_HOST, "unix:///tmp/docker.sock");
  assert.equal(env.STRIX_LLM, "openai/glm-5.3");
  assert.equal(env.STRIX_REASONING_EFFORT, "high");
  assert.equal(env.STRIX_TELEMETRY, "0");
  assert.match(env.STRIX_IMAGE, /^ghcr\.io\/usestrix\/strix-sandbox:1\.4\.1@sha256:[0-9a-f]{64}$/);
});

test("attachments become files in Strix's workspace, named in the instruction", async (t) => {
  const { frames, run, state, invocation } = await turnFixture(t);
  const spec = Buffer.from("openapi: 3.1.0\n").toString("base64");
  const code = await run(
    {
      prompt: "Test the API",
      attachments: [
        {
          mediaType: "application/yaml",
          filename: "open api.yaml",
          url: `data:application/yaml;base64,${spec}`,
        },
      ],
    },
    "complete",
  );
  assert.equal(code, 0, JSON.stringify(frames.filter((f) => f.type === "error")));
  const seen = await invocation();
  const spec_ = seen.args[seen.args.indexOf("--workspace-file") + 1];
  assert.match(spec_, /\/attachments\/msg_1\/1-open-api\.yaml:attached\/1-open-api\.yaml$/);
  assert.equal(await readFile(spec_.split(":")[0], "utf8"), "openapi: 3.1.0\n");
  assert.ok(spec_.startsWith(join(state, "attachments")), "attachments stay with the conversation");
  assert.match(
    seen.instruction,
    /^Test the API\n\nFiles attached to this message, in your workspace:\n- \/workspace\/attached\/1-open-api\.yaml\n$/,
  );
});

test("the operator's Strix MCP servers apply despite the private HOME", async (t) => {
  const { run, invocation, home } = await turnFixture(t);
  await mkdir(join(home, ".strix"), { recursive: true });
  await writeFile(join(home, ".strix", "mcp-servers.json"), "[]");
  assert.equal(await run({ prompt: "Scan" }, "complete"), 0);
  const seen = await invocation();
  assert.equal(
    seen.args[seen.args.indexOf("--mcp-config") + 1],
    join(home, ".strix", "mcp-servers.json"),
  );
});

test("console errors lose Strix's panel borders", () => {
  assert.equal(
    strixConsoleError(
      "╭─ STRIX ─╮\n│  Cannot connect to Docker  │\n│  Make sure Docker is running.  │\n╰────╯\n",
    ),
    "STRIX\nCannot connect to Docker\nMake sure Docker is running.",
  );
});

// A stand-in for the Strix executable: it records what it received and writes
// a run directory the way Strix does, driven by the fake-mode file in its
// working directory (Strix receives only allowlisted variables).
const fakeStrix = `#!/usr/bin/env node
const { mkdirSync, writeFileSync, readFileSync, existsSync } = require("node:fs");
const { join } = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const args = process.argv.slice(2);
const flag = (name) => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const config = flag("--config");
writeFileSync(join(process.cwd(), "invocation.json"), JSON.stringify({
  args, home: process.env.HOME, configExists: existsSync(config), config: readFileSync(config, "utf8"),
  instruction: flag("--instruction-file") ? readFileSync(flag("--instruction-file"), "utf8") : undefined,
  apiKey: process.env.LLM_API_KEY, token: process.env.DIETER_TURN_TOKEN,
}));
const mode = readFileSync(join(process.cwd(), "fake-mode"), "utf8").trim();
if (mode === "no-docker") {
  console.log("╭─ STRIX ─╮\\n│ Cannot connect to Docker │\\n╰─────╯");
  process.exit(1);
}
const runName = flag("--resume") || "tree_abcd";
const runDir = join(process.cwd(), "strix_runs", runName);
mkdirSync(join(runDir, ".state"), { recursive: true });
const record = (status) => writeFileSync(join(runDir, "run.json"), JSON.stringify({
  run_name: runName, status, llm_usage: { input_tokens: 10, output_tokens: 2, total_tokens: 12, cost: 0.01 },
}));
writeFileSync(join(runDir, ".state", "agents.json"), JSON.stringify({ statuses: { r: "running" }, parent_of: { r: null }, names: { r: "Root Agent" } }));
const db = new DatabaseSync(join(runDir, ".state", "agents.db"));
db.exec("CREATE TABLE IF NOT EXISTS agent_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, message_data TEXT)");
db.prepare("INSERT INTO agent_messages (session_id, message_data) VALUES (?, ?)").run("r", JSON.stringify({ type: "message", role: "assistant", content: [{ type: "output_text", text: "Scanning " + runName }] }));
db.close();
record("running");
const finish = (status, code) => { record(status); process.exit(code); };
process.on("SIGINT", () => finish("interrupted", 1));
if (mode === "complete") {
  writeFileSync(join(runDir, "vulnerabilities.json"), JSON.stringify([{ id: "vuln-0001", title: "Injection", severity: "high" }]));
  setTimeout(() => finish("completed", 2), 700);
} else if (mode === "self-interrupt") {
  setTimeout(() => finish("interrupted", 1), 700);
} else {
  setInterval(() => {}, 1000);
}
`;

async function turnFixture(t) {
  const root = await mkdtemp(join(tmpdir(), "strix-turn-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = join(root, "strix");
  await writeFile(executable, fakeStrix);
  await chmod(executable, 0o755);
  const project = join(root, "tree");
  await mkdir(project);
  const frames = [];
  const { collector } = recorder();
  const state = join(root, "runtime", "strix", "card1");
  const run = async (request, mode) => {
    await mkdir(state, { recursive: true });
    await writeFile(join(state, "fake-mode"), mode);
    return runStrixTurn({
      request: {
        sessionId: "card1",
        runtimeRoot: join(root, "runtime"),
        projectPath: project,
        responseMessageId: "msg_1",
        model: "openai/test",
        options: { scan_mode: "quick", max_budget_usd: "2" },
        ...request,
      },
      send: (frame) => frames.push(frame),
      collector,
      executable,
      env: {
        PATH: process.env.PATH,
        HOME: root,
        LLM_API_KEY: "sk-fake",
        DIETER_TURN_TOKEN: "token",
      },
    });
  };
  const invocation = async () => JSON.parse(await readFile(join(state, "invocation.json"), "utf8"));
  return { frames, run, state, invocation, home: root };
}

test("a completed turn ends with the report summary and the run's cursor", async (t) => {
  const { frames, run, state, invocation } = await turnFixture(t);
  const code = await run({ prompt: "Scan for injection" }, "complete");
  assert.equal(code, 0);
  const seen = await invocation();
  assert.ok(seen.args.includes("--scan-mode"));
  assert.equal(seen.instruction, "Scan for injection\n");
  assert.equal(seen.home, join(state, "home"));
  assert.ok(seen.configExists, "Strix gets a config file for the turn");
  assert.equal(seen.apiKey, "sk-fake");
  assert.equal(seen.token, undefined);
  assert.ok(!existsSync(join(state, "turn-config.json")), "the turn's config file is removed");
  assert.ok(
    !existsSync(join(state, "turn-instruction.md")),
    "the turn's instruction file is removed",
  );
  const chunks = frames.filter((f) => f.type === "chunk").map((f) => f.chunk);
  assert.equal(chunks[0].type, "start");
  assert.equal(chunks.at(-1).type, "finish");
  assert.ok(
    chunks.some((c) => c.type === "tool-input-available" && c.toolName === "strix_finding"),
  );
  const session = frames.find((f) => f.type === "session").state;
  assert.deepEqual(session.data, { strixRunName: "tree_abcd", lastRowId: 1 });
  assert.equal(session.continueFrom, undefined);
});

test("the next message resumes the same run with the message as its instruction", async (t) => {
  const { frames, run, invocation } = await turnFixture(t);
  await run({ prompt: "First" }, "complete");
  const session = frames.find((f) => f.type === "session").state;
  frames.length = 0;
  assert.equal(await run({ prompt: "Re-check /user", session }, "complete"), 0);
  const seen = await invocation();
  assert.deepEqual(
    seen.args.slice(seen.args.indexOf("--resume"), seen.args.indexOf("--resume") + 2),
    ["--resume", "tree_abcd"],
  );
  assert.ok(!seen.args.includes("--target"), "a resumed run keeps its targets");
  assert.equal(seen.instruction, "Re-check /user\n");
  const text = frames
    .filter((f) => f.type === "chunk" && f.chunk.type === "text-delta")
    .map((f) => f.chunk.delta);
  assert.equal(
    text.filter((value) => value.startsWith("Scanning")).length,
    1,
    "only the resumed run's new item shows; the first turn's is not replayed",
  );
});

test("Strix failing before it starts a run fails the turn with its console message", async (t) => {
  const { frames, run } = await turnFixture(t);
  assert.equal(await run({ prompt: "Scan" }, "no-docker"), 1);
  const error = frames.find((f) => f.type === "error");
  assert.match(error.error, /Cannot connect to Docker/);
});

test("an interrupted turn stays resumable and settles its agents", async (t) => {
  const { frames, run } = await turnFixture(t);
  const turn = run({ prompt: "Scan" }, "self-interrupt");
  // The daemon signals the worker's process group; Strix gets its own SIGINT.
  setTimeout(() => process.emit("SIGINT", "SIGINT"), 300);
  assert.equal(await turn, 130);
  const session = frames.find((f) => f.type === "session").state;
  assert.equal(session.data.strixRunName, "tree_abcd");
  assert.equal(session.continueFrom, undefined);
  assert.ok(!frames.some((f) => f.type === "error"));
});

test("a suspended turn stops Strix and continues the run after the restart", async (t) => {
  const { frames, run, state, invocation } = await turnFixture(t);
  const turn = run({ prompt: "Scan" }, "wait");
  // Suspend once Strix is running its scan (it has written its run record).
  const record = join(state, "strix_runs", "tree_abcd", "run.json");
  while (!existsSync(record)) await new Promise((resolve) => setTimeout(resolve, 25));
  await new Promise((resolve) => setTimeout(resolve, 100));
  process.emit("SIGUSR1", "SIGUSR1");
  assert.equal(await turn, 0);
  const session = frames.find((f) => f.type === "session").state;
  assert.deepEqual(session.continueFrom, { strix: true });
  frames.length = 0;
  assert.equal(await run({ prompt: "", continue: true, session }, "complete"), 0);
  const seen = await invocation();
  assert.ok(seen.args.includes("--resume"));
  assert.ok(!seen.args.includes("--instruction-file"), "a continuation sends no new message");
});
