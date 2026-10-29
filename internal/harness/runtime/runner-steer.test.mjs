import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const runnerURL = new URL("./runner.mjs", import.meta.url).href;
const dataURL = (source) => `data:text/javascript,${encodeURIComponent(source)}`;

// A deterministic provider boundary: the stream waits until the session is
// steered (or the fixture mode rejects the steer) and then echoes the text.
const agentFixture = `
export const getHarnessErrorMessage = error => error.message;
let release;
const steered = new Promise(resolve => { release = resolve; });
export class HarnessAgent {
  async createSession() {
    return {
      experimental_steerTurn: async text => {
        const mode = process.env.FIXTURE_STEER;
        if (mode === 'unsupported') {
          const error = new Error("Harness 'fixture' does not support steering active turns.");
          error.name = 'HarnessCapabilityUnsupportedError';
          release('');
          throw error;
        }
        if (mode === 'ended') { release(''); throw new Error('Harness session x has no running turn to steer.'); }
        release(text);
      },
      stop: async () => ({ type: 'resume-session', data: {} }),
    };
  }
  async stream() {
    return {stream: new ReadableStream({async start(controller) {
      controller.enqueue({type: 'start', messageId: 'response'});
      process.stderr.write('fixture-ready\\n');
      const text = await steered;
      controller.enqueue({type: 'text-start', id: 't'});
      controller.enqueue({type: 'text-delta', id: 't', delta: 'steered: ' + text});
      controller.enqueue({type: 'text-end', id: 't'});
      controller.enqueue({type: 'finish', finishReason: 'stop'});
      controller.close();
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

async function runSteered(
  t,
  { mode = "", steerEnabled = true, harness = "claude-code", prompt = "Work", early = false } = {},
) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "dieter-worker-steer-")));
  await mkdir(join(root, "project"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const request = {
    harness,
    adapter: harness,
    sessionId: "steer-test",
    projectPath: join(root, "project"),
    runtimeRoot: join(root, "runtime"),
    prompt,
    responseMessageId: "response",
    steerEnabled,
  };
  const child = spawn(process.execPath, ["--import", preload, fileURLToPath(runnerURL)], {
    env: { PATH: process.env.PATH, HOME: root, TMPDIR: root, FIXTURE_STEER: mode },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const closed = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => resolve(code));
  });
  const timeout = setTimeout(() => child.kill("SIGKILL"), 30_000);
  t.after(async () => {
    clearTimeout(timeout);
    if (child.exitCode == null && child.signalCode == null) child.kill("SIGKILL");
    await closed;
  });
  let stdout = "",
    stderr = "",
    steered = false;
  const steer = () => {
    if (steered) return;
    steered = true;
    child.stdin.write(
      `${JSON.stringify({ type: "steer", id: "steer-1", text: "release tag PAPAYA-7" })}\n`,
    );
  };
  child.stdout.on("data", (data) => {
    stdout += data;
    // The mock harness announces readiness with its start chunk.
    if (harness === "mock" && stdout.includes('"type":"start"')) steer();
  });
  child.stderr.on("data", (data) => {
    stderr += data;
    if (stderr.includes("fixture-ready")) steer();
  });
  child.stdin.write(`${JSON.stringify(request)}\n`);
  // A daemon may steer while the worker is still starting its session.
  if (early) steer();
  const code = await closed;
  clearTimeout(timeout);
  const frames = stdout
    .trim()
    .split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line));
  return { code, frames, stderr };
}

test(
  "a steer frame reaches the running turn and is acknowledged",
  { timeout: 60_000 },
  async (t) => {
    const { code, frames, stderr } = await runSteered(t);
    assert.equal(code, 0, stderr);
    assert.deepEqual(
      frames.find((frame) => frame.type === "steer-result"),
      { type: "steer-result", id: "steer-1", accepted: true },
    );
    assert(
      frames.some((frame) => frame.chunk?.delta === "steered: release tag PAPAYA-7"),
      stderr,
    );
  },
);

test("a harness without steering answers unsupported", { timeout: 60_000 }, async (t) => {
  const { code, frames, stderr } = await runSteered(t, { mode: "unsupported" });
  assert.equal(code, 0, stderr);
  assert.deepEqual(
    frames.find((frame) => frame.type === "steer-result"),
    { type: "steer-result", id: "steer-1", accepted: false, reason: "unsupported" },
  );
});

test("a steer after the turn ended answers no-running-turn", { timeout: 60_000 }, async (t) => {
  const { frames } = await runSteered(t, { mode: "ended" });
  assert.deepEqual(
    frames.find((frame) => frame.type === "steer-result"),
    { type: "steer-result", id: "steer-1", accepted: false, reason: "no-running-turn" },
  );
});

test("the mock harness accepts one steer for daemon tests", { timeout: 60_000 }, async (t) => {
  const { code, frames, stderr } = await runSteered(t, {
    harness: "mock",
    prompt: "digest\n\nmock-channel-steer",
  });
  assert.equal(code, 0, stderr);
  assert.equal(frames.find((frame) => frame.type === "steer-result")?.accepted, true, stderr);
  assert(frames.some((frame) => frame.chunk?.delta === "Mock steered: release tag PAPAYA-7"));
});

test(
  "a steer that arrives during worker startup waits for the session",
  { timeout: 60_000 },
  async (t) => {
    const { code, frames, stderr } = await runSteered(t, { early: true });
    assert.equal(code, 0, stderr);
    assert.deepEqual(
      frames.find((frame) => frame.type === "steer-result"),
      { type: "steer-result", id: "steer-1", accepted: true },
    );
    assert(frames.some((frame) => frame.chunk?.delta === "steered: release tag PAPAYA-7"));
  },
);

test("the mock harness accepts a steer sent before it is ready", { timeout: 60_000 }, async (t) => {
  const { code, frames, stderr } = await runSteered(t, {
    harness: "mock",
    prompt: "mock-channel-steer",
    early: true,
  });
  assert.equal(code, 0, stderr);
  assert.equal(frames.find((frame) => frame.type === "steer-result")?.accepted, true, stderr);
});
