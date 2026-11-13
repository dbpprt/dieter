import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createAntigravity } from "./antigravity-runtime.mjs";

const PROXY = fileURLToPath(new URL("./antigravity-host-tools.mjs", import.meta.url));

// A stand-in for `agy` that records its arguments and stdin and replays the stream-json events
// observed from agy 1.4.8. Its behaviour is chosen with AGY_FIXTURE. No network, no credentials.
// `agy mcp add …` (the host tools registration) is recorded and succeeds; in the "host-tool"
// fixture it drives the stdio MCP proxy like agy does and reports the call as a call_mcp_tool step.
const fakeAgy = `
import { appendFileSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import readline from "node:readline";
const argv = process.argv.slice(2);
const log = (entry) => appendFileSync(process.env.AGY_LOG, JSON.stringify(entry) + "\\n");
if (argv[0] === "mcp") {
  log({ argv, cwd: process.cwd() });
  process.exit(0);
}
const prompt = readFileSync(0, "utf8");
log({ argv, prompt, cwd: process.cwd(), tools: !!process.env.DIETER_AGY_TOOLS_URL });
const out = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
const arg = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
const usage = (input, output, thinking = 0, cached = 0) => ({ input_tokens: input, output_tokens: output, thinking_tokens: thinking, cache_read_tokens: cached, total_tokens: input + output });
const mode = process.env.AGY_FIXTURE || "ok";
const resume = arg("--conversation");
const conv = resume || "conv-1";
const step = (su) => out({ event: "step_update", step_update: { conversation_id: conv, ...su } });
if (mode === "quota") {
  process.stderr.write('AGY_ERROR: {"status":"RESOURCE_EXHAUSTED","short_error":"error: quota reached for gemini-4-argon. Resets in 3h12m"}\\n');
  out({ event: "result", result: { status: "ERROR", error: "quota reached for gemini-4-argon. Resets in 3h12m" } });
  process.exit(1);
}
if (mode === "lost" && resume) {
  process.stderr.write('warning: conversation "' + resume + '" not found\\n');
  out({ event: "init", conversation_id: "conv-fresh", init: { cwd: process.cwd() } });
  setTimeout(() => {}, 60_000); // the adapter stops this run
} else if (mode === "hang") {
  out({ event: "init", conversation_id: "conv-hang", init: { cwd: process.cwd() } });
  step({ step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: "working" });
  setTimeout(() => {}, 60_000);
} else {
  out({ event: "init", conversation_id: conv, init: { cwd: process.cwd(), tools: ["write_file"], permission_mode: argv.includes("--dangerously-skip-permissions") ? "always-proceed" : "request-review" } });
  step({ step_index: 0, state: "DONE", step_type: "user_input" });
  if (prompt.startsWith("/compact")) {
    step({ step_index: 1, state: "DONE", step_type: "system_message" });
    step({ step_index: 2, state: "DONE", step_type: "checkpoint", duration_seconds: 1 });
    out({ event: "result", result: { conversation_id: conv, status: "SUCCESS", response: "", usage: usage(0, 0) } });
  } else {
    (async () => {
      step({ step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: "Hello " });
      step({ step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: "there" });
      step({ step_index: 1, state: "DONE", step_type: "agent_response", usage: usage(100, 10, 1, 2) });
      if (mode === "host-tool") {
        const proxy = spawn(process.execPath, [process.env.AGY_PROXY], { stdio: ["pipe", "pipe", "inherit"] });
        const lines = readline.createInterface({ input: proxy.stdout });
        const waiting = new Map();
        lines.on("line", (l) => { const m = JSON.parse(l); waiting.get(m.id)?.(m); });
        let id = 0;
        const request = (method, params) => new Promise((resolve) => { waiting.set(++id, resolve); proxy.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\\n"); });
        const init = await request("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "fake-agy", version: "0" } });
        proxy.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\\n");
        const list = await request("tools/list", {});
        const schema = { Path: "/home/u/.gemini/antigravity-cli/mcp/dieter/present_content.json" };
        step({ step_index: 2, state: "ACTIVE", step_type: "tool", tool_name: "read_file", tool_info: { name: "read_file", parameters: schema } });
        step({ step_index: 2, state: "DONE", step_type: "tool", tool_name: "read_file", tool_info: { name: "read_file", parameters: schema, output: "1 lines" } });
        const params = { ServerName: "dieter", ToolName: "present_content", Arguments: { path: "a.md" } };
        step({ step_index: 3, state: "ACTIVE", step_type: "tool", tool_name: "call_mcp_tool", tool_info: { name: "call_mcp_tool", parameters: params } });
        const call = await request("tools/call", { name: "present_content", arguments: { path: "a.md" } });
        proxy.stdin.end();
        log({ mcp: { init: init.result, tools: list.result.tools, call: call.result } });
        step({ step_index: 3, state: "DONE", step_type: "tool", tool_name: "call_mcp_tool", duration_seconds: 0.1, tool_info: { name: "call_mcp_tool", parameters: params, output: call.result.content[0].text } });
      } else {
        step({ step_index: 2, state: "ACTIVE", step_type: "tool", tool_name: "write_file", tool_info: { name: "write_file", parameters: { path: "a.txt" } } });
        step({ step_index: 2, state: "DONE", step_type: "tool", tool_name: "write_file", tool_info: { name: "write_file", parameters: { path: "a.txt" }, output: "ok" } });
      }
      step({ step_index: 4, state: "ACTIVE", step_type: "agent_response", text_delta: "Done" });
      step({ step_index: 4, state: "DONE", step_type: "agent_response", text_delta: ".", usage: usage(150, 5) });
      out({ event: "result", result: { conversation_id: conv, status: "SUCCESS", response: "Hello there Done.", usage: { input_tokens: 10, output_tokens: 4, thinking_tokens: 1, cache_read_tokens: 2, total_tokens: 14 } } });
    })();
  }
}
`;

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "dieter-antigravity-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const script = join(root, "fake-agy.mjs");
  await writeFile(script, fakeAgy);
  const command = join(root, "agy");
  await writeFile(command, `#!/bin/sh\nexec "${process.execPath}" "${script}" "$@"\n`);
  await chmod(command, 0o755);
  const log = join(root, "calls.jsonl");
  await writeFile(log, "");
  process.env.AGY_LOG = log;
  process.env.AGY_PROXY = PROXY;
  const calls = async () =>
    (await readFile(log, "utf8"))
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((l) => JSON.parse(l));
  return { root, command, calls };
}

