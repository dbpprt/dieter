import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const runnerURL = new URL("./runner.mjs", import.meta.url).href;
const dataURL = (source) => `data:text/javascript,${encodeURIComponent(source)}`;

// The adapter factories report the options a turn hands them, so a test sees
// whether the provider account's `auth` object reached them.
const factory = (name, adapter) => `
export function ${name}(options) {
  process.stderr.write('fixture-factory:' + JSON.stringify({adapter: ${JSON.stringify(adapter)}, options}) + '\\n');
  return {fixture: ${JSON.stringify(adapter)}};
}
`;

// A deterministic provider boundary. FIXTURE_PARTS is the JSON list of parts
// every stream yields; the first FIXTURE_FAILURES streams end in Claude
// Code's terminal 401 instead.
const agentFixture = `
export const getHarnessErrorMessage = error => error.message;
let streams = 0;
export class HarnessAgent {
  async createSession() {
    const state = () => ({type: 'resume-session', data: {claudeSessionId: 'fixture'}});
    return {detach: async () => state(), stop: async () => state()};
  }
  async stream() {
    streams += 1;
    const failing = streams <= Number(process.env.FIXTURE_FAILURES || 0);
    const parts = JSON.parse(process.env.FIXTURE_PARTS || '[]');
    return {stream: new ReadableStream({start: controller => {
      controller.enqueue({type: 'start', messageId: 'response'});
      if (failing) {
        controller.enqueue({type: 'error', errorText: 'HTTP 401: authentication_failed'});
      } else {
        for (const part of parts) controller.enqueue(part);
        controller.enqueue({type: 'text-delta', id: 'text', delta: 'answered'});
        controller.enqueue({type: 'finish', finishReason: 'stop'});
      }
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
  "./claude-runtime.mjs": dataURL(factory("createLocalClaudeCode", "claude-code")),
  "./codex-runtime.mjs": dataURL(factory("createLocalCodex", "codex")),
})};
registerHooks({resolve(specifier, context, next) {
  if (context.parentURL === ${JSON.stringify(runnerURL)} && replacements[specifier]) {
    return {url: replacements[specifier], shortCircuit: true};
  }
  return next(specifier, context);
}});
`);

