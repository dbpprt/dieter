// Push + pull agent channels spike (Atrium-style coordination).
//
// Runs one or two HarnessAgents (built like runner.mjs) against a shared
// checkout and an in-process channel board served on loopback HTTP:
//
//   push   board → agent: coalesced experimental_steerTurn while a turn runs
//          ("steer"), or PostToolUse additionalContext ("hook"); otherwise a
//          digest in the next prompt; a released claim wakes a waiting agent
//   pull   agent → board: channel_check / channel_inbox / channel_post host
//          tools (instruction-driven, Atrium's "is anybody else doing this?")
//          and PreToolUse hooks that check claims before every write
//          (deterministic: no model call when there is no conflict)
//
// Scenarios:
//   probe       which hooks fire through Dieter's adapters, tool names, deny
//   pull-check  claim held by Z; the agent is told to channel_check first
//   pull-hook   same claim; no instruction, PreToolUse enforces it
//   push-hook   a post arrives mid-turn and is delivered by PostToolUse
//   pair        agents A and B, overlapping files and commits, claims + push
//
// Usage: node atrium.mjs --scenario NAME --a claude-code|codex [--b claude-code|codex]
//                        [--codex-hooks thread|home] [--no-board] --out FILE
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { homedir, tmpdir, userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const runtimeDir = resolve(here, "../../../internal/harness/runtime");

function args() {
  const out = {};
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) out[key] = argv[++i];
    else out[key] = true;
  }
  return out;
}
const opts = args();

// ─── Parent: homes, credentials, scrubbed environment ──────────────────────

