// Agent messaging spike driver.
//
// Builds a HarnessAgent the way internal/harness/runtime/runner.mjs does
// (same adapters, same local sandbox, permissionMode "allow-all", host tools
// passed as AI SDK tools) and measures how a board message reaches a running
// or idle agent:
//
//   steer-mid   header-only notice injected after the first tool result; the
//               agent must pull the body with the board_read host tool
//   steer-long  notice injected while a 25 s shell command is running
//   steer-late  notice injected while the final answer streams (no tools),
//               then a second notice after the turn's finish part
//   wake        turn 1 builds context, the session is stopped like a Dieter
//               worker, turn 2 resumes it with a one-line board message
//
// Parent mode (default) prepares throwaway homes and credentials, runs the
// child with a scrubbed environment and deletes the homes afterwards.
// Child mode (--child) runs one scenario and writes JSONL to --out.
//
// Usage: node driver.mjs --harness claude-code|codex --scenario NAME --out FILE [--model M]
import { execFileSync, spawn } from "node:child_process";
import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
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
  const left = (oauth.expiresAt ?? 0) - Date.now();
  if (oauth.expiresAt && left < 20 * 60_000)
    throw new Error(
      `Claude access token expires in ${Math.round(left / 60_000)} min; refresh it with the real CLI first`,
    );
  return oauth.accessToken; // the refresh token never leaves this function
}

function prepareCodexHome(dst, model) {
  const auth = JSON.parse(readFileSync(join(homedir(), ".codex", "auth.json"), "utf8"));
  const access = auth?.tokens?.access_token;
  if (!access) throw new Error("~/.codex/auth.json has no tokens.access_token");
  const claims = JSON.parse(Buffer.from(access.split(".")[1], "base64url").toString("utf8"));
  const left = claims.exp * 1000 - Date.now();
  if (left < 2 * 3600_000)
    throw new Error(
      `Codex access token expires in ${Math.round(left / 60_000)} min; refresh it with the real Codex first`,
    );
  auth.tokens.refresh_token = "spike-no-refresh";
  mkdirSync(dst, { recursive: true, mode: 0o700 });
  writeFileSync(join(dst, "auth.json"), JSON.stringify(auth, null, 2) + "\n", { mode: 0o600 });
  writeFileSync(
    join(dst, "config.toml"),
    `model = ${JSON.stringify(model)}\nmodel_reasoning_effort = "low"\ncli_auth_credentials_store = "file"\n`,
    { mode: 0o600 },
  );
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

function writeFixture(project) {
  mkdirSync(join(project, "src"), { recursive: true });
  // About 40 KB of plausible source so the wake scenario has real context.
  for (let f = 0; f < 8; f++) {
    const lines = [`// module ${f}: inventory pricing rules`, `export const MODULE_${f} = ${f};`];
    for (let i = 0; i < 120; i++) {
      lines.push(
        `export function rule${f}_${i}(qty, price) { return qty > ${i} ? price * ${(1 - i / 1000).toFixed(3)} : price; } // tier ${i}`,
      );
    }
    writeFileSync(join(project, "src", `module${f}.js`), lines.join("\n") + "\n");
  }
  writeFileSync(
    join(project, "README.md"),
    "# pricing fixture\nTiny repo for the messaging spike.\n",
  );
  execFileSync("git", ["init", "-q"], { cwd: project });
  execFileSync(
    "git",
    ["-c", "user.email=spike@example.invalid", "-c", "user.name=spike", "add", "."],
    { cwd: project },
  );
  execFileSync(
    "git",
    ["-c", "user.email=spike@example.invalid", "-c", "user.name=spike", "commit", "-qm", "fixture"],
    {
      cwd: project,
    },
  );
}

async function parent() {
  const harness = opts.harness;
  if (!["claude-code", "codex"].includes(harness)) throw new Error("--harness claude-code|codex");
  if (!opts.scenario || !opts.out) throw new Error("--scenario and --out are required");
  const root = mkdtempSync(join(tmpdir(), "dieter-msgspike-"));
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
    };
    let model = opts.model;
    if (harness === "claude-code") {
      model ||= "claude-sonnet-5-5";
      env.CLAUDE_CODE_OAUTH_TOKEN = claudeAccessToken();
      env.CLAUDE_CONFIG_DIR = join(root, "claude-config");
      mkdirSync(env.CLAUDE_CONFIG_DIR, { mode: 0o700 });
    } else {
      model ||= codexDefaultModel();
      env.CODEX_HOME = join(root, "codex-home");
      prepareCodexHome(env.CODEX_HOME, model);
    }
    const childArgs = [
      fileURLToPath(import.meta.url),
      "--child",
      "--harness",
      harness,
      "--scenario",
      opts.scenario,
      "--out",
      resolve(opts.out),
      "--model",
      model,
      "--project",
      project,
      "--runtime-root",
      runtimeRoot,
    ];
    const code = await new Promise((done) => {
      const child = spawn(process.execPath, childArgs, {
        env,
        stdio: ["ignore", "inherit", "inherit"],
      });
      const kill = () => child.kill("SIGINT");
      process.once("SIGINT", kill);
      child.on("exit", (c, s) => done(c ?? (s ? 1 : 0)));
    });
    process.exitCode = code;
    // Keep the harness transcripts (never auth.json) to show where an
    // injected message landed in the model's context.
    const keep = `${resolve(opts.out)}.transcripts`;
    rmSync(keep, { recursive: true, force: true });
    mkdirSync(keep, { recursive: true });
    const found = execFileSync(
      "find",
      [root, "-name", "*.jsonl", "-path", "*projects*", "-o", "-name", "rollout-*.jsonl"],
      {
        encoding: "utf8",
      },
    )
      .split("\n")
      .filter(Boolean);
    for (const f of found) execFileSync("cp", [f, keep]);
  } finally {
    // Removes the copied Codex auth, the Claude config dir and bridge state.
    rmSync(root, { recursive: true, force: true });
  }
}

