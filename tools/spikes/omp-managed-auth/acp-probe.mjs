// Drives `omp acp` the way Dieter's runner launches it (ompACPArgs in
// internal/harness/runtime/provider-options.mjs): --config overlay, --advisor,
// --thinking and --model, with credentials only in the environment. A minimal
// ACP client sends one prompt and records the session updates.
//
//   node acp-probe.mjs <omp> <cwd> <overlay.yml> <model> <thinking> <out.json>
//
// The caller provides the environment (HOME, PATH with Bun, PI_CODING_AGENT_DIR,
// ANTHROPIC_OAUTH_TOKEN, OPENAI_CODEX_OAUTH_TOKEN, ...).
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [omp, cwd, overlay, model, thinking, outPath] = process.argv.slice(2);
if (!outPath)
  throw new Error("usage: acp-probe.mjs <omp> <cwd> <overlay.yml> <model> <thinking> <out.json>");

// ACP_CONSTANT_ARGS=1 launches with the overlay only, as the managed design
// does (model, thinking and advisor live in the overlay or in ACP options).
// ACP_LOAD_SESSION=<id> loads a stored session instead of creating one.
// ACP_SET="model=…,thinking=…" sets ACP config options before the prompt.
const constantArgs = process.env.ACP_CONSTANT_ARGS === "1";
const args = constantArgs
  ? ["acp", "--config", overlay]
  : ["acp", "--config", overlay, `--thinking=${thinking}`, "--advisor", `--model=${model}`];
const child = spawn(omp, args, { cwd, env: process.env, stdio: ["pipe", "pipe", "pipe"] });
let stderr = "";
child.stderr.on("data", (chunk) => {
  stderr = (stderr + chunk).slice(-16_000);
});

let nextId = 1;
const pending = new Map();
const updates = [];
const agentRequests = [];

function send(message) {
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
}

function call(method, params) {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject, method }));
}

createInterface({ input: child.stdout }).on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.id != null && pending.has(message.id) && !message.method) {
    const { resolve, reject, method } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(`${method}: ${JSON.stringify(message.error)}`));
    else resolve(message.result);
    return;
  }
  if (message.method === "session/update") {
    const update = message.params?.update ?? {};
    updates.push({
      kind: update.sessionUpdate,
      text: update.content?.text?.slice(0, 200),
      title: update.title,
    });
    return;
  }
  if (message.method && message.id != null) {
    // The probe grants nothing: permission requests are cancelled and client
    // capabilities (fs, terminal) were not advertised.
    agentRequests.push(message.method);
    if (message.method === "session/request_permission") {
      send({ id: message.id, result: { outcome: { outcome: "cancelled" } } });
    } else {
      send({ id: message.id, error: { code: -32601, message: "not supported by probe" } });
    }
  }
});

const deadline = setTimeout(() => finish("timeout"), 120_000);
let finished = false;
function finish(status, extra = {}) {
  if (finished) return;
  finished = true;
  clearTimeout(deadline);
  writeFileSync(
    outPath,
    JSON.stringify(
      { status, args, updates, agentRequests, stderrTail: stderr.slice(-4000), ...extra },
      null,
      2,
    ),
  );
  child.kill("SIGTERM");
  setTimeout(() => process.exit(status === "ok" ? 0 : 1), 500);
}

try {
  const init = await call("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
  });
  const loadId = process.env.ACP_LOAD_SESSION;
  const session = loadId
    ? {
        sessionId: loadId,
        ...(await call("session/load", { sessionId: loadId, cwd, mcpServers: [] })),
      }
    : await call("session/new", { cwd, mcpServers: [] });
  for (const pair of (process.env.ACP_SET ?? "").split(",").filter(Boolean)) {
    const [configId, value] = pair.split("=");
    await call("session/set_config_option", { sessionId: session.sessionId, configId, value });
  }
  const result = await call("session/prompt", {
    sessionId: session.sessionId,
    prompt: [{ type: "text", text: "Reply with the single word OK." }],
  });
  // The advisor reviews asynchronously; give a strict backlog time to drain.
  await new Promise((resolve) => setTimeout(resolve, 5_000));
  finish("ok", {
    agent: init.agentInfo ?? init.agentCapabilities ?? null,
    sessionId: session.sessionId,
    configOptions: (session.configOptions ?? []).map((option) => ({
      id: option.id,
      current: option.currentValue,
      values: (option.options ?? []).slice(0, 12).map((value) => value.value ?? value.id),
    })),
    stopReason: result.stopReason,
  });
} catch (error) {
  finish("error", { error: String(error) });
}
