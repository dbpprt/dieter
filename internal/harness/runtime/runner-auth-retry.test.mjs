import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { claudeAuthResumePrompt } from "./claude-resilience.mjs";

const runnerURL = new URL("./runner.mjs", import.meta.url).href;
const dataURL = (source) => `data:text/javascript,${encodeURIComponent(source)}`;

// The real worker with a deterministic provider boundary: the first
// FIXTURE_FAILURES streams end in Claude Code's terminal 401, later ones answer.
const agentFixture = `
export const getHarnessErrorMessage = error => error.message;
let streams = 0;
export class HarnessAgent {
  async createSession() {
    const state = () => ({type: 'resume-session', data: {claudeSessionId: 'fixture'}});
    return {detach: async () => state(), stop: async () => state()};
  }
  async stream({prompt}) {
    streams += 1;
    process.stderr.write('fixture-prompt:' + JSON.stringify(prompt) + '\\n');
    const failing = streams <= Number(process.env.FIXTURE_FAILURES);
    return {stream: new ReadableStream({start: controller => {
      controller.enqueue({type: 'start', messageId: 'response'});
      if (failing) {
        controller.enqueue({type: 'error', errorText: 'HTTP 401: authentication_failed'});
      } else {
        controller.enqueue({type: 'text-delta', id: 'text', delta: 'recovered'});
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
})};
registerHooks({resolve(specifier, context, next) {
  if (context.parentURL === ${JSON.stringify(runnerURL)} && replacements[specifier]) {
    return {url: replacements[specifier], shortCircuit: true};
  }
  return next(specifier, context);
}});
`);

async function runWorker(t, failures) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "dieter-auth-retry-")));
  await mkdir(join(root, "project"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const request = {
    harness: "claude-code",
    adapter: "claude-code",
    sessionId: "auth-retry-test",
    projectPath: join(root, "project"),
    runtimeRoot: join(root, "runtime"),
    prompt: "Research",
    responseMessageId: "response",
  };
  const child = spawn(process.execPath, ["--import", preload, fileURLToPath(runnerURL)], {
    env: { PATH: process.env.PATH, HOME: root, TMPDIR: root, FIXTURE_FAILURES: String(failures) },
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

test(
  "a terminal Claude 401 resumes the session once and hides the held error",
  { timeout: 40_000 },
  async (t) => {
    const result = await runWorker(t, 1);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.prompts, ["Research", claudeAuthResumePrompt]);
    assert(result.frames.some((frame) => frame.chunk?.delta === "recovered"));
    assert(
      !result.frames.some((frame) => frame.type === "error" || frame.chunk?.type === "error"),
      JSON.stringify(result.frames),
    );
  },
);

test(
  "a second Claude 401 is reported with an actionable first line and no third attempt",
  { timeout: 40_000 },
  async (t) => {
    const result = await runWorker(t, 2);
    assert.deepEqual(result.prompts, ["Research", claudeAuthResumePrompt]);
    const errors = result.frames.filter((frame) => frame.chunk?.type === "error");
    assert.equal(errors.length, 1);
    const lines = errors[0].chunk.errorText.split("\n");
    assert.match(lines[0], /^Claude Code sign-in was rejected.*claude auth login/);
    assert.equal(lines[1], "HTTP 401: authentication_failed");
  },
);
