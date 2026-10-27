import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createAntigravity } from "./antigravity-runtime.mjs";

// A stand-in for `agy` that records its arguments and stdin and replays the stream-json events
// observed from agy 1.4.8. Its behaviour is chosen with AGY_FIXTURE. No network, no credentials.
const fakeAgy = `
import { appendFileSync, readFileSync } from "node:fs";
const prompt = readFileSync(0, "utf8");
appendFileSync(process.env.AGY_LOG, JSON.stringify({ argv: process.argv.slice(2), prompt, cwd: process.cwd() }) + "\\n");
const out = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
const mode = process.env.AGY_FIXTURE || "ok";
if (mode === "quota") {
  process.stderr.write('AGY_ERROR: {"status":"RESOURCE_EXHAUSTED","short_error":"error: quota reached for gemini-4-argon. Resets in 3h12m"}\\n');
  out({ event: "result", result: { status: "ERROR", error: "quota reached for gemini-4-argon. Resets in 3h12m" } });
  process.exit(1);
}
if (mode === "hang") {
  out({ event: "init", conversation_id: "conv-hang", init: { cwd: process.cwd() } });
  setTimeout(() => {}, 60_000);
} else {
  out({ event: "init", conversation_id: process.argv.includes("--conversation") ? process.argv[process.argv.indexOf("--conversation") + 1] : "conv-1", init: { cwd: process.cwd(), tools: ["write_file"] } });
  out({ event: "step_update", step_update: { step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: "Hello " } });
  out({ event: "step_update", step_update: { step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: "there" } });
  out({ event: "step_update", step_update: { step_index: 1, state: "DONE", step_type: "agent_response" } });
  out({ event: "step_update", step_update: { step_index: 2, state: "ACTIVE", step_type: "tool", tool_name: "write_file", tool_info: { name: "write_file", parameters: { path: "a.txt" } } } });
  out({ event: "step_update", step_update: { step_index: 2, state: "DONE", step_type: "tool", tool_name: "write_file", tool_info: { name: "write_file", parameters: { path: "a.txt" }, output: "ok" } } });
  out({ event: "result", result: { status: "SUCCESS", response: "Hello there", usage: { input_tokens: 10, output_tokens: 4, thinking_tokens: 1, cache_read_tokens: 2, total_tokens: 14 } } });
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
  process.env.AGY_LOG = log;
  const calls = async () =>
    (await readFile(log, "utf8"))
      .trim()
      .split("\n")
      .map((l) => JSON.parse(l));
  return { root, command, calls };
}

async function runTurn(session, turn) {
  const events = [];
  const controller = new AbortController();
  const handle = await session.doPromptTurn({
    prompt: turn.prompt,
    instructions: turn.instructions,
    model: turn.model,
    tools: turn.tools,
    abortSignal: controller.signal,
    emit: (e) => events.push(e),
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
    model: "gemini-3.8-flash-high",
  });
  assert.equal(error, undefined);
  const text = events
    .filter((e) => e.type === "text-delta")
    .map((e) => e.delta)
    .join("");
  assert.equal(text, "Hello there");
  const call = events.find((e) => e.type === "tool-call");
  assert.equal(call.toolName, "write_file");
  assert.equal(call.providerExecuted, true);
  const result = events.find((e) => e.type === "tool-result");
  assert.equal(result.toolCallId, call.toolCallId);
  assert.equal(result.isError, false);
  const finish = events.find((e) => e.type === "finish");
  assert.equal(finish.finishReason.unified, "stop");
  assert.equal(finish.totalUsage.inputTokens.total, 10);
  assert.equal(finish.totalUsage.inputTokens.cacheRead, 2);
  assert.equal(finish.totalUsage.outputTokens.reasoning, 1);
  const [first] = await calls();
  assert.deepEqual(first.argv, [
    "--output-format",
    "stream-json",
    "--model",
    "gemini-3.8-flash-high",
    "--effort",
    "high",
    "--dangerously-skip-permissions",
  ]);
  assert.match(first.prompt, /^<instructions>\nBe brief\.\n<\/instructions>\n\nSay hello\n$/);
  assert.equal(first.cwd, root);
  // the second turn continues the conversation and does not repeat the instructions
  const second = await runTurn(session, {
    prompt: "And again",
    instructions: "Be brief.",
    model: "gemini-3.8-flash-high",
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

test("Antigravity: a quota failure becomes one plain sentence without stderr or a stack", async (t) => {
  const { root, command } = await fixture(t);
  process.env.AGY_FIXTURE = "quota";
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s4",
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
    sessionId: "s5",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  const started = Date.now();
  const { error } = await runTurn(session, { prompt: "hang", abortAfterMs: 300 });
  assert.ok(error);
  assert.match(error.message, /interrupted/);
  assert.ok(Date.now() - started < 10_000);
});

test("Antigravity: unsupported capabilities are reported as such", async (t) => {
  const { root, command } = await fixture(t);
  const harness = createAntigravity({ command });
  const session = await harness.doStart({
    sessionId: "s6",
    sessionWorkDir: root,
    permissionMode: "allow-all",
  });
  await assert.rejects(session.doSuspendTurn(), /cannot suspend/);
  await assert.rejects(session.doCompact(), /no manual compaction/);
  await assert.rejects(
    harness.doStart({ sessionId: "s7", sessionWorkDir: root, continueFrom: {} }),
    /cannot continue/,
  );
  await assert.rejects(
    harness.doStart({
      sessionId: "s8",
      sessionWorkDir: root,
      resumeFrom: { harnessId: "codex", data: {} },
    }),
    /belongs to harness 'codex'/,
  );
});