async function runWorker(t, { adapter, auth, parts = [], failures = 0 }) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "dieter-provider-accounts-")));
  await mkdir(join(root, "project"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const request = {
    harness: adapter,
    adapter,
    model: adapter === "codex" ? "gpt-5.5" : "sonnet",
    contextWindow: 200000,
    sessionId: "provider-accounts-test",
    projectPath: join(root, "project"),
    runtimeRoot: join(root, "runtime"),
    prompt: "Work",
    responseMessageId: "response",
  };
  if (auth !== undefined) request.auth = auth;
  const child = spawn(process.execPath, ["--import", preload, fileURLToPath(runnerURL)], {
    env: {
      PATH: process.env.PATH,
      HOME: root,
      TMPDIR: root,
      CODEX_HOME: join(root, "codex"),
      FIXTURE_FAILURES: String(failures),
      FIXTURE_PARTS: JSON.stringify(parts),
    },
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
  const factories = [...stderr.matchAll(/^fixture-factory:(.*)$/gm)].map((match) =>
    JSON.parse(match[1]),
  );
  return { code, frames, factories, stderr };
}

test(
  "a provider account's auth object reaches the adapter factory only when it is an object",
  { timeout: 120_000 },
  async (t) => {
    const cases = [
      { adapter: "claude-code", auth: {}, want: {} },
      {
        adapter: "codex",
        auth: { CODEX_API_KEY: "fixture-token", OPENAI_BASE_URL: "https://example.test/codex" },
        want: { CODEX_API_KEY: "fixture-token", OPENAI_BASE_URL: "https://example.test/codex" },
      },
      { adapter: "claude-code", auth: null },
      { adapter: "codex", auth: null },
      { adapter: "codex" },
      { adapter: "claude-code", auth: "not-an-object" },
    ];
    for (const { adapter, auth, want } of cases) {
      const result = await runWorker(t, { adapter, auth });
      const label = `${adapter} with auth ${JSON.stringify(auth)}`;
      assert.equal(result.code, 0, `${label}: ${result.stderr}`);
      assert.equal(result.factories.length, 1, label);
      assert.equal(result.factories[0].adapter, adapter, label);
      if (want === undefined) {
        assert(
          !("auth" in result.factories[0].options),
          `${label}: ${JSON.stringify(result.factories[0])}`,
        );
      } else {
        assert.deepEqual(result.factories[0].options.auth, want, label);
      }
      assert(
        result.frames.some((frame) => frame.chunk?.delta === "answered"),
        label,
      );
    }
  },
);

test(
  "a raw Claude rate_limit_event becomes one provider-usage frame and the stream flows on",
  { timeout: 40_000 },
  async (t) => {
    const event = {
      type: "rate_limit_event",
      rate_limit_info: {
        status: "allowed",
        rateLimitType: "five_hour",
        utilization: 0.38,
        resetsAt: 1763150400,
      },
    };
    const result = await runWorker(t, {
      adapter: "claude-code",
      auth: {},
      parts: [{ type: "raw", rawValue: event }],
    });
    assert.equal(result.code, 0, result.stderr);
    const usage = result.frames.filter((frame) => frame.type === "provider-usage");
    assert.equal(usage.length, 1, JSON.stringify(result.frames));
    assert.deepEqual(usage[0].data, event);
    const usageAt = result.frames.indexOf(usage[0]);
    const answeredAt = result.frames.findIndex((frame) => frame.chunk?.delta === "answered");
    assert(answeredAt > usageAt, JSON.stringify(result.frames));
    assert(!result.frames.some((frame) => frame.type === "auth-failure"));
  },
);

test(
  "a raw Codex account/rateLimits/updated notification becomes one provider-usage frame",
  { timeout: 40_000 },
  async (t) => {
    const params = {
      rateLimits: { primary: { usedPercent: 24, windowDurationMins: 300, resetsAt: 1763150400 } },
    };
    const result = await runWorker(t, {
      adapter: "codex",
      auth: { CODEX_API_KEY: "fixture-token" },
      parts: [
        { type: "raw", rawValue: { method: "account/rateLimits/updated", params } },
        { type: "raw", rawValue: { method: "thread/tokenUsage/updated", params: {} } },
      ],
    });
    assert.equal(result.code, 0, result.stderr);
    const usage = result.frames.filter((frame) => frame.type === "provider-usage");
    assert.equal(usage.length, 1, JSON.stringify(result.frames));
    assert.deepEqual(usage[0].data, params);
    assert(result.frames.some((frame) => frame.chunk?.delta === "answered"));
  },
);

test(
  "only the second Claude auth failure reports the login as rejected",
  { timeout: 80_000 },
  async (t) => {
    const recovered = await runWorker(t, { adapter: "claude-code", auth: {}, failures: 1 });
    assert.equal(recovered.code, 0, recovered.stderr);
    assert(!recovered.frames.some((frame) => frame.type === "auth-failure"));
    assert(recovered.frames.some((frame) => frame.chunk?.delta === "answered"));

    const rejected = await runWorker(t, { adapter: "claude-code", auth: {}, failures: 2 });
    const failures = rejected.frames.filter((frame) => frame.type === "auth-failure");
    assert.equal(failures.length, 1, JSON.stringify(rejected.frames));
    assert.equal(failures[0].reason, "HTTP 401: authentication_failed");
    const errorAt = rejected.frames.findIndex((frame) => frame.chunk?.type === "error");
    assert(errorAt >= 0, JSON.stringify(rejected.frames));
    assert.match(rejected.frames[errorAt].chunk.errorText, /^Claude Code sign-in was rejected/);
  },
);
