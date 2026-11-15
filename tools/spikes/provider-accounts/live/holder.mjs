#!/usr/bin/env node
// Phase 0 login holder: keeps one official provider login alive while a person
// completes it in a browser, the way the daemon's login session would.
//
//   holder.mjs claude --dir DIR --claude BIN           claude auth login in CLAUDE_CONFIG_DIR=DIR/config
//   holder.mjs codex  --dir DIR --codex BIN --type T   app-server account/login/start (chatgpt | chatgptDeviceCode)
//   holder.mjs siwc   --dir DIR [--client-id ID --id-token-file F] [--port N]
//
// Each login writes DIR/challenge.json once its URL or code is ready and then
// polls DIR/input. A line there is either a pasted code (Claude manual flow) or
// a full loopback redirect URL copied from a browser on another device, which
// the holder replays to the loopback listener on this host (callback
// forwarding). The outcome goes to DIR/result.json. Secrets stay in DIR
// (mode 0700): Claude Code's own store, Codex's auth.json, siwc.json.

import { spawn } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { createInterface } from "node:readline";

const [mode, ...rest] = process.argv.slice(2);
const opt = {};
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];
const dir = opt.dir;
mkdirSync(dir, { recursive: true, mode: 0o700 });
chmodSync(dir, 0o700);

const log = (...a) => console.log(new Date().toISOString(), ...a);
const writeJSON = (name, value) => {
  const path = join(dir, name);
  writeFileSync(`${path}.tmp`, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  renameSync(`${path}.tmp`, path);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const deadline = Date.now() + Number(opt.minutes ?? 45) * 60_000;

async function nextInput() {
  const path = join(dir, "input");
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      const text = readFileSync(path, "utf8").trim();
      renameSync(path, join(dir, `input.consumed.${Date.now()}`));
      if (text) return text;
    }
    await sleep(1000);
  }
  throw new Error("timed out waiting for input");
}

async function forward(url) {
  // Replays a loopback redirect captured on another device to this host.
  const response = await fetch(url, { redirect: "manual" });
  log("forwarded callback ->", response.status);
  return response.status;
}

function decodeJwt(token) {
  try {
    const part = token.split(".")[1];
    return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
  } catch {
    return undefined;
  }
}

async function claude() {
  const config = join(dir, "config");
  mkdirSync(config, { recursive: true, mode: 0o700 });
  const hook = join(dir, "browser-hook.sh");
  writeFileSync(hook, `#!/bin/sh\nprintf '%s\\n' "$1" > '${join(dir, "browser-url")}'\n`, {
    mode: 0o700,
  });
  const env = {
    PATH: "/usr/bin:/bin",
    HOME: process.env.HOME,
    USER: process.env.USER,
    CLAUDE_CONFIG_DIR: config,
    BROWSER: hook,
  };
  const child = track(
    spawn(opt.claude, ["auth", "login", "--claudeai"], { env, stdio: ["pipe", "pipe", "pipe"] }),
  );
  let output = "";
  const onData = (d) => {
    output += d;
    process.stdout.write(String(d).replace(/(code_challenge|state)=[^&\s]+/g, "$1=<redacted>"));
  };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData);
  const exited = new Promise((resolve) => child.on("close", (code) => resolve(code)));
  while (!/visit: (https:\/\/\S+)/.test(output) && Date.now() < deadline) await sleep(200);
  const manualUrl = output.match(/visit: (https:\/\/\S+)/)[1];
  let localUrl;
  for (let i = 0; i < 50 && !localUrl; i++) {
    if (existsSync(join(dir, "browser-url")))
      localUrl = readFileSync(join(dir, "browser-url"), "utf8").trim();
    else await sleep(100);
  }
  writeJSON("challenge.json", {
    kind: "claude",
    manualUrl,
    localUrl,
    callbackPort: localUrl && new URL(new URL(localUrl).searchParams.get("redirect_uri")).port,
  });
  log("challenge ready");
  const input = await Promise.race([nextInput(), exited.then(() => undefined)]);
  let delivery;
  if (input && /^https?:\/\/(localhost|127\.0\.0\.1)/.test(input))
    delivery = { forwarded: await forward(input) };
  else if (input) {
    child.stdin.write(input + "\n");
    delivery = { pasted: true };
  }
  const code = await Promise.race([exited, sleep(120_000).then(() => "timeout")]);
  if (code === "timeout") child.kill("SIGTERM");
  const status = await new Promise((resolve) => {
    const s = spawn(opt.claude, ["auth", "status", "--json"], { env });
    let out = "";
    s.stdout.on("data", (d) => (out += d));
    s.on("close", () => resolve(out));
  });
  writeJSON("result.json", {
    exitCode: code,
    delivery,
    status: JSON.parse(status || "{}"),
    tail: output.split("\n").slice(-4),
  });
  log("done", code);
}