function claudeAccessToken() {
  const raw = execFileSync(
    "perl",
    [
      "-e",
      "alarm 25; exec @ARGV",
      "security",
      "find-generic-password",
      "-s",
      "Claude Code-credentials",
      "-a",
      userInfo().username,
      "-w",
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  const oauth = JSON.parse(raw.trim()).claudeAiOauth;
  if (!oauth?.accessToken) throw new Error("keychain item has no claudeAiOauth.accessToken");
  if (oauth.expiresAt && oauth.expiresAt - Date.now() < 30 * 60_000)
    throw new Error("Claude access token expires within 30 min; refresh it with the real CLI");
  return oauth.accessToken; // the refresh token never leaves this function
}

function codexDefaultModel() {
  const toml = readFileSync(join(homedir(), ".codex", "config.toml"), "utf8");
  for (const line of toml.split("\n")) {
    if (/^\s*\[/.test(line)) break;
    const m = line.match(/^\s*model\s*=\s*"([^"]+)"/);
    if (m) return m[1];
  }
  throw new Error("no top-level model in ~/.codex/config.toml");
}

function prepareCodexHome(dst, model) {
  const auth = JSON.parse(readFileSync(join(homedir(), ".codex", "auth.json"), "utf8"));
  const access = auth?.tokens?.access_token;
  if (!access) throw new Error("~/.codex/auth.json has no tokens.access_token");
  const claims = JSON.parse(Buffer.from(access.split(".")[1], "base64url").toString("utf8"));
  if (claims.exp * 1000 - Date.now() < 2 * 3600_000)
    throw new Error("Codex access token expires within 2 h; refresh it with the real Codex");
  auth.tokens.refresh_token = "spike-no-refresh";
  mkdirSync(dst, { recursive: true, mode: 0o700 });
  writeFileSync(join(dst, "auth.json"), JSON.stringify(auth, null, 2) + "\n", { mode: 0o600 });
  writeFileSync(
    join(dst, "config.toml"),
    `model = ${JSON.stringify(model)}\nmodel_reasoning_effort = "low"\ncli_auth_credentials_store = "file"\n`,
    { mode: 0o600 },
  );
}

const GIT_ENV = {
  GIT_AUTHOR_NAME: "spike",
  GIT_AUTHOR_EMAIL: "spike@example.invalid",
  GIT_COMMITTER_NAME: "spike",
  GIT_COMMITTER_EMAIL: "spike@example.invalid",
};

function writeFixture(project) {
  mkdirSync(join(project, "src"), { recursive: true });
  for (let f = 0; f < 8; f++) {
    const lines = [`// module ${f}: inventory pricing rules`, `export const MODULE_${f} = ${f};`];
    for (let i = 0; i < 40; i++)
      lines.push(
        `export function rule${f}_${i}(qty, price) { return qty > ${i} ? price * ${(1 - i / 1000).toFixed(3)} : price; }`,
      );
    writeFileSync(join(project, "src", `module${f}.js`), lines.join("\n") + "\n");
  }
  writeFileSync(join(project, "README.md"), "# pricing fixture\n");
  const git = (...a) =>
    execFileSync("git", a, { cwd: project, env: { ...process.env, ...GIT_ENV } });
  git("init", "-q");
  git("add", ".");
  git("commit", "-qm", "fixture");
}

async function parent() {
  if (!opts.scenario || !opts.out || !opts.a)
    throw new Error("--scenario, --a and --out are required");
  const harnesses = [opts.a, opts.b].filter(Boolean);
  const root = mkdtempSync(join(tmpdir(), "dieter-atrium-"));
  try {
    const home = join(root, "home");
    const project = join(root, "project");
    const runtimeRoot = join(root, "runtime");
    for (const d of [home, project, runtimeRoot]) mkdirSync(d, { recursive: true, mode: 0o700 });
    writeFixture(project);
    const env = {
      PATH: process.env.PATH,
      HOME: home,
      TMPDIR: process.env.TMPDIR || "/tmp",
      LANG: process.env.LANG || "en_US.UTF-8",
      USER: process.env.USER,
      SHELL: "/bin/zsh",
      TERM: "dumb",
      ...GIT_ENV,
    };
    if (harnesses.includes("claude-code")) env.CLAUDE_CODE_OAUTH_TOKEN = claudeAccessToken();
    if (harnesses.includes("codex")) opts["codex-model"] ||= codexDefaultModel();
    if (harnesses.includes("codex")) {
      env.CODEX_HOME = join(root, "codex-home");
      prepareCodexHome(env.CODEX_HOME, opts["codex-model"]);
    }
    if (harnesses.includes("codex")) opts["codex-model"] ||= codexDefaultModel();
    const passthrough = Object.entries(opts).flatMap(([k, v]) =>
      v === true ? [`--${k}`] : [`--${k}`, v],
    );
    const childArgs = [
      fileURLToPath(import.meta.url),
      ...passthrough.map((v, i, all) => (all[i - 1] === "--out" ? resolve(v) : v)),
      "--child",
      "--root",
      root,
    ];
    const code = await new Promise((done) => {
      const child = spawn(process.execPath, childArgs, {
        env,
        stdio: ["ignore", "inherit", "inherit"],
      });
      process.once("SIGINT", () => child.kill("SIGINT"));
      child.on("exit", (c, s) => done(c ?? (s ? 1 : 0)));
    });
    process.exitCode = code;
    const keep = `${resolve(opts.out)}.transcripts`;
    rmSync(keep, { recursive: true, force: true });
    mkdirSync(keep, { recursive: true });
    const found = execFileSync(
      "find",
      [root, "-name", "*.jsonl", "-path", "*projects*", "-o", "-name", "rollout-*.jsonl"],
      { encoding: "utf8" },
    )
      .split("\n")
      .filter(Boolean);
    for (const f of found) execFileSync("cp", [f, keep]);
    // Final repository state for the verification step.
    writeFileSync(
      join(keep, "git-log.txt"),
      execFileSync("git", ["log", "--stat", "-p", "--format=== %s"], {
        cwd: project,
        encoding: "utf8",
      }),
    );
    writeFileSync(
      join(keep, "git-status.txt"),
      execFileSync("git", ["status", "--short"], { cwd: project, encoding: "utf8" }),
    );
  } finally {
    rmSync(root, { recursive: true, force: true }); // copied auth, config dirs, bridge state
  }
}

// ─── Child ─────────────────────────────────────────────────────────────────

async function child() {
  process.chdir(runtimeDir);
  const t0 = Date.now();
  const out = opts.out;
  const log = (rec) => appendFileSync(out, JSON.stringify({ t: Date.now() - t0, ...rec }) + "\n");
  const imp = (p) => import(join(runtimeDir, p));
  const [
    { HarnessAgent },
    { tool },
    { z },
    { createLocalCodex },
    { createLocalClaudeCode },
    { createLocalSandboxProvider },
  ] = await Promise.all([
    imp("node_modules/@ai-sdk/harness/dist/agent/index.js"),
    imp("node_modules/ai/dist/index.js"),
    imp("node_modules/zod/index.js"),
    imp("codex-runtime.mjs"),
    imp("claude-runtime.mjs"),
    imp("local-sandbox.mjs"),
  ]);
  const root = opts.root;
  const project = join(root, "project");
  const scenario = opts.scenario;
  const useBoard = !opts["no-board"];
  log({
    kind: "config",
    scenario,
    a: opts.a,
    b: opts.b,
    useBoard,
    codexHooks: opts["codex-hooks"] || "thread",
  });

  // ── Board ────────────────────────────────────────────────────────────────
  const stats = {
    hookCalls: 0,
    hookMs: 0,
    hookOutputs: 0,
    denies: 0,
    contexts: 0,
    steers: 0,
    steerRejected: 0,
    wakes: 0,
    posts: 0,
    checks: 0,
    inboxReads: 0,
  };
  const agents = new Map();
  const posts = [];
  const claims = new Map(); // file → { agent, since }
  const FILE_RE = /(src\/module\d+\.js|README\.md|notes\.txt)/g;
  const MUTATING_RE =
    /\b(sed\s+-i|perl\s+-p?i|tee\b|mv\s|cp\s|rm\s|truncate\b|apply_patch|git\s+(add|commit|checkout|restore))|>>?\s*[\w./]/;

  const title = (id) => agents.get(id)?.title ?? id;
  const header = (p) =>
    `<dieter-channel-message id="${p.id}" from="agent ${p.from} '${title(p.from)}'" kind="${p.kind}"${p.to ? ` to="${p.to}"` : ""}>\n${p.text}\n</dieter-channel-message>`;

  function writtenFiles(toolName, toolInput) {
    const name = String(toolName || "");
    const raw = JSON.stringify(toolInput ?? {});
    const files = new Set(raw.match(FILE_RE) ?? []);
    if (/^(Edit|Write|MultiEdit|NotebookEdit|apply_patch)$/i.test(name)) return [...files];
    if (MUTATING_RE.test(raw)) return [...files];
    return [];
  }

  function deliver(id, post) {
    const a = agents.get(id);
    if (!a) return;
    if (a.running && a.push === "steer") {
      a.pendingSteer.push(post);
      a.steerTimer ??= setTimeout(() => flushSteer(a), 1000); // coalescing window
    } else {
      a.unread.push(post);
    }
  }

  async function flushSteer(a) {
    a.steerTimer = undefined;
    const batch = a.pendingSteer.splice(0);
    if (batch.length === 0) return;
    const text = batch.map(header).join("\n");
    try {
      await a.session.experimental_steerTurn(text);
      stats.steers++;
      log({ kind: "steer", to: a.id, posts: batch.map((p) => p.id), bytes: text.length });
    } catch (error) {
      stats.steerRejected++;
      a.unread.push(...batch);
      log({ kind: "steer-rejected", to: a.id, error: String(error?.message ?? error) });
    }
  }

  function post({ from, to, kind = "note", text, files }) {
    const p = { id: `m_${posts.length + 1}`, from, to, kind, text, files, t: Date.now() - t0 };
    posts.push(p);
    stats.posts += from !== "dieter" ? 1 : 0;
    log({ kind: "post", post: p });
    const recipients = to ? [to] : [...agents.keys()].filter((id) => id !== from);
    for (const r of recipients) if (r !== from) deliver(r, p);
    return p;
  }

  function check({ agent, files = [], intent = "" }) {
    stats.checks++;
    const lines = [];
    for (const f of files) {
      const c = claims.get(f);
      if (c && c.agent !== agent)
        lines.push(
          `${f}: being changed by agent ${c.agent} ('${title(c.agent)}') for ${Math.round((Date.now() - c.since) / 1000)} s.`,
        );
    }
    const history = posts
      .filter((p) => p.from !== agent && files.some((f) => p.text.includes(f)))
      .slice(-3)
      .map((p) => `${p.id} ${p.from} (${p.kind}): ${p.text}`);
    if (history.length) lines.push("Recent notes about these files:", ...history);
    const unread = agents.get(agent)?.unread.length ?? 0;
    if (unread) lines.push(`${unread} unread message(s); read them with channel_inbox.`);
    for (const f of files) {
      const c = claims.get(f);
      if (c && c.agent !== agent) agents.get(agent)?.waitingOn.add(f);
    }
    log({ kind: "check", agent, files, intent, conflicts: lines.length });
    return lines.length ? lines.join("\n") : "No other agent is working on these files.";
  }

  function hook({ agent, input }) {
    const event = input.hook_event_name;
    const a = agents.get(agent);
    const files = writtenFiles(input.tool_name, input.tool_input);
    log({
      kind: "hook",
      agent,
      event,
      tool: input.tool_name,
      files,
      keys: Object.keys(input.tool_input ?? {}),
    });
    if (!useBoard || !a) return "";
    if (event === "PreToolUse" && files.length) {
      const held = files.map((f) => [f, claims.get(f)]).filter(([, c]) => c && c.agent !== agent);
      if (held.length) {
        stats.denies++;
        const [f, c] = held[0];
        a.waitingOn.add(f);
        if (!c.notified?.has(agent)) {
          (c.notified ??= new Set()).add(agent);
          post({
            from: "dieter",
            to: c.agent,
            kind: "request",
            text: `Agent ${agent} ('${title(agent)}') wants to change ${f}, which you hold. Finish your work on it; it is released when your turn ends.`,
          });
        }
        const reason =
          `Dieter channels: ${f} is being changed by agent ${c.agent} ('${title(c.agent)}') for ${Math.round((Date.now() - c.since) / 1000)} s. ` +
          `Do the other parts of your task first. If nothing else is left, end your turn with a one-line status; ` +
          `you will be woken when ${f} is free. Do not poll or sleep. You can message ${c.agent} with channel_post.`;
        return JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: reason,
          },
        });
      }
      for (const f of files) if (!claims.has(f)) claims.set(f, { agent, since: Date.now() });
      return "";
    }
    if (event === "PostToolUse" && a.push === "hook" && a.unread.length) {
      const batch = a.unread.splice(0);
      stats.contexts++;
      log({ kind: "hook-push", to: agent, posts: batch.map((p) => p.id) });
      return JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: batch.map(header).join("\n"),
        },
      });
    }
    return "";
  }

  // Releasing claims at turn end is Atrium's "here are my changes": waiting
  // agents get a push (steer if running) or a wake (if idle).
  function release(agent, summary) {
    const freed = [...claims].filter(([, c]) => c.agent === agent).map(([f]) => f);
    for (const f of freed) claims.delete(f);
    if (!freed.length) return;
    log({ kind: "release", agent, files: freed });
    for (const other of agents.values()) {
      const waited = freed.filter((f) => other.waitingOn.has(f));
      if (!waited.length) continue;
      for (const f of waited) other.waitingOn.delete(f);
      post({
        from: "dieter",
        to: other.id,
        kind: "release",
        text: `${waited.join(", ")} is free now: agent ${agent} finished (${summary.slice(0, 160)}).`,
      });
      if (!other.running) other.wake?.();
    }
  }

  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const started = Date.now();
      let reply = "";
      try {
        const msg = JSON.parse(body || "{}");
        if (req.url === "/hook") {
          stats.hookCalls++;
          if (msg.spawnMs != null) stats.hookSpawnMs = (stats.hookSpawnMs ?? 0) + msg.spawnMs;
          reply = hook(msg);
          if (reply) stats.hookOutputs++;
        }
      } catch (error) {
        log({ kind: "board-error", error: String(error?.message ?? error) });
      }
      stats.hookMs += Date.now() - started;
      res.end(reply);
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const boardUrl = `http://127.0.0.1:${server.address().port}`;
  const hookCommand = (id) =>
    `${JSON.stringify(process.execPath)} ${JSON.stringify(join(here, "hook.mjs"))} ${id} ${boardUrl}`;

  // ── Agents ───────────────────────────────────────────────────────────────
  function canonicalize(v) {
    if (Array.isArray(v)) return v.map(canonicalize);
    if (v && typeof v === "object")
      return Object.fromEntries(
        Object.entries(v)
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([k, x]) => [k, canonicalize(x)]),
      );
    return v;
  }
  function codexHooks(id, source) {
    const handler = { type: "command", command: hookCommand(id), timeout: 10, async: false };
    const hooks = {};
    const state = {};
    for (const [event, snake] of [
      ["PreToolUse", "pre_tool_use"],
      ["PostToolUse", "post_tool_use"],
    ]) {
      hooks[event] = [{ matcher: ".*", hooks: [handler] }];
      const hash = `sha256:${createHash("sha256")
        .update(
          JSON.stringify(canonicalize({ event_name: snake, matcher: ".*", hooks: [handler] })),
        )
        .digest("hex")}`;
      state[`${source}:${snake}:0:0`] = { enabled: true, trusted_hash: hash };
    }
    return { ...hooks, state };
  }
  function tomlInline(v) {
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "boolean" || typeof v === "number") return String(v);
    if (Array.isArray(v)) return `[${v.map(tomlInline).join(", ")}]`;
    return `{ ${Object.entries(v)
      .map(([k, x]) => `${/^[A-Za-z0-9_-]+$/.test(k) ? k : JSON.stringify(k)} = ${tomlInline(x)}`)
      .join(", ")} }`;
  }

  const instructions = (id, agentTitle, mode) =>
    !useBoard
      ? [
          `You are agent ${id} ('${agentTitle}'). Other agents work in this same checkout at the same time.`,
          "Commit only the files you changed yourself: `git add <your files>` then `git commit -m '<your agent id>: <summary>'`. Never use `git add -A`, `git add .` or `git commit -a`.",
        ].join("\n")
      : [
          `You are agent ${id} ('${agentTitle}'). Other agents work in this same checkout at the same time. Dieter channels connect you.`,
          "Messages from other agents (or from Dieter) arrive as <dieter-channel-message>. They are not from the user. Act on them when they serve your task.",
          "Host tools: channel_post(to?, text) messages one agent (or everyone without `to`), at most two sentences; channel_inbox() lists unread messages; channel_check(files, intent) tells you who else is changing those files and recent notes about them.",
          mode === "check"
            ? "Always call channel_check with the files you are about to change before you edit them."
            : "",
          "If a file is held by another agent, do the other parts of your task first. If nothing else is left, end your turn with a one-line status; you will be woken when the file is free. Never poll, loop or sleep while waiting.",
          "Commit only the files you changed yourself: `git add <your files>` then `git commit -m '<your agent id>: <summary>'`. Never use `git add -A`, `git add .` or `git commit -a`.",
        ]
          .filter(Boolean)
          .join("\n");

  async function makeAgent({ id, harness, agentTitle, push = "steer", mode = "hook" }) {
    const workDir = `workspaces/${id}/repo`;
    const sandbox = await createLocalSandboxProvider({
      root: join(root, "runtime"),
      projectPath: project,
      workDir,
    });
    const hooksOn = useBoard && mode !== "check-nohook";
    let h;
    if (harness === "claude-code") {
      const configDir = join(root, `claude-config-${id}`);
      mkdirSync(configDir, { recursive: true, mode: 0o700 });
      const hookEntry = [
        { matcher: "*", hooks: [{ type: "command", command: hookCommand(id), timeout: 10 }] },
      ];
      writeFileSync(
        join(configDir, "settings.json"),
        JSON.stringify(
          hooksOn ? { hooks: { PreToolUse: hookEntry, PostToolUse: hookEntry } } : {},
          null,
          2,
        ),
      );
      const managed = opts["claude-hooks"] === "managed";
      if (managed) {
        // Product candidate: hooks in a per-turn managed-settings file, user config untouched.
        writeFileSync(join(configDir, "settings.json"), "{}");
        const file = join(root, `managed-${id}`);
        mkdirSync(file, { recursive: true });
        writeFileSync(
          join(file, "managed-settings.json"),
          JSON.stringify({
            hooks: hooksOn ? { PreToolUse: hookEntry, PostToolUse: hookEntry } : {},
          }),
        );
        h = createLocalClaudeCode({
          effort: "low",
          env: { CLAUDE_CONFIG_DIR: configDir, CLAUDE_CODE_MANAGED_SETTINGS_PATH: file },
        });
      } else h = createLocalClaudeCode({ effort: "low", env: { CLAUDE_CONFIG_DIR: configDir } });
    } else {
      const route = opts["codex-hooks"] || "thread";
      let codexConfig = { features: { fast_mode: true, ...(hooksOn ? { hooks: true } : {}) } };
      if (hooksOn && route === "thread")
        codexConfig.hooks = codexHooks(id, "/<session-flags>/config.toml");
      if (hooksOn && route === "home") {
        const file = realpathSync(join(process.env.CODEX_HOME, "config.toml"));
        appendFileSync(
          file,
          `\n[features]\nhooks = true\n\n[hooks]\n${Object.entries(codexHooks(id, file))
            .map(([k, v]) => `${k} = ${tomlInline(v)}`)
            .join("\n")}\n`,
        );
      }
      h = createLocalCodex({ reasoningEffort: "low", codexConfig });
    }
    const a = {
      id,
      harness,
      title: agentTitle,
      push,
      running: false,
      unread: [],
      pendingSteer: [],
      waitingOn: new Set(),
      turns: [],
    };
    const channelTools = {
      channel_post: tool({
        description: "Post a short message to another agent (to) or to everyone on this project.",
        inputSchema: z.object({ to: z.string().optional(), text: z.string() }),
        execute: async ({ to, text }) => {
          const p = post({ from: id, to, text });
          return `posted ${p.id}`;
        },
      }),
      channel_inbox: tool({
        description: "List unread channel messages for you.",
        inputSchema: z.object({}),
        execute: async () => {
          stats.inboxReads++;
          const batch = a.unread.splice(0);
          return batch.length ? batch.map(header).join("\n") : "No unread messages.";
        },
      }),
      channel_check: tool({
        description:
          "Before changing files: who else is changing them, and recent notes about them.",
        inputSchema: z.object({ files: z.array(z.string()), intent: z.string().optional() }),
        execute: async ({ files, intent }) => check({ agent: id, files, intent }),
      }),
    };
    a.agent = new HarnessAgent({
      harness: h,
      sandbox,
      model:
        harness === "claude-code"
          ? opts["claude-model"] || "claude-sonnet-5-5"
          : opts["codex-model"],
      instructions: instructions(
        id,
        agentTitle,
        mode === "check" || mode === "check-nohook" ? "check" : "hook",
      ),
      tools: useBoard ? channelTools : {},
      permissionMode: "allow-all",
      sandboxConfig: { workDir },
    });
    a.session = await a.agent.createSession({ sessionId: `atrium-${id}` });
    agents.set(id, a);
    return a;
  }

  async function runTurn(a, prompt, label) {
    a.running = true;
    const turn = { label, started: Date.now() - t0, steps: [], tools: [], text: "" };
    try {
      const result = await a.agent.stream({ session: a.session, prompt });
      for await (const part of result.stream) {
        const now = Date.now() - t0;
        if (part.type === "text-delta") turn.text += part.text ?? part.delta ?? "";
        else if (part.type === "tool-call") {
          turn.tools.push(part.toolName);
          log({
            kind: "tool-call",
            agent: a.id,
            name: part.toolName,
            input: JSON.stringify(part.input).slice(0, 220),
          });
        } else if (part.type === "tool-result")
          log({
            kind: "tool-result",
            agent: a.id,
            name: part.toolName,
            output: JSON.stringify(part.output).slice(0, 220),
          });
        else if (part.type === "finish-step") turn.steps.push(part.usage);
        else if (part.type === "finish") turn.totalUsage = part.totalUsage;
        else if (part.type === "error")
          log({
            kind: "stream-error",
            agent: a.id,
            error: String(part.error?.message ?? part.error),
          });
        void now;
      }
    } finally {
      a.running = false;
    }
    turn.ended = Date.now() - t0;
    a.turns.push(turn);
    log({
      kind: "turn-end",
      agent: a.id,
      label,
      ms: turn.ended - turn.started,
      tools: turn.tools,
      totalUsage: turn.totalUsage,
      text: turn.text.slice(-400),
    });
    return turn;
  }

  // Runs an agent's task; a released claim wakes it for at most two more
  // turns, each prompted only with its digest (bounded, like Dieter's queue).
  async function lifecycle(a, prompt) {
    let wakeResolve;
    const pendingWakes = [];
    a.wake = () => {
      stats.wakes++;
      pendingWakes.push(1);
      wakeResolve?.();
    };
    await runTurn(a, prompt, "task");
    release(a.id, a.turns.at(-1).text.trim().split("\n").at(-1) || "done");
    for (let i = 0; i < 2; i++) {
      if (!pendingWakes.length && a.waitingOn.size) {
        // Wait (no model calls) until a release wakes us or the others finish.
        await new Promise((r) => {
          wakeResolve = r;
          lifecycle.idleWaiters.push(r);
        });
      }
      if (!pendingWakes.length && !a.unread.length) break;
      pendingWakes.length = 0;
      const digest = a.unread.splice(0).map(header).join("\n");
      log({ kind: "wake", agent: a.id, bytes: digest.length });
      await runTurn(
        a,
        `${digest}\nContinue your original task where you left off.`,
        `wake-${i + 1}`,
      );
      release(a.id, a.turns.at(-1).text.trim().split("\n").at(-1) || "done");
    }
    a.done = true;
    if ([...agents.values()].every((x) => x.done || x.waitingOn.size))
      for (const r of lifecycle.idleWaiters.splice(0)) r();
  }
  lifecycle.idleWaiters = [];

  const summary = { scenario, useBoard };
  const seedClaim = () => {
    agents.set("Z", {
      id: "Z",
      title: "Refactor tier pricing in module3",
      push: "none",
      running: true,
      unread: [],
      pendingSteer: [],
      waitingOn: new Set(),
      turns: [],
    });
    claims.set("src/module3.js", { agent: "Z", since: Date.now() });
    posts.push({
      id: "m_0",
      from: "Z",
      kind: "decision",
      text: "src/module3.js rules must stay pure functions; no I/O.",
      t: 0,
    });
  };
  const soloTask =
    "Append the line `// reviewed` at the end of src/module2.js and at the end of src/module3.js, then commit both files with message 'S: review comments'.";

  if (scenario === "probe") {
    seedClaim();
    const a = await makeAgent({ id: "S", harness: opts.a, agentTitle: "Probe" });
    await runTurn(
      a,
      "Create a file notes.txt containing `hi` with your file editing tool. Then append `// probe` to the end of src/module3.js. Report what happened in one line.",
      "probe",
    );
  } else if (scenario === "pull-check" || scenario === "pull-hook") {
    seedClaim();
    const mode =
      scenario === "pull-check" ? (opts["with-hooks"] ? "check" : "check-nohook") : "hook";
    const a = await makeAgent({
      id: "S",
      harness: opts.a,
      agentTitle: "Add review comments",
      mode,
    });
    // Z finishes 20 s after S starts, so S is either still running (push) or idle (wake).
    setTimeout(
      () => {
        agents.get("Z").running = false;
        release("Z", "tier pricing refactor merged");
      },
      Number(opts["release-after"] || 20000),
    );
    await lifecycle(a, soloTask);
  } else if (scenario === "push-hook" || scenario === "push-steer") {
    const push = scenario === "push-hook" ? "hook" : "steer";
    const a = await makeAgent({ id: "S", harness: opts.a, agentTitle: "Step runner", push });
    agents.set("R", {
      id: "R",
      title: "Release agent",
      push: "none",
      running: true,
      unread: [],
      pendingSteer: [],
      waitingOn: new Set(),
      turns: [],
    });
    let sent = false;
    const prompt =
      "Run exactly these five shell commands in order, one per tool call: `sleep 2 && echo step-1` … `sleep 2 && echo step-5` (replace … with steps 2-4). After each, write one short line. " +
      "At the end write DONE followed by the release tag that the release agent announces on the channel while you work (write DONE none if no tag arrived).";
    setTimeout(() => {
      sent = true;
      post({ from: "R", to: "S", kind: "note", text: "Release tag for this run: PAPAYA-7." });
    }, 9000);
    await runTurn(a, prompt, "task");
    summary.papaya = /PAPAYA/.test(a.turns[0].text);
    summary.sent = sent;
  } else if (scenario === "pair") {
    const A = await makeAgent({
      id: "A",
      harness: opts.a,
      agentTitle: "Review headers of modules 3, 4, 6, 7",
    });
    const B = await makeAgent({
      id: "B",
      harness: opts.b || opts.a,
      agentTitle: "Add MAX_TIER_3 and module5 owner",
    });
    const taskA =
      "For each of src/module3.js, src/module4.js, src/module6.js and src/module7.js, one file at a time: append ' (reviewed)' to the comment on line 1, then run `sleep 3 && echo checked`. When all four are done, commit them with message 'A: review headers'.";
    const taskB =
      "Add the line `export const MAX_TIER_3 = 39;` at the end of src/module3.js, and append ' (owner: B)' to the comment on line 1 of src/module5.js. Then commit your changes with message 'B: tier cap and owner'.";
    // Stagger B by 2 s: simultaneous Claude turn starts under one HOME race on
    // @ai-sdk/harness's skills manifest (fixed .tmp name + mv), see results.
    await Promise.all([
      lifecycle(A, taskA),
      new Promise((r) => setTimeout(r, 2000)).then(() => lifecycle(B, taskB)),
    ]);
  } else {
    throw new Error(`unknown scenario ${scenario}`);
  }

  // ── Verification ─────────────────────────────────────────────────────────
  const file = (f) => readFileSync(join(project, f), "utf8");
  const git = (...a) => execFileSync("git", a, { cwd: project, encoding: "utf8" });
  summary.files = {};
  for (const f of [
    "src/module2.js",
    "src/module3.js",
    "src/module4.js",
    "src/module5.js",
    "src/module6.js",
    "src/module7.js",
  ]) {
    const text = file(f);
    summary.files[f] = {
      header: text.split("\n")[0],
      reviewedLine: /\/\/ reviewed\s*$/.test(text.trimEnd().split("\n").at(-1)) ? true : undefined,
      maxTier: text.includes("MAX_TIER_3") ? true : undefined,
    };
  }
  summary.commits = git("log", "--format=%s", "--name-only", "-n", "6").trim().split("\n\n");
  try {
    // Which commit introduced MAX_TIER_3 (cross-attribution check)?
    summary.maxTierCommit = git("log", "-S", "MAX_TIER_3", "--format=%s").trim();
    summary.reviewedHeaderCommit = git(
      "log",
      "-S",
      "(reviewed)",
      "--format=%s",
      "--",
      "src/module3.js",
    ).trim();
  } catch {}
  summary.dirty = git("status", "--short").trim();
  summary.stats = stats;
  summary.agents = [...agents.values()]
    .filter((a) => a.agent)
    .map((a) => ({
      id: a.id,
      harness: a.harness,
      turns: a.turns.map((t) => ({
        label: t.label,
        ms: t.ended - t.started,
        requests: t.steps.filter((u) => u?.inputTokens > 0).length,
        tools: t.tools,
        totalUsage: t.totalUsage,
        tail: t.text.slice(-240),
      })),
    }));
  summary.posts = posts.map(
    (p) => `${p.id} ${p.from}→${p.to ?? "*"} ${p.kind}: ${p.text.slice(0, 140)}`,
  );
  log({ kind: "summary", summary });
  for (const a of agents.values()) await a.session?.stop().catch(() => {});
  server.close();
  process.exit(0);
}

try {
  if (opts.child) await child();
  else await parent();
} catch (error) {
  console.error(`atrium: ${error?.stack ?? error}`);
  if (opts.child && opts.out)
    appendFileSync(
      opts.out,
      JSON.stringify({ kind: "fatal", error: String(error?.stack ?? error) }) + "\n",
    );
  process.exit(1);
}
