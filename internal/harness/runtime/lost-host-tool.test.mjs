import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createLostHostToolDetector,
  lostHostToolFailure,
  lostHostToolPrompt,
} from "./lost-host-tool.mjs";

function clock() {
  let current = 1_000_000;
  return { now: () => current, advance: (ms) => (current += ms) };
}

test("a host tool whose call never reaches the worker is lost after the timeout", () => {
  const time = clock();
  const detector = createLostHostToolDetector({ timeoutMs: 60_000, now: time.now });
  detector.observe({
    type: "tool-input-start",
    id: "toolu_bash",
    toolName: "bash",
    providerExecuted: true,
  });
  detector.observe({ type: "tool-input-end", id: "toolu_bash" });
  detector.observe({
    type: "tool-input-start",
    id: "toolu_list",
    toolName: "list_background_processes",
    providerExecuted: false,
  });
  detector.observe({ type: "tool-input-delta", id: "toolu_list", delta: "" });
  detector.observe({ type: "tool-input-end", id: "toolu_list" });
  time.advance(59_000);
  assert.equal(detector.lost(), undefined);
  time.advance(1_000);
  assert.deepEqual(detector.lost(), {
    toolCallId: "toolu_list",
    toolName: "list_background_processes",
  });
});

test("a dispatched host tool is never lost, however long it runs", () => {
  const time = clock();
  const detector = createLostHostToolDetector({ timeoutMs: 60_000, now: time.now });
  detector.observe({
    type: "tool-input-start",
    id: "toolu_review",
    toolName: "request_code_review",
    providerExecuted: false,
  });
  detector.observe({ type: "tool-input-end", id: "toolu_review" });
  detector.observe({
    type: "tool-call",
    toolCallId: "toolu_review",
    toolName: "request_code_review",
  });
  time.advance(10 * 60_000);
  detector.observe({
    type: "raw",
    rawValue: {
      type: "tool_progress",
      tool_name: "mcp__harness-tools__request_code_review",
      parent_tool_use_id: "toolu_review",
      elapsed_time_seconds: 600,
    },
  });
  assert.equal(detector.lost(), undefined);
});

test("a heartbeat without a parent id still names the dispatched call", () => {
  const time = clock();
  const detector = createLostHostToolDetector({ timeoutMs: 60_000, now: time.now });
  detector.observe({
    type: "tool-call",
    toolCallId: "toolu_review",
    toolName: "request_code_review",
  });
  detector.observe({
    type: "raw",
    rawValue: {
      type: "tool_progress",
      tool_use_id: "toolu_review-heartbeat-12",
      tool_name: "mcp__harness-tools__request_code_review",
      elapsed_time_seconds: 360,
    },
  });
  assert.equal(detector.lost(), undefined);
});

test("Claude Code's heartbeat alone reveals a lost call and dates it", () => {
  const time = clock();
  const detector = createLostHostToolDetector({ timeoutMs: 60_000, now: time.now });
  const heartbeat = (tool, elapsed) => ({
    type: "raw",
    rawValue: {
      type: "tool_progress",
      tool_use_id: "toolu_x-heartbeat-1",
      tool_name: tool,
      parent_tool_use_id: "toolu_x",
      elapsed_time_seconds: elapsed,
      heartbeat: true,
    },
  });
  // Built-in and external MCP tools are Claude Code's own.
  detector.observe(heartbeat("Agent", 600));
  detector.observe(heartbeat("mcp__github__search", 600));
  assert.equal(detector.lost(), undefined);
  detector.observe(heartbeat("mcp__harness-tools__list_background_processes", 90));
  assert.deepEqual(detector.lost(), {
    toolCallId: "toolu_x",
    toolName: "list_background_processes",
  });
});