async function runTurn(session, turn) {
  const events = [];
  const controller = new AbortController();
  let handle;
  handle = await session.doPromptTurn({
    prompt: turn.prompt,
    instructions: turn.instructions,
    model: turn.model,
    tools: turn.tools,
    abortSignal: controller.signal,
    emit: (e) => {
      events.push(e);
      turn.onEvent?.(e, handle);
    },
  });
  if (turn.abortAfterMs) setTimeout(() => controller.abort(), turn.abortAfterMs);
  let error;
  try {
    await handle.done;
  } catch (e) {
    error = e;
  }
  return { events, error };
}

const types = (events) => events.map((e) => e.type);

test("Antigravity: a turn streams text, provider-executed tools and usage, and keeps the conversation id", async (t) => {
  const { root, command, calls } = await fixture(t);
  process.env.AGY_FIXTURE = "ok";
  const harness = createAntigravity({ command, effort: "high" });
  const session = await harness.doStart({
    sessionId: "s1",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  const { events, error } = await runTurn(session, {
    prompt: "Say hello",
    instructions: "Be brief.",
    model: "gemini-4-argon",
  });
  assert.equal(error, undefined);
  const text = events
    .filter((e) => e.type === "text-delta")
    .map((e) => e.delta)
    .join("");
  assert.equal(text, "Hello thereDone.");
  const call = events.find((e) => e.type === "tool-call");
  assert.equal(call.toolName, "write_file");
  assert.equal(call.providerExecuted, true);
  const result = events.find((e) => e.type === "tool-result");
  assert.equal(result.toolCallId, call.toolCallId);
  assert.equal(result.isError, false);
  // each model request closes a step with its own usage (the context it saw); the turn total is agy's sum
  const steps = events.filter((e) => e.type === "finish-step");
  assert.equal(steps.length, 2);
  assert.deepEqual(steps[0].finishReason, { unified: "tool-calls", raw: "tool-calls" });
  assert.equal(steps[0].usage.inputTokens.total, 100);
  assert.equal(steps[0].usage.inputTokens.cacheRead, 2);
  assert.equal(steps[0].usage.outputTokens.reasoning, 1);
  assert.deepEqual(steps[1].finishReason, { unified: "stop", raw: "SUCCESS" });
  assert.equal(steps[1].usage.inputTokens.total, 150);
  assert.ok(types(events).indexOf("finish-step") < types(events).indexOf("text-start", 2));
  const finish = events.find((e) => e.type === "finish");
  assert.equal(finish.finishReason.unified, "stop");
  assert.equal(finish.totalUsage.inputTokens.total, 10);
  assert.equal(finish.totalUsage.inputTokens.cacheRead, 2);
  assert.equal(finish.totalUsage.outputTokens.reasoning, 1);
  assert.ok(
    !events.some((e) => e.type === "raw"),
    "agy's housekeeping steps are not passed through",
  );
  const [first] = await calls();
  assert.deepEqual(first.argv, [
    "--output-format",
    "stream-json",
    "--model",
    "gemini-4-argon",
    "--effort",
    "high",
    "--dangerously-skip-permissions",
  ]);
  assert.match(first.prompt, /^<instructions>\nBe brief\.\n<\/instructions>\n\nSay hello\n$/);
  assert.equal(first.cwd, root);
  assert.equal(first.tools, false);
  // the second turn continues the conversation and does not repeat the instructions
  const second = await runTurn(session, {
    prompt: "And again",
    instructions: "Be brief.",
    model: "gemini-4-argon",
  });
  assert.equal(second.error, undefined);
  const [, next] = await calls();
  assert.ok(
    next.argv.includes("--conversation") &&
      next.argv[next.argv.indexOf("--conversation") + 1] === "conv-1",
  );
  assert.equal(next.prompt, "And again\n");
  const state = await session.doStop();
  assert.equal(state.type, "resume-session");
  assert.equal(state.data.conversationId, "conv-1");
  assert.equal(state.data.instructionsApplied, true);
  // a resumed session starts from that state
  const resumed = await harness.doStart({
    sessionId: "s1",
    sessionWorkDir: root,
    permissionMode: "allow-all",
    resumeFrom: state,
  });
  assert.equal(resumed.isResume, true);
  await runTurn(resumed, { prompt: "Still there?", instructions: "Be brief." });
  const [, , third] = await calls();
  assert.ok(third.argv.includes("--conversation"));
  assert.equal(third.prompt, "Still there?\n");
});

test("Antigravity: a model id with its own level is run without --effort", async (t) => {
  const { root, command, calls } = await fixture(t);
  process.env.AGY_FIXTURE = "ok";
  const harness = createAntigravity({ command, effort: "xhigh" });
  const session = await harness.doStart({
    sessionId: "s1b",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  await runTurn(session, { prompt: "hi", model: "gemini-3.8-flash-high" });
  const [call] = await calls();
  assert.ok(!call.argv.includes("--effort"));
  assert.ok(call.argv.includes("gemini-3.8-flash-high"));
});

test("Antigravity: permission prompts are skipped only in allow-all mode", async (t) => {
  const { root, command, calls } = await fixture(t);
  process.env.AGY_FIXTURE = "ok";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s2",
    sessionWorkDir: root,
    permissionMode: "ask",
  });
  await runTurn(session, { prompt: "hi" });
  const [call] = await calls();
  assert.ok(!call.argv.includes("--dangerously-skip-permissions"));
  const unset = await harness.doStart({ sessionId: "s3", sessionWorkDir: root });
  await runTurn(unset, { prompt: "hi" });
  const [, second] = await calls();
  assert.ok(!second.argv.includes("--dangerously-skip-permissions"));
});

test("Antigravity: host tools reach agy through the MCP proxy and come back as host tool calls", async (t) => {
  const { root, command, calls } = await fixture(t);
  process.env.AGY_FIXTURE = "host-tool";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s4",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  const tools = [
    {
      name: "present_content",
      description: "Show a file.",
      inputSchema: { type: "object", properties: { path: { type: "string" } } },
    },
  ];
  let hostCall;
  const { events, error } = await runTurn(session, {
    prompt: "show a.md",
    model: "gemini-4-argon",
    tools,
    // the host executes the tool when its call shows up and answers like the harness agent does
    onEvent: (e, handle) => {
      if (e.type !== "tool-call" || e.providerExecuted) return;
      hostCall = e;
      void handle.submitToolResult({
        toolCallId: e.toolCallId,
        output: { requested: true },
        toolResult: {
          type: "tool-result",
          toolCallId: e.toolCallId,
          toolName: "present_content",
          output: { type: "json", value: { requested: true } },
        },
      });
    },
  });
  assert.equal(error, undefined);
  const [registration, run, mcp] = await calls();
  assert.deepEqual(registration.argv, ["mcp", "add", "dieter", process.execPath, PROXY]);
  assert.equal(run.tools, true);
  assert.equal(mcp.mcp.init.protocolVersion, "2025-11-25");
  assert.deepEqual(mcp.mcp.tools, [
    { name: "present_content", description: "Show a file.", inputSchema: tools[0].inputSchema },
  ]);
  assert.deepEqual(mcp.mcp.call, {
    content: [{ type: "text", text: '{"requested":true}' }],
    isError: false,
  });
  assert.equal(hostCall.toolName, "present_content");
  assert.deepEqual(JSON.parse(hostCall.input), { path: "a.md" });
  const echo = events.find((e) => e.type === "tool-result" && e.toolCallId === hostCall.toolCallId);
  assert.equal(echo.providerExecuted, false);
  assert.deepEqual(echo.result, { requested: true });
  assert.ok(
    !events.some((e) => e.toolName === "call_mcp_tool"),
    "agy's MCP step is not shown twice",
  );
  assert.ok(
    !events.some((e) => e.toolName === "read_file"),
    "agy's read of the tool schema is hidden",
  );
  assert.equal(events[0].type, "stream-start");
  assert.equal(events[0].warnings, undefined);
  // the registration happens once per process
  process.env.AGY_FIXTURE = "ok";
  await runTurn(session, { prompt: "again", model: "gemini-4-argon", tools });
  assert.equal((await calls()).filter((c) => c.argv?.[0] === "mcp").length, 1);
  await session.doStop();
});

test("Antigravity: the MCP proxy offers no tools outside a Dieter turn", async () => {
  const proxy = spawn(process.execPath, [PROXY], {
    env: { ...process.env, DIETER_AGY_TOOLS_URL: "", DIETER_AGY_TOOLS_TOKEN: "" },
    stdio: ["pipe", "pipe", "inherit"],
  });
  let out = "";
  proxy.stdout.on("data", (c) => (out += c));
  proxy.stdin.write(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}\n',
  );
  proxy.stdin.write('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n');
  proxy.stdin.write('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"x"}}\n');
  proxy.stdin.end();
  await new Promise((r) => proxy.on("close", r));
  const replies = out
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
  assert.equal(replies.find((r) => r.id === 1).result.protocolVersion, "2025-03-26");
  assert.deepEqual(replies.find((r) => r.id === 2).result, { tools: [] });
  assert.equal(replies.find((r) => r.id === 3).result.isError, true);
});

