// Daemon-host Claude Design operations. Go starts this script with the harness
// environment allowlist and a private state directory. It never receives a
// conversation, a workspace or a credential: Claude Code keeps the claude.ai
// login and the design credential in its own secure storage on this host.
//
//   status   one JSON object describing the pinned CLI and the design sign-in
//   sign-in  Claude Code's design-login JSON lines; stdin carries {"code"} lines
//   consent  grant the Claude account's durable agent access to Design projects
//   revoke   revoke that grant
import { spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { prepareSandboxForHarness } from "@ai-sdk/harness/agent";
import { CLAUDE_CODE_VERSION, createLocalClaudeCode } from "./claude-runtime.mjs";
import { createLocalSandboxProvider } from "./local-sandbox.mjs";

// Stdout is the protocol. Bootstrap diagnostics must not corrupt it.
const protocolWrite = process.stdout.write.bind(process.stdout);
const toStderr = (...values) =>
  process.stderr.write(
    `${values.map((value) => (typeof value === "string" ? value : JSON.stringify(value))).join(" ")}\n`,
  );
console.log = toStderr;
console.info = toStderr;
console.debug = toStderr;
console.warn = toStderr;
const emit = (value) =>
  new Promise((resolveWrite) => protocolWrite(`${JSON.stringify(value)}\n`, () => resolveWrite()));

const maxOutputBytes = 1 << 20;
const workDir = "workspace/repo";

function run(command, args, { cwd, timeoutMs, input = "ignore" }) {
  return new Promise((resolveRun) => {
    const child = spawn(command, args, { cwd, stdio: [input, "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let exceeded = false;
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (chunk) => {
      if (stdout.length + chunk.length > maxOutputBytes) {
        exceeded = true;
        child.kill("SIGKILL");
        return;
      }
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr = `${stderr}${chunk}`.slice(-4096);
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      resolveRun({ code: -1, stdout, stderr: error.message, exceeded });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolveRun({ code: code ?? -1, stdout, stderr, exceeded });
    });
  });
}

function lastJSONLine(text) {
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      const value = JSON.parse(lines[index]);
      if (value && typeof value === "object") return value;
    } catch {
      // Claude Code may print a diagnostic line before its JSON result.
    }
  }
  return undefined;
}

async function claudeBinary() {
  const recipe = await createLocalClaudeCode().getBootstrap({});
  return join(
    process.env.HOME || homedir(),
    ".ai-sdk-harness",
    recipe.bootstrapDir,
    "node_modules",
    ".bin",
    "claude",
  );
}

async function runtimeReady(binary, cwd) {
  const result = await run(binary, ["--version"], { cwd, timeoutMs: 15_000 });
  return result.code === 0 && result.stdout.trim().startsWith(`${CLAUDE_CODE_VERSION} `);
}

// The marker check makes this a single file read when Dieter's turns already
// installed the same pinned recipe.
async function prepareRuntime(stateRoot, project) {
  const sandbox = await createLocalSandboxProvider({
    root: stateRoot,
    projectPath: project,
    workDir,
  });
  try {
    const session = await sandbox.createSession();
    await prepareSandboxForHarness({
      session,
      harnesses: [createLocalClaudeCode()],
      sandboxConfig: { workDir },
    });
  } finally {
    await sandbox.stopAll?.();
  }
}

async function status(binary, project) {
  if (!(await runtimeReady(binary, project))) {
    return {
      runtimeReady: false,
      version: CLAUDE_CODE_VERSION,
      available: false,
      signedIn: false,
      canSignIn: true,
      reason: `Claude Code ${CLAUDE_CODE_VERSION} is installed on this machine with the first sign-in or Claude Code turn.`,
    };
  }
  const result = await run(binary, ["design-login", "--json", "--status"], {
    cwd: project,
    timeoutMs: 30_000,
  });
  const value = lastJSONLine(result.stdout);
  if (result.code !== 0 || !value) {
    return {
      runtimeReady: true,
      version: CLAUDE_CODE_VERSION,
      available: false,
      signedIn: false,
      canSignIn: false,
      reason:
        (result.stdout || result.stderr).trim().split("\n").pop() ||
        "Claude Code did not report Claude Design status.",
    };
  }
  return {
    runtimeReady: true,
    version: CLAUDE_CODE_VERSION,
    available: value.available === true,
    signedIn: value.signed_in === true,
    canSignIn: value.can_sign_in_here === true,
    reason: typeof value.reason === "string" ? value.reason : "",
  };
}

async function accessGrant(binary, project, command) {
  const current = await status(binary, project);
  if (!current.available) {
    return {
      ok: false,
      message: current.reason || "Claude Design is not available for this Claude account.",
    };
  }
  // Both commands are local, non-interactive Claude Code commands. Without
  // tools and with one turn at most, a build that no longer recognized them
  // could not act on the text.
  const result = await run(
    binary,
    [
      "-p",
      `/${command}`,
      "--output-format",
      "json",
      "--no-session-persistence",
      "--strict-mcp-config",
      "--tools",
      "",
      "--max-turns",
      "1",
    ],
    { cwd: project, timeoutMs: 60_000 },
  );
  const value = lastJSONLine(result.stdout);
  const message = typeof value?.result === "string" ? value.result.trim() : "";
  const expected =
    command === "design-consent" ? /^Design agent access granted/ : /^Design agent access revoked/;
  if (
    result.exceeded ||
    !value ||
    value.is_error ||
    value.num_turns > 0 ||
    !expected.test(message)
  ) {
    return {
      ok: false,
      message:
        message ||
        (result.stderr || "").trim().split("\n").pop() ||
        `Claude Code could not run /${command}.`,
    };
  }
  return { ok: true, message };
}

async function signIn(binary, stateRoot, project) {
  if (!(await runtimeReady(binary, project))) {
    await emit({ event: "preparing" });
  }
  try {
    await prepareRuntime(stateRoot, project);
  } catch (error) {
    await emit({
      event: "done",
      ok: false,
      message: `Claude Code could not be installed: ${error?.message || error}`,
    });
    return 1;
  }
  return new Promise((resolveSignIn) => {
    // Inherit the protocol pipes: Claude Code writes its JSON lines directly
    // and reads {"code": "..."} lines from Dieter on stdin.
    const child = spawn(binary, ["design-login", "--json"], { cwd: project, stdio: "inherit" });
    const stop = () => child.kill("SIGTERM");
    process.once("SIGTERM", stop);
    process.once("SIGINT", stop);
    child.on("error", async (error) => {
      await emit({ event: "done", ok: false, message: error.message });
      resolveSignIn(1);
    });
    child.on("close", (code) => resolveSignIn(code ?? 1));
  });
}

const [command, stateRootArgument] = process.argv.slice(2);
if (!stateRootArgument) {
  toStderr("usage: claude-design-host.mjs <status|sign-in|consent|revoke> <state-root>");
  process.exit(2);
}
const stateRoot = resolve(stateRootArgument);
const project = join(stateRoot, "host");
await mkdir(project, { recursive: true, mode: 0o700 });
const binary = await claudeBinary();
let exitCode = 0;
switch (command) {
  case "status":
    await emit(await status(binary, project));
    break;
  case "sign-in":
    exitCode = await signIn(binary, stateRoot, project);
    break;
  case "consent":
  case "revoke": {
    const outcome = await accessGrant(binary, project, `design-${command}`);
    await emit(outcome);
    exitCode = outcome.ok ? 0 : 1;
    break;
  }
  default:
    toStderr(`unknown Claude Design command: ${command}`);
    exitCode = 2;
}
process.exit(exitCode);