// The real worker with a deterministic provider boundary: the first
// FIXTURE_LOST streams start a host tool call that never reaches the worker
// (Claude Code keeps reporting it as running) and end only when aborted.
const runnerURL = new URL("./runner.mjs", import.meta.url).href;
const dataURL = (source) => `data:text/javascript,${encodeURIComponent(source)}`;
const agentFixture = `
export const getHarnessErrorMessage = error => error.message;
let streams = 0;
export class HarnessAgent {
  async createSession() {
    const state = () => ({type: 'resume-session', data: {claudeSessionId: 'fixture'}});
    return {detach: async () => state(), stop: async () => state()};
  }
  async stream({prompt, abortSignal}) {
    streams += 1;
    process.stderr.write('fixture-prompt:' + JSON.stringify(prompt) + '\\n');
    const losing = streams <= Number(process.env.FIXTURE_LOST);
    return {stream: new ReadableStream({start: controller => {
      controller.enqueue({type: 'start', messageId: 'response'});
      if (!losing) {
        controller.enqueue({type: 'text-delta', id: 'text-' + streams, delta: 'recovered'});
        controller.enqueue({type: 'finish', finishReason: 'stop'});
        controller.close();
        return;
      }
      const id = 'toolu_lost_' + streams;
      controller.enqueue({type: 'text-delta', id: 'text-' + streams, delta: 'checking processes'});
      controller.enqueue({type: 'tool-input-start', id, toolName: 'list_background_processes', providerExecuted: false});
      controller.enqueue({type: 'tool-input-delta', id, delta: ''});
      controller.enqueue({type: 'tool-input-end', id});
      const heartbeat = setInterval(() => controller.enqueue({type: 'raw', rawValue: {
        type: 'tool_progress', tool_use_id: id + '-heartbeat', tool_name: 'mcp__harness-tools__list_background_processes',
        parent_tool_use_id: id, elapsed_time_seconds: 1, heartbeat: true}}), 50);
      abortSignal.addEventListener('abort', () => {
        clearInterval(heartbeat);
        controller.enqueue({type: 'abort'});
        controller.close();
      }, {once: true});
    }})};
  }
}
`;
const preload = dataURL(`
import { registerHooks } from 'node:module';
const replacements = ${JSON.stringify({
  "@ai-sdk/harness/agent": dataURL(agentFixture),
  ai: dataURL(
    "export const tool = value => value; export const toUIMessageStream = ({stream}) => stream;",
  ),
})};
registerHooks({resolve(specifier, context, next) {
  if (context.parentURL === ${JSON.stringify(runnerURL)} && replacements[specifier]) {
    return {url: replacements[specifier], shortCircuit: true};
  }
  return next(specifier, context);
}});
`);

async function runWorker(t, lost) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "dieter-lost-host-tool-")));
  await mkdir(join(root, "project"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const request = {
    harness: "claude-code",
    adapter: "claude-code",
    sessionId: "lost-host-tool-test",
    projectPath: join(root, "project"),
    runtimeRoot: join(root, "runtime"),
    prompt: "Research",
    responseMessageId: "response",
    hostToolDispatchTimeoutMs: 300,
  };
  const child = spawn(process.execPath, ["--import", preload, fileURLToPath(runnerURL)], {
    env: { PATH: process.env.PATH, HOME: root, TMPDIR: root, FIXTURE_LOST: String(lost) },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const closed = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => resolve(code));
  });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 30_000);
  t.after(() => {
    clearTimeout(timeout);
    if (child.exitCode == null) child.kill("SIGKILL");
  });
  let stdout = "",
    stderr = "";
  child.stdout.on("data", (data) => {
    stdout += data;
  });
  child.stderr.on("data", (data) => {
    stderr += data;
  });
  child.stdin.write(`${JSON.stringify(request)}\n`);
  const code = await closed;
  const frames = stdout
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const prompts = [...stderr.matchAll(/^fixture-prompt:(.*)$/gm)].map((match) =>
    JSON.parse(match[1]),
  );
  return { code, frames, prompts, stderr };
}

const chunks = (frames) =>
  frames.filter((frame) => frame.type === "chunk").map((frame) => frame.chunk);

test(
  "a lost host tool call stops the stream and resumes the session in the same response",
  { timeout: 40_000 },
  async (t) => {
    const result = await runWorker(t, 1);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.prompts, ["Research", lostHostToolPrompt("list_background_processes")]);
    const stream = chunks(result.frames);
    assert.equal(
      stream.filter((chunk) => chunk.type === "start").length,
      1,
      JSON.stringify(stream),
    );
    assert(
      !stream.some((chunk) => chunk.type === "abort" || chunk.type === "error"),
      JSON.stringify(stream),
    );
    const text = stream.filter((chunk) => chunk.type === "text-delta").map((chunk) => chunk.delta);
    assert.equal(text[0], "checking processes");
    assert.match(text[1], /^Claude Code lost the call to list_background_processes/);
    assert.equal(text[2], "recovered");
    assert.equal(stream.at(-1).type, "finish");
    assert.match(
      result.stderr,
      /lost the list_background_processes host tool call; resuming the session \(1\/2\)/,
    );
  },
);

test(
  "a call lost three times fails the turn with the preserved session",
  { timeout: 40_000 },
  async (t) => {
    const result = await runWorker(t, 3);
    assert.equal(result.prompts.length, 3);
    const errors = result.frames.filter((frame) => frame.type === "error");
    assert.equal(errors.length, 1, JSON.stringify(result.frames));
    assert.equal(errors[0].error, lostHostToolFailure("list_background_processes"));
    assert.notEqual(result.code, 0);
  },
);