test("Antigravity: a conversation agy no longer has is restarted with the instructions and a note", async (t) => {
  const { root, command, calls } = await fixture(t);
  process.env.AGY_FIXTURE = "lost";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s5",
    sessionWorkDir: root,
    permissionMode: "allow-all",
    resumeFrom: {
      type: "resume-session",
      harnessId: "antigravity",
      data: { conversationId: "conv-old", instructionsApplied: true },
    },
  });
  const { events, error } = await runTurn(session, { prompt: "hi", instructions: "Be brief." });
  assert.equal(error, undefined);
  const [first, second] = await calls();
  assert.ok(first.argv.includes("conv-old"));
  assert.equal(first.prompt, "hi\n");
  assert.ok(!second.argv.includes("--conversation"));
  assert.match(second.prompt, /^<instructions>\nBe brief\.\n<\/instructions>\n\nhi\n$/);
  assert.ok(
    events.some(
      (e) => e.type === "text-delta" && /no longer has the stored conversation/.test(e.delta),
    ),
  );
  assert.equal(types(events).filter((type) => type === "stream-start").length, 1);
  assert.equal(types(events).at(-1), "finish");
  const state = await session.doDetach();
  assert.deepEqual(state.data, { conversationId: "conv-1", instructionsApplied: true });
});

