#!/usr/bin/env node
// Provider-account spike probes for docs/proposals/provider-accounts.md.
//
// Every probe runs the agent CLIs pinned in a Dieter harness runtime inside a
// throwaway HOME, CLAUDE_CONFIG_DIR and CODEX_HOME. No probe completes a sign-in:
// login flows are started, their prompts and URLs are recorded with PKCE
// challenge, state and user codes redacted, and the flow is cancelled. The
// resume probe uses a bogus OAuth token, so its only provider traffic is one
// rejected request.
//
// Usage:
//   node tools/spikes/provider-accounts/probe.mjs --runtime DIR [--out FILE]
//
// DIR is an installed harness runtime (DIETER_HOME/runtime/harness/<digest>).

import { spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  existsSync,
  chmodSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const runtime = args.get("--runtime");
if (!runtime) {
  console.error("usage: probe.mjs --runtime DIR [--out FILE]");
  process.exit(2);
}
const modules = join(runtime, "node_modules");
const platform = `${process.platform === "darwin" ? "darwin" : "linux"}-${process.arch === "arm64" ? "arm64" : "x64"}`;
const claude = join(modules, "@anthropic-ai", `claude-agent-sdk-${platform}`, "claude");
const codexTriple = {
  "darwin-arm64": "aarch64-apple-darwin",
  "linux-arm64": "aarch64-unknown-linux-musl",
  "linux-x64": "x86_64-unknown-linux-musl",
}[platform];
const codex = join(modules, "@openai", `codex-${platform}`, "vendor", codexTriple, "bin", "codex");

const root = mkdtempSync(join(tmpdir(), "dieter-provider-accounts-"));
const home = join(root, "home");
mkdirSync(home);
const browserLog = join(root, "browser-calls.log");
const browserHook = join(root, "browser-hook.sh");
writeFileSync(browserHook, `#!/bin/sh\necho "$@" >> '${browserLog}'\n`);
chmodSync(browserHook, 0o755);

const redact = (text) =>
  String(text)
    .replaceAll(`/private${root}`, "<tmp>")
    .replaceAll(root, "<tmp>")
    .replaceAll(tmpdir(), "<tmpdir>/")
    .replaceAll(runtime, "<runtime>")
    .replace(/(code_challenge|state|nonce)=[^&"\s]+/g, "$1=<redacted>")
    .replace(/"userCode":\s*"[^"]+"/g, '"userCode":"<redacted>"')
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/\r/g, "");

const baseEnv = (extra) => ({
  PATH: "/usr/bin:/bin",
  HOME: home,
  USER: process.env.USER ?? "",
  BROWSER: browserHook,
  ...extra,
});

function run(command, argv, env, { seconds = 30, stdin = "ignore" } = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, argv, { env, cwd: root, stdio: [stdin, "pipe", "pipe"] });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    const timer = setTimeout(() => child.kill("SIGTERM"), seconds * 1000);
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, output: redact(out).trim() });
    });
  });
}

const browserCalls = () =>
  existsSync(browserLog) ? redact(readFileSync(browserLog, "utf8")).trim().split("\n") : [];

async function claudeLogin() {
  const config = join(root, "claude-login");
  rmSync(browserLog, { force: true });
  const env = baseEnv({ CLAUDE_CONFIG_DIR: config });
  const status = await run(claude, ["auth", "status", "--json"], env, { seconds: 20 });
  // Plain pipes, no TTY: the CLI prints the manual URL and waits for a pasted code.
  const login = await run(claude, ["auth", "login", "--claudeai"], env, {
    seconds: 8,
    stdin: "pipe",
  });
  return {
    version: (await run(claude, ["--version"], env)).output,
    status: status.output,
    loginOutput: login.output,
    browserHookCalls: browserCalls(),
  };
}

