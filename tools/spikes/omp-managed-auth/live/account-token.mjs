// Live stand-in for `dieter provider token --turn --provider P`: prints the
// current access token of this machine's Claude Code or Codex login on stdout
// and nothing else. Like the daemon would, it never touches a refresh token:
// when the access token is close to expiry it asks the provider's own tool to
// refresh (Codex app-server `account/read {refreshToken:true}`; Claude Code's
// prompt-less usage probe) and reads the store again.
//
//   node account-token.mjs claude|codex [--refresh-only]
//
// Environment:
//   TOKEN_HELPER_LOG   JSONL log: provider, action, token fingerprint, minutes left
//   CLAUDE_CONFIG_DIR  per-account Claude Code dir (unset: the host login)
//   CLAUDE_PROBE       path to Dieter's usage-claude.mjs (Claude refresh trigger)
//   CODEX_HOME         Codex auth home (default ~/.codex)
//   CODEX_BIN          codex executable (default: codex on PATH)
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, readFileSync } from "node:fs";
import { userInfo } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const provider = process.argv[2];
const refreshOnly = process.argv.includes("--refresh-only");
const claudeWindowMs = 5 * 60_000; // Claude Code refreshes within 5 min of expiry
const codexWindowMs = 24 * 60 * 60_000; // Dieter's broker refreshes within 24 h

function log(action, token, expiresAt) {
  const path = process.env.TOKEN_HELPER_LOG;
  if (!path) return;
  appendFileSync(
    path,
    `${JSON.stringify({
      at: new Date().toISOString(),
      provider,
      action,
      sha256: token ? createHash("sha256").update(token).digest("hex").slice(0, 12) : undefined,
      minutesLeft: expiresAt ? Math.round((expiresAt - Date.now()) / 60_000) : undefined,
    })}\n`,
  );
}

// OMP runs `!command` values with its own (isolated) HOME. The keychain search
// list and the default Codex home belong to the real user, so resolve them
// from the user database instead of $HOME.
const realHome = userInfo().homedir;

function claudeService() {
  const dir = process.env.CLAUDE_CONFIG_DIR;
  if (!dir) return "Claude Code-credentials";
  return `Claude Code-credentials-${createHash("sha256").update(dir).digest("hex").slice(0, 8)}`;
}

function readClaude() {
  const keychain = join(realHome, "Library", "Keychains", "login.keychain-db");
  const raw = execFileSync(
    "security",
    ["find-generic-password", "-s", claudeService(), "-w", keychain],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    },
  );
  const oauth = JSON.parse(raw).claudeAiOauth ?? {};
  return { token: oauth.accessToken, expiresAt: oauth.expiresAt };
}

function refreshClaude() {
  const probe = process.env.CLAUDE_PROBE;
  if (!probe) throw new Error("CLAUDE_PROBE is not set; cannot ask Claude Code to refresh");
  execFileSync(process.execPath, [probe], {
    // Claude Code finds its Keychain item by user name: without USER it reports
    // "signed out" and refreshes nothing.
    env: {
      ...process.env,
      HOME: realHome,
      USER: userInfo().username,
      LOGNAME: userInfo().username,
    },
    stdio: ["ignore", "ignore", "inherit"],
    timeout: 30_000,
  });
}

function codexHome() {
  return process.env.CODEX_HOME || join(realHome, ".codex");
}

function readCodex() {
  const auth = JSON.parse(readFileSync(join(codexHome(), "auth.json"), "utf8"));
  const token = auth.tokens?.access_token;
  const claims = token
    ? JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"))
    : {};
  return { token, expiresAt: claims.exp ? claims.exp * 1000 : undefined };
}

async function refreshCodex() {
  const child = spawn(process.env.CODEX_BIN || "codex", ["app-server"], {
    env: { ...process.env, HOME: realHome, CODEX_HOME: codexHome() },
    stdio: ["pipe", "pipe", "ignore"],
  });
  const pending = new Map();
  createInterface({ input: child.stdout }).on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id != null && pending.has(message.id) && !message.method) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    }
  });
  let id = 0;
  const request = (method, params) =>
    new Promise((resolve, reject) => {
      const next = ++id;
      pending.set(next, { resolve, reject });
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: next, method, params })}\n`);
    });
  const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
  try {
    await request("initialize", {
      clientInfo: { name: "dieter-spike", title: "Dieter spike", version: "0" },
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "initialized" })}\n`);
    const read = await request("account/read", { refreshToken: true });
    if (!read?.account) throw new Error("Codex reports no ChatGPT login");
  } finally {
    clearTimeout(timer);
    child.kill("SIGTERM");
  }
}

const read = provider === "claude" ? readClaude : provider === "codex" ? readCodex : undefined;
if (!read) {
  process.stderr.write("usage: account-token.mjs claude|codex [--refresh-only]\n");
  process.exit(2);
}
const window = provider === "claude" ? claudeWindowMs : codexWindowMs;
let current = read();
// TOKEN_HELPER_FORCE_REFRESH=1 exercises the refresh path on a fresh login.
const force = process.env.TOKEN_HELPER_FORCE_REFRESH === "1";
if (force || !current.token || !current.expiresAt || current.expiresAt - Date.now() < window) {
  log("refresh-requested", current.token, current.expiresAt);
  if (provider === "claude") refreshClaude();
  else await refreshCodex();
  current = read();
  log("refreshed", current.token, current.expiresAt);
}
if (!current.token || current.expiresAt - Date.now() < 60_000) {
  process.stderr.write(`${provider} login has no usable access token\n`);
  process.exit(1);
}
if (!refreshOnly) {
  log("served", current.token, current.expiresAt);
  process.stdout.write(current.token);
}