test("Antigravity: a quota failure becomes one plain sentence without stderr or a stack", async (t) => {
  const { root, command } = await fixture(t);
  process.env.AGY_FIXTURE = "quota";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s6",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  const { events, error } = await runTurn(session, { prompt: "hi" });
  assert.ok(error);
  assert.equal(
    error.message,
    "Antigravity has no quota left for this model (resets in 3h12m). Pick another model (e.g. Gemini 3.8 Flash) or try again later.",
  );
  assert.equal(error.stack, error.message);
  assert.ok(!/AGY_ERROR/.test(error.message));
  const finish = events.find((e) => e.type === "finish");
  assert.equal(finish.finishReason.unified, "error");
});

test("Antigravity: aborting a turn stops the agy process", async (t) => {
  const { root, command } = await fixture(t);
  process.env.AGY_FIXTURE = "hang";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s7",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  const started = Date.now();
  const { events, error } = await runTurn(session, { prompt: "hang", abortAfterMs: 300 });
  assert.ok(error);
  assert.match(error.message, /interrupted/);
  assert.ok(Date.now() - started < 10_000);
  assert.ok(
    events.some((e) => e.type === "text-end"),
    "open parts are closed",
  );
});

test("Antigravity: compaction runs agy's /compact on the stored conversation", async (t) => {
  const { root, command, calls } = await fixture(t);
  process.env.AGY_FIXTURE = "ok";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s8",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  await session.doCompact(); // nothing stored yet: nothing to do
  assert.equal((await calls()).length, 0);
  await runTurn(session, { prompt: "hi" });
  await session.doCompact();
  const [, compact] = await calls();
  assert.deepEqual(compact.argv, ["--output-format", "stream-json", "--conversation", "conv-1"]);
  assert.equal(compact.prompt, "/compact\n");
});

test("Antigravity: unsupported capabilities are reported as such", async (t) => {
  const { root, command } = await fixture(t);
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s9",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  await assert.rejects(session.doSuspendTurn(), /cannot suspend/);
  await assert.rejects(session.doContinueTurn(), /cannot continue/);
  await assert.rejects(
    harness.doStart({ sessionId: "s10", sessionWorkDir: root, continueFrom: {} }),
    /cannot continue/,
  );
  await assert.rejects(
    harness.doStart({
      sessionId: "s11",
      sessionWorkDir: root,
      resumeFrom: { harnessId: "codex", data: {} },
    }),
    /belongs to harness 'codex'/,
  );
});