async function codex() {
  const home = join(dir, "codex-home");
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const env = {
    PATH: "/usr/bin:/bin",
    HOME: process.env.HOME,
    USER: process.env.USER,
    CODEX_HOME: home,
  };
  const child = track(
    spawn(opt.codex, ["-c", 'cli_auth_credentials_store="file"', "app-server"], {
      env,
      stdio: ["pipe", "pipe", "inherit"],
    }),
  );
  const pending = new Map();
  const notifications = [];
  let completed;
  const done = new Promise((resolve) => (completed = resolve));
  createInterface({ input: child.stdout }).on("line", (line) => {
    const m = JSON.parse(line);
    if (m.id != null && pending.has(m.id)) return pending.get(m.id)(m);
    notifications.push(m.method);
    if (m.method === "account/login/completed") completed(m.params);
  });
  let id = 1;
  const request = (method, params) =>
    new Promise((resolve) => {
      const n = id++;
      pending.set(n, resolve);
      child.stdin.write(JSON.stringify({ id: n, method, params }) + "\n");
    });
  await request("initialize", {
    clientInfo: { name: "dieter", title: "Dieter", version: "0.0.0-spike" },
  });
  child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
  const start = await request("account/login/start", { type: opt.type });
  if (start.error) {
    writeJSON("result.json", { error: start.error });
    child.kill();
    return;
  }
  writeJSON("challenge.json", { kind: "codex", ...start.result });
  log("challenge ready", opt.type);
  if (opt.type === "chatgpt") {
    const input = await Promise.race([nextInput(), done.then(() => undefined)]);
    if (input) await forward(input);
  }
  const outcome = await Promise.race([
    done,
    sleep(deadline - Date.now()).then(() => ({ timeout: true })),
  ]);
  const account = await request("account/read", {});
  writeJSON("result.json", { login: outcome, account: account.result, notifications });
  child.kill("SIGTERM");
  log("done");
}

async function siwc() {
  const issuer = "https://auth.openai.com";
  const port = Number(opt.port ?? 0);
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const state = randomBytes(16).toString("base64url");
  const nonce = randomBytes(16).toString("base64url");
  const hostId = opt["host-id"] ?? `urn:uuid:${randomUUID()}`;
  let resolveCallback;
  const callback = new Promise((r) => (resolveCallback = r));
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    if (url.pathname !== "/auth/callback") return res.writeHead(404).end();
    res.writeHead(200, { "content-type": "text/plain" }).end("Signed in. You can close this tab.");
    resolveCallback(url.searchParams);
  });
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  const redirectUri = `http://127.0.0.1:${server.address().port}/auth/callback`;
  const params = new URLSearchParams({
    client_id: opt["client-id"] ?? "dynamic_agent_client",
    ext_agent_host_id: hostId,
    response_type: "code",
    redirect_uri: redirectUri,
    scope: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
    resource: "https://api.openai.com/v1",
    state,
    nonce,
    code_challenge_method: "S256",
    code_challenge: challenge,
  });
  if (!opt["client-id"]) params.set("agent_name_hint", "Dieter");
  if (opt["id-token-file"])
    params.set("id_token_hint", readFileSync(opt["id-token-file"], "utf8").trim());
  const authorizeUrl = `${issuer}/api/accounts/authorize?${params}`;
  writeJSON("challenge.json", {
    kind: "siwc",
    authorizeUrl,
    redirectUri,
    hostId,
    reauthorize: Boolean(opt["client-id"]),
  });
  log("challenge ready");
  const pasted = nextInput().then((text) => new URL(text).searchParams);
  const query = await Promise.race([callback, pasted]);
  server.close();
  if (query.get("state") !== state) throw new Error("state mismatch");
  if (query.get("error")) {
    writeJSON("result.json", {
      error: query.get("error"),
      description: query.get("error_description"),
    });
    return;
  }
  const clientId = query.get("client_id") ?? opt["client-id"];
  const tokenResponse = await fetch(`${issuer}/api/accounts/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: clientId,
      code: query.get("code"),
      code_verifier: verifier,
      redirect_uri: redirectUri,
      resource: "https://api.openai.com/v1",
    }),
  });
  const body = await tokenResponse.json();
  if (!tokenResponse.ok) {
    writeJSON("result.json", { tokenStatus: tokenResponse.status, error: body });
    return;
  }
  const idClaims = decodeJwt(body.id_token) ?? {};
  writeFileSync(
    join(dir, "siwc.json"),
    JSON.stringify(
      {
        client_id: clientId,
        ext_agent_host_id: hostId,
        ...body,
        saved_at: new Date().toISOString(),
      },
      null,
      2,
    ),
    { mode: 0o600 },
  );
  writeFileSync(join(dir, "id_token"), body.id_token ?? "", { mode: 0o600 });
  writeJSON("result.json", {
    tokenStatus: tokenResponse.status,
    clientIdPrefix: String(clientId).slice(0, 7),
    callbackHadClientId: query.has("client_id"),
    scope: body.scope,
    planUsage: String(body.scope).split(" ").includes("chatgpt.tokens.use.direct"),
    expiresIn: body.expires_in,
    earliestRefreshAt: body.earliest_refresh_at,
    idTokenNonceMatches: idClaims.nonce === nonce,
    idTokenAudMatches:
      idClaims.aud === clientId || (Array.isArray(idClaims.aud) && idClaims.aud.includes(clientId)),
    accessClaims: Object.keys(decodeJwt(body.access_token) ?? {}),
  });
  log("done");
}

// Children (claude auth login, codex app-server) must not outlive the holder.
const children = new Set();
const track = (child) => (children.add(child), child);
for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => process.exit(143));
process.on("exit", () => children.forEach((c) => c.kill("SIGTERM")));

const modes = { claude, codex, siwc };
modes[mode]().catch((error) => {
  writeJSON("result.json", { error: String(error?.stack ?? error) });
  log("failed", error);
  process.exit(1);
});