async function claudeResumeAcrossConfigDirs() {
  const work = join(root, "work");
  const shared = join(root, "shared-projects");
  mkdirSync(work);
  mkdirSync(shared);
  const dirs = { a: join(root, "claude-a"), b: join(root, "claude-b"), c: join(root, "claude-c") };
  for (const dir of Object.values(dirs)) mkdirSync(dir);
  symlinkSync(shared, join(dirs.a, "projects"));
  symlinkSync(shared, join(dirs.b, "projects"));
  const session = "6f1c2a7e-1111-4c3d-9e2f-0123456789ab";
  const env = (dir) =>
    baseEnv({
      CLAUDE_CONFIG_DIR: dir,
      CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-bogus-spike-token",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
    });
  const exec = (dir, argv) =>
    new Promise((resolve) => {
      const child = spawn(claude, argv, {
        env: env(dir),
        cwd: work,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let out = "";
      child.stdout.on("data", (d) => (out += d));
      child.stderr.on("data", (d) => (out += d));
      const timer = setTimeout(() => child.kill("SIGTERM"), 60_000);
      child.on("close", () => {
        clearTimeout(timer);
        resolve(redact(out).trim().split("\n").slice(-2).join("\n"));
      });
    });
  const created = await exec(dirs.a, [
    "-p",
    "say hi",
    "--session-id",
    session,
    "--output-format",
    "text",
  ]);
  const transcripts = readdirSync(shared, { recursive: true }).filter((p) =>
    String(p).endsWith(".jsonl"),
  );
  const sharedResume = await exec(dirs.b, [
    "-p",
    "again",
    "--resume",
    session,
    "--output-format",
    "text",
  ]);
  const isolatedResume = await exec(dirs.c, [
    "-p",
    "again",
    "--resume",
    session,
    "--output-format",
    "text",
  ]);
  return { created, transcripts, sharedProjectsResume: sharedResume, isolatedResume };
}

async function codexAppServerLogin(type) {
  const codexHome = join(root, `codex-${type}`);
  mkdirSync(codexHome, { recursive: true });
  rmSync(browserLog, { force: true });
  const child = spawn(codex, ["app-server"], {
    env: baseEnv({ CODEX_HOME: codexHome }),
    cwd: root,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const pending = new Map();
  const notifications = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    if (message.id != null && pending.has(message.id)) pending.get(message.id)(message);
    else notifications.push(message);
  });
  let nextId = 1;
  const request = (method, params) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 20_000);
      pending.set(id, (m) => {
        clearTimeout(timer);
        resolve(m);
      });
      child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    });
  try {
    const initialize = await request("initialize", {
      clientInfo: { name: "dieter_spike", title: "Dieter spike", version: "0.0.0" },
    });
    child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
    const account = await request("account/read", {});
    const login = await request("account/login/start", { type });
    const loginId = login.result?.loginId;
    const cancel = loginId ? await request("account/login/cancel", { loginId }) : undefined;
    return {
      codexHome: redact(initialize.result?.codexHome ?? ""),
      account: account.result,
      login: JSON.parse(redact(JSON.stringify(login.result ?? login.error))),
      cancel: cancel?.result,
      browserHookCalls: browserCalls(),
      notifications: notifications.map((n) => n.method),
      codexHomeEntries: readdirSync(codexHome).sort(),
    };
  } finally {
    child.kill("SIGTERM");
  }
}

async function codexProtocol() {
  const out = join(root, "schema");
  await run(
    codex,
    ["app-server", "generate-json-schema", "--out", out],
    baseEnv({ CODEX_HOME: join(root, "codex-schema") }),
    { seconds: 60 },
  );
  const login = JSON.parse(readFileSync(join(out, "v2", "LoginAccountParams.json"), "utf8"));
  const variants = login.oneOf.map((v) => ({
    type: v.properties?.type?.enum?.[0],
    fields: Object.keys(v.properties ?? {}).filter((k) => k !== "type"),
    note: v.description?.slice(0, 80),
  }));
  const serverRequests =
    readFileSync(join(out, "ServerRequest.json"), "utf8").match(/"account\/[A-Za-z/]+"/g) ?? [];
  return {
    version: (await run(codex, ["--version"], baseEnv({}))).output.split("\n").at(-1),
    loginVariants: variants,
    accountServerRequests: [...new Set(serverRequests)],
  };
}

const results = { ranAt: new Date().toISOString(), platform };
try {
  results.claudeLogin = await claudeLogin();
  results.claudeResumeAcrossConfigDirs = await claudeResumeAcrossConfigDirs();
  results.codexProtocol = await codexProtocol();
  results.codexBrowserLogin = await codexAppServerLogin("chatgpt");
  results.codexDeviceCodeLogin = await codexAppServerLogin("chatgptDeviceCode");
} finally {
  rmSync(root, { recursive: true, force: true });
}
const text = JSON.stringify(results, null, 2) + "\n";
if (args.get("--out")) writeFileSync(args.get("--out"), text);
process.stdout.write(text);