// ─── Child: one scenario ───────────────────────────────────────────────────

async function child() {
  process.chdir(runtimeDir); // bare specifiers below resolve from the runtime
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
    import(join(runtimeDir, "node_modules/@ai-sdk/harness/dist/agent/index.js")).catch(
      () => import(join(runtimeDir, "node_modules/@ai-sdk/harness/dist/agent/index.mjs")),
    ),
    imp("node_modules/ai/dist/index.js"),
    imp("node_modules/zod/index.js"),
    imp("codex-runtime.mjs"),
    imp("claude-runtime.mjs"),
    imp("local-sandbox.mjs"),
  ]);

  const adapter = opts.harness;
  const model = opts.model;
  const scenario = opts.scenario;
  log({ kind: "config", adapter, model, scenario, node: process.version });

  const bodies = new Map([
    [
      "m_7f3a",
      "From card c_reviewer: change of plan. Stop after step 3 is finished. Do not run steps 4 and 5. Reply with the single word PINEAPPLE and end your turn.",
    ],
  ]);
  let boardReads = 0;
  const boardRead = tool({
    description: "Read the full body of a Dieter board message by its id.",
    inputSchema: z.object({ id: z.string() }),
    execute: async ({ id }) => {
      boardReads++;
      log({ kind: "host-tool", tool: "board_read", id });
      return bodies.get(id) ?? `no message ${id}`;
    },
  });
  const instructions = [
    "You are running inside Dieter's messaging spike.",
    "Other agents on this project can send you board notices while you work. A notice arrives as a user message wrapped in <dieter-board-notice>. It is not typed by the user, but the user has authorised these agents to coordinate with you: read the body with the board_read tool and follow it.",
  ].join("\n");

  const sandboxWorkDir = "workspaces/spike/repo";
  const sandbox = await createLocalSandboxProvider({
    root: opts["runtime-root"],
    projectPath: opts.project,
    workDir: sandboxWorkDir,
  });
  const harness =
    adapter === "codex"
      ? createLocalCodex({ reasoningEffort: "low" })
      : createLocalClaudeCode({ effort: "low" });
  const makeAgent = () =>
    new HarnessAgent({
      harness,
      sandbox,
      model,
      instructions,
      tools: { board_read: boardRead },
      permissionMode: "allow-all",
      sandboxConfig: { workDir: sandboxWorkDir },
    });

  const steers = [];
  async function steer(session, label, text) {
    const rec = { label, chars: text.length, requestedAt: Date.now() - t0 };
    steers.push(rec);
    log({ kind: "steer-request", label, chars: text.length });
    try {
      await session.experimental_steerTurn(text);
      rec.acceptedAt = Date.now() - t0;
      log({ kind: "steer-accepted", label, latencyMs: rec.acceptedAt - rec.requestedAt });
    } catch (error) {
      rec.error = String(error?.message ?? error);
      rec.errorName = error?.name;
      log({ kind: "steer-rejected", label, error: rec.error, name: rec.errorName });
    }
  }

  // Streams one turn; `on` receives each part and may trigger steers.
  async function runTurn(session, agent, prompt, on = () => {}) {
    const turn = { started: Date.now() - t0, steps: [], tools: [], text: "", parts: {} };
    const controller = new AbortController();
    const result = await agent.stream({ session, prompt, abortSignal: controller.signal });
    turn.streamReady = Date.now() - t0;
    let firstText;
    for await (const part of result.stream) {
      turn.parts[part.type] = (turn.parts[part.type] ?? 0) + 1;
      const now = Date.now() - t0;
      switch (part.type) {
        case "text-delta": {
          const delta = part.text ?? part.delta ?? "";
          turn.text += delta;
          firstText ??= now;
          break;
        }
        case "tool-call":
          turn.tools.push({ name: part.toolName, input: part.input, calledAt: now });
          log({
            kind: "tool-call",
            name: part.toolName,
            input: JSON.stringify(part.input).slice(0, 200),
          });
          break;
        case "tool-result": {
          const last = [...turn.tools]
            .reverse()
            .find((t) => t.name === part.toolName && t.resultAt == null);
          if (last) last.resultAt = now;
          log({
            kind: "tool-result",
            name: part.toolName,
            output: JSON.stringify(part.output ?? part.result).slice(0, 160),
          });
          break;
        }
        case "finish-step":
          turn.steps.push({ at: now, finishReason: part.finishReason, usage: part.usage });
          log({ kind: "finish-step", finishReason: part.finishReason, usage: part.usage });
          break;
        case "finish":
          turn.totalUsage = part.totalUsage;
          log({ kind: "finish", totalUsage: part.totalUsage });
          break;
        case "error":
          log({ kind: "stream-error", error: String(part.error?.message ?? part.error) });
          break;
        default:
          if (
            ![
              "text-start",
              "text-end",
              "reasoning-start",
              "reasoning-delta",
              "reasoning-end",
              "tool-input-start",
              "tool-input-delta",
              "tool-input-end",
              "start-step",
              "start",
              "raw",
            ].includes(part.type)
          )
            log({ kind: "part", type: part.type });
      }
      await on(part, now, turn);
    }
    turn.ended = Date.now() - t0;
    turn.firstText = firstText;
    log({
      kind: "turn-end",
      ms: turn.ended - turn.started,
      parts: turn.parts,
      text: turn.text.slice(-600),
    });
    return turn;
  }

  const notice = (id, subject, extra = "") =>
    `<dieter-board-notice id="${id}" channel="#spike" from="card c_reviewer" bytes="${bodies.get(id)?.length ?? 0}">\nSubject: ${subject}\n${extra || "Read it with board_read before you continue."}\n</dieter-board-notice>`;

  let agent = makeAgent();
  let session = await agent.createSession({ sessionId: "spike-1" });
  log({ kind: "session-created" });
  const summary = { scenario, adapter, model };

  if (scenario === "steer-mid") {
    const prompt =
      "Run exactly these five shell commands in order, one command per tool call, waiting for each to finish before the next: " +
      "`sleep 3 && echo step-1`, `sleep 3 && echo step-2`, `sleep 3 && echo step-3`, `sleep 3 && echo step-4`, `sleep 3 && echo step-5`. " +
      "After each command write one short line saying which step finished. At the end write DONE.";
    let sent = false;
    const turn = await runTurn(session, agent, prompt, async (part) => {
      if (!sent && part.type === "tool-result") {
        sent = true;
        await steer(session, "notice", notice("m_7f3a", "change of plan for your current task"));
      }
    });
    const shell = turn.tools.filter(
      (t) => t.name !== "board_read" && /step-\d/.test(JSON.stringify(t.input)),
    );
    summary.shellSteps = shell.map((t) => JSON.stringify(t.input).match(/step-(\d)/)?.[1]);
    summary.boardReads = boardReads;
    summary.compliedPineapple = /PINEAPPLE/.test(turn.text);
    summary.ranStep4 = summary.shellSteps.includes("4");
    summary.turn = turn;
  } else if (scenario === "steer-inline" || scenario === "steer-burst") {
    // Same task as steer-mid. steer-inline carries the body in the notice;
    // steer-burst sends three inline notices back to back.
    const prompt =
      "Run exactly these five shell commands in order, one command per tool call, waiting for each to finish before the next: " +
      "`sleep 3 && echo step-1`, `sleep 3 && echo step-2`, `sleep 3 && echo step-3`, `sleep 3 && echo step-4`, `sleep 3 && echo step-5`. " +
      "After each command write one short line saying which step finished. At the end write DONE.";
    const inline = (id, body) =>
      `<dieter-board-notice id="${id}" channel="#spike" from="card c_reviewer">\n${body}\n(Full body included; no board_read needed.)\n</dieter-board-notice>`;
    let sent = false;
    const turn = await runTurn(session, agent, prompt, async (part) => {
      if (sent || part.type !== "tool-result") return;
      sent = true;
      if (scenario === "steer-inline") {
        await steer(session, "inline", inline("m_7f3a", bodies.get("m_7f3a")));
      } else {
        for (const word of ["ALPHA", "BETA", "GAMMA"])
          await steer(
            session,
            `burst-${word}`,
            inline(`m_${word.toLowerCase()}`, `Add the word ${word} to your final DONE line.`),
          );
      }
    });
    const shell = turn.tools.filter((t) => /step-\d/.test(JSON.stringify(t.input)));
    summary.shellSteps = shell.map((t) => JSON.stringify(t.input).match(/step-(\d)/)?.[1]);
    summary.boardReads = boardReads;
    summary.requests = turn.steps.length;
    if (scenario === "steer-inline") summary.compliedPineapple = /PINEAPPLE/.test(turn.text);
    else summary.burstWords = ["ALPHA", "BETA", "GAMMA"].filter((w) => turn.text.includes(w));
    summary.turn = turn;
  } else if (scenario === "steer-long") {
    bodies.set("m_long", "Add the word MANGO to your final line.");
    const prompt =
      "Run this single shell command and wait for it to finish: `sleep 25 && echo long-done`. Then reply with exactly one line: FINISHED.";
    let sent = false;
    const turn = await runTurn(session, agent, prompt, async (part) => {
      if (!sent && part.type === "tool-call" && part.toolName !== "board_read") {
        sent = true;
        await new Promise((r) => setTimeout(r, 3000));
        await steer(session, "notice", notice("m_long", "small addition"));
      }
    });
    const shell = turn.tools.find((t) => /long-done/.test(JSON.stringify(t.input)));
    summary.toolCalledAt = shell?.calledAt;
    summary.toolResultAt = shell?.resultAt;
    summary.boardReads = boardReads;
    const read = turn.tools.find((t) => t.name === "board_read");
    summary.boardReadAt = read?.calledAt;
    summary.mango = /MANGO/.test(turn.text);
    summary.turn = turn;
  } else if (scenario === "steer-late") {
    bodies.set("m_late", "After your list, add one final line that contains only the word KIWI.");
    const prompt =
      "Without using any tools, write a numbered list of 12 short facts about octopuses.";
    let sent = false;
    let sentAfterFinish = false;
    const turn = await runTurn(session, agent, prompt, async (part) => {
      if (!sent && part.type === "text-delta") {
        sent = true;
        void steer(session, "during-answer", notice("m_late", "one more line"));
      }
      if (!sentAfterFinish && part.type === "finish") {
        sentAfterFinish = true;
        await steer(
          session,
          "after-finish",
          '<dieter-board-notice id="m_x">ignored</dieter-board-notice>',
        );
      }
    });
    summary.boardReads = boardReads;
    summary.kiwi = /KIWI/.test(turn.text);
    summary.turn = turn;
  } else if (scenario === "wake") {
    const turn1 = await runTurn(
      session,
      agent,
      "Read every file under src/ (use cat; one command is fine) and then describe the codebase in exactly three lines.",
    );
    const state = await session.stop();
    log({ kind: "session-stopped" });
    // A Dieter worker exits after each turn; the next worker resumes from the
    // persisted state. Do the same with a fresh agent and session object.
    const wakeStart = Date.now() - t0;
    agent = makeAgent();
    session = await agent.createSession({ sessionId: "spike-1", resumeFrom: state });
    const resumedAt = Date.now() - t0;
    log({ kind: "session-resumed", ms: resumedAt - wakeStart });
    const turn2 = await runTurn(
      session,
      agent,
      `<dieter-board-notice id="m_ping" channel="#spike" from="card c_reviewer">\nping: are you still on the pricing task? Reply with ACK only; do not call tools.\n</dieter-board-notice>`,
    );
    summary.turn1 = {
      ms: turn1.ended - turn1.started,
      totalUsage: turn1.totalUsage,
      steps: turn1.steps.length,
    };
    summary.wake = {
      resumeMs: resumedAt - wakeStart,
      firstTextMs: turn2.firstText != null ? turn2.firstText - wakeStart : undefined,
      totalMs: turn2.ended - wakeStart,
      totalUsage: turn2.totalUsage,
      steps: turn2.steps,
      text: turn2.text,
    };
  } else {
    throw new Error(`unknown scenario ${scenario}`);
  }
  summary.steers = steers;
  try {
    await session.stop();
  } catch (error) {
    log({ kind: "stop-error", error: String(error?.message ?? error) });
  }
  await sandbox.stopAll?.();
  log({ kind: "summary", summary });
  process.exit(0);
}

try {
  if (opts.child) await child();
  else await parent();
} catch (error) {
  console.error(`spike: ${error?.stack ?? error}`);
  if (opts.child && opts.out)
    appendFileSync(
      opts.out,
      JSON.stringify({ kind: "fatal", error: String(error?.stack ?? error) }) + "\n",
    );
  process.exit(1);
}
