import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeUsage, probe } from "./usage-claude.mjs";

const probeURL = new URL("./usage-claude.mjs", import.meta.url).href;
const dataURL = (source) => `data:text/javascript,${encodeURIComponent(source)}`;

const report = {
  subscription_type: "max",
  rate_limits_available: true,
  rate_limits: {
    five_hour: { utilization: 12.345, resets_at: "2026-11-14T15:00:00Z" },
    seven_day: { utilization: 140, resets_at: "2026-11-18T10:00:00Z" },
    seven_day_opus: { utilization: 5, resets_at: null },
    extra_usage: {
      is_enabled: true,
      monthly_limit: 5000,
      used_credits: 1250,
      utilization: 25,
      currency: "usd",
    },
  },
};

test("normalizes account info and plan usage", () => {
  const result = normalizeUsage(
    {
      email: "alice@example.com",
      organization: "Org",
      subscriptionType: "max",
      apiProvider: "firstParty",
    },
    report,
  );
  assert.deepEqual(result, {
    loggedIn: true,
    identity: { email: "alice@example.com", organization: "Org", plan: "max" },
    usage: {
      plan: "max",
      windows: [
        {
          kind: "five_hour",
          label: "5h",
          usedPercent: 12.3,
          durationMinutes: 300,
          resetsAt: "2026-11-14T15:00:00Z",
        },
        {
          kind: "weekly",
          label: "Weekly",
          usedPercent: 100,
          durationMinutes: 10080,
          resetsAt: "2026-11-18T10:00:00Z",
        },
        { kind: "model", label: "Opus", usedPercent: 5, durationMinutes: 10080 },
      ],
      spend: { used: 12.5, limit: 50, currency: "USD" },
    },
  });
});

test("prefers the server's per-model windows", () => {
  const result = normalizeUsage(
    { email: "a@example.com", subscriptionType: "max" },
    {
      ...report,
      rate_limits: {
        ...report.rate_limits,
        model_scoped: [{ display_name: "Fable", utilization: 7, resets_at: null }],
      },
    },
  );
  assert.deepEqual(
    result.usage.windows.map((window) => window.label),
    ["5h", "Weekly", "Fable"],
  );
});

test("reports signed-out and unsupported logins", () => {
  assert.deepEqual(normalizeUsage({}, undefined), {
    loggedIn: false,
    identity: {},
    usage: { unavailable: "signed_out" },
  });
  assert.equal(
    normalizeUsage({ email: "a@example.com", apiProvider: "bedrock" }, report).usage.unavailable,
    "unsupported",
  );
  assert.equal(
    normalizeUsage(
      { email: "a@example.com", subscriptionType: "pro" },
      { rate_limits_available: false, rate_limits: null },
    ).usage.unavailable,
    "unsupported",
  );
});

test("probe runs a prompt-less session and closes it", async () => {
  const seen = {};
  const sdk = {
    query({ prompt, options }) {
      seen.options = options;
      seen.prompt = prompt;
      return {
        accountInfo: async () => ({ email: "alice@example.com", subscriptionType: "max" }),
        usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET: async (opts) => {
          seen.usageOptions = opts;
          return report;
        },
        close: () => {
          seen.closed = true;
        },
      };
    },
  };
  const result = await probe({ sdk, cwd: "/tmp" });
  assert.equal(result.loggedIn, true);
  assert.deepEqual(seen.options, { cwd: "/tmp", settingSources: [], persistSession: false });
  assert.deepEqual(seen.usageOptions, { skipBehaviors: true });
  assert.equal(seen.closed, true);
  // The prompt stream ends without yielding a message.
  const iterator = seen.prompt[Symbol.asyncIterator]();
  assert.deepEqual(await iterator.next(), { value: undefined, done: true });
});

test("probe times out", async () => {
  const sdk = {
    query: () => ({ accountInfo: () => new Promise(() => {}), close: () => {} }),
  };
  await assert.rejects(probe({ sdk, timeoutMs: 20 }), /timed out/);
});

// The script itself, with the SDK swapped for a stub through a resolve hook.
async function runScript(t, sdkSource) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "dieter-usage-claude-")));
  t.after(() => rm(root, { recursive: true, force: true }));
  const preload = dataURL(`
import { registerHooks } from 'node:module';
registerHooks({resolve(specifier, context, next) {
  if (context.parentURL === ${JSON.stringify(probeURL)} && specifier === '@anthropic-ai/claude-agent-sdk') {
    return {url: ${JSON.stringify(dataURL(sdkSource))}, shortCircuit: true};
  }
  return next(specifier, context);
}});
`);
  const child = spawn(process.execPath, ["--import", preload, fileURLToPath(probeURL)], {
    cwd: root,
    env: { PATH: process.env.PATH, HOME: root, CLAUDE_CONFIG_DIR: join(root, "claude") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => (stdout += chunk));
  child.stderr.on("data", (chunk) => (stderr += chunk));
  const code = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  return { code, stdout, stderr };
}

test("the script prints one JSON line", async (t) => {
  const { code, stdout, stderr } = await runScript(
    t,
    `export const query = ({options}) => ({
      accountInfo: async () => ({email: 'alice@example.com', subscriptionType: 'max', configDir: process.env.CLAUDE_CONFIG_DIR}),
      usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET: async () => (${JSON.stringify(report)}),
      close: () => {},
    });`,
  );
  assert.equal(code, 0, stderr);
  const lines = stdout.trim().split("\n");
  assert.equal(lines.length, 1);
  const result = JSON.parse(lines[0]);
  assert.equal(result.loggedIn, true);
  assert.equal(result.usage.windows.length, 3);
});

test("the script fails when the SDK fails", async (t) => {
  const { code, stdout, stderr } = await runScript(
    t,
    `export const query = () => ({accountInfo: async () => { throw new Error('Claude Code exited'); }, close: () => {}});`,
  );
  assert.equal(code, 1);
  assert.equal(stdout, "");
  assert.match(stderr, /Claude Code exited/);
});
