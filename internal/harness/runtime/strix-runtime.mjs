// Strix (https://github.com/usestrix/strix) as a Dieter harness.
//
// One turn is one headless Strix process. The first turn scans the card's
// checkout; later turns resume the same Strix run with the new message as its
// instruction. Strix keeps its live state in its run directory, so the
// transcript is projected from those files rather than from Strix's console
// output:
//   run.json                      status, timings and usage
//   .state/agents.json            the agent graph
//   .state/agents.db              per-agent items (openai-agents SQLiteSession)
//   .state/todos.json             per-agent todo lists
//   vulnerabilities.json          findings, with vulnerabilities/<id>.md
//   penetration_test_report.md    the final report
//
// Exit codes are ambiguous (0: clean or budget stop, 1: fatal or interrupted,
// 2: findings or a usage error), so run.json's status decides the outcome.

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

// The sandbox image Strix 1.7.1 expects, pinned by its multi-arch index digest.
export const strixSandboxImage =
  "ghcr.io/usestrix/strix-sandbox:1.4.1@sha256:c8e70302ba4a69b678b4001c909b134d8d0b84625d7b23feed59ece02672c1d2";

const terminalRunStatuses = new Set(["completed", "stopped", "failed", "interrupted"]);
const pollIntervalMs = 500;
const outputTailBytes = 64 * 1024;
const reportLimitBytes = 64 * 1024;
const findingDetailLimitBytes = 8 * 1024;
const toolOutputLimitBytes = 4 * 1024;
const rowsPerPoll = 500;
const recentChildLines = 5;
// The daemon waits four seconds for a suspended worker (harness.go); Strix
// needs about two to stop its agents and remove its sandbox container.
const suspendStopMs = 3_000;

// Variables Strix may receive from the worker environment. The daemon fills
// LLM_* and STRIX_LLM from the conversation's vault item; nothing else of the
// worker (turn token, Dieter paths) reaches the Strix process.
const forwardedEnv = [
  "PATH",
  "TMPDIR",
  "LANG",
  "LC_ALL",
  "TERM",
  "USER",
  "LOGNAME",
  "DOCKER_HOST",
  "DOCKER_CONFIG",
  "DOCKER_CONTEXT",
  "DOCKER_TLS_VERIFY",
  "DOCKER_CERT_PATH",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "NO_PROXY",
  "STRIX_LLM",
  "STRIX_API_TYPE",
  "STRIX_REASONING_EFFORT",
  "STRIX_LLM_INPUT_COST_PER_MTOK",
  "STRIX_LLM_OUTPUT_COST_PER_MTOK",
  "STRIX_LLM_CACHED_INPUT_COST_PER_MTOK",
  "LLM_API_KEY",
  "LLM_API_BASE",
  "LLM_EXTRA_HEADERS",
  "LLM_EXTRA_BODY",
  // Optional integrations: web search for the agents' research, and Postman
  // collections as targets.
  "PERPLEXITY_API_KEY",
  "EXA_API_KEY",
  "STRIX_WEB_SEARCH_PROVIDER",
  "STRIX_EXA_SEARCH_TYPE",
  "STRIX_EXA_NUM_RESULTS",
  "POSTMAN_API_KEY",
];

function readJSON(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

function readText(path, limit) {
  try {
    const text = readFileSync(path, "utf8");
    return text.length > limit ? `${text.slice(0, limit)}\n\n… (truncated)` : text;
  } catch {
    return undefined;
  }
}

function bounded(value, limit) {
  const text = typeof value === "string" ? value : value == null ? "" : JSON.stringify(value);
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function findingsOf(runDir) {
  const findings = readJSON(join(runDir, "vulnerabilities.json"));
  const list = Array.isArray(findings) ? findings : findings?.vulnerabilities;
  return Array.isArray(list)
    ? list.filter((finding) => finding && typeof finding === "object")
    : [];
}

function usageOf(record) {
  const usage = record?.llm_usage || {};
  return {
    inputTokens: Number(usage.input_tokens) || 0,
    outputTokens: Number(usage.output_tokens) || 0,
    totalTokens: Number(usage.total_tokens) || 0,
    cost: Number(usage.cost) || 0,
  };
}

// The run directory Strix created under runsRoot (its cwd's strix_runs). A
// Dieter conversation owns its own cwd, so there is at most one run.
export function findRunDir(runsRoot, runName) {
  if (runName) {
    const dir = join(runsRoot, runName);
    return existsSync(join(dir, "run.json")) ? dir : undefined;
  }
  if (!existsSync(runsRoot)) return undefined;
  const runs = readdirSync(runsRoot)
    .map((name) => join(runsRoot, name))
    .filter((dir) => existsSync(join(dir, "run.json")));
  runs.sort(
    (a, b) => statSync(join(b, "run.json")).mtimeMs - statSync(join(a, "run.json")).mtimeMs,
  );
  return runs[0];
}

export function strixAgentStatus(status) {
  switch (status) {
    case "running":
    case "waiting":
      return "running";
    case "completed":
    case "finished":
      return "completed";
    case "crashed":
    case "failed":
    case "error":
      return "failed";
    case "stopped":
    case "interrupted":
      return "aborted";
    default:
      return "pending";
  }
}

function todoStatus(todo) {
  const status = String(todo?.status || "").toLowerCase();
  if (status === "done" || status === "completed") return "completed";
  if (status === "in_progress" || status === "in-progress") return "in_progress";
  if (status === "cancelled" || status === "canceled" || status === "deleted") return "abandoned";
  return "pending";
}

function itemText(item) {
  if (typeof item.content === "string") return item.content;
  if (!Array.isArray(item.content)) return "";
  return item.content
    .map((part) => (typeof part?.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n");
}

function reasoningText(item) {
  const parts = [...(item.summary || []), ...(item.content || [])];
  return parts
    .map((part) => (typeof part?.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n");
}

// Projects one Strix run directory into UI chunks and capability updates.
// cursor = { runName, lastRowId } from the previous turn's session, so a
// resumed run shows only new activity.
export function createStrixProjection({ runsRoot, emit, collector, cursor = {} }) {
  let runDir = cursor.runName ? findRunDir(runsRoot, cursor.runName) : undefined;
  let lastRowId = Number(cursor.lastRowId) || 0;
  let rootId;
  let record = {};
  let textCount = 0;
  let planFingerprint = "";
  const agentFingerprints = new Map();
  // Statuses of a resumed run's agents when this turn started: agents an
  // earlier turn finished stay on that turn's message.
  const settledBefore = new Map();
  // Per child agent: tool count, current tool, latest message, recent lines.
  const children = new Map();
  const seenFindings = new Set();
  let startUsage;

  function text(value, kind = "text") {
    if (!String(value || "").trim()) return;
    const id = `strix-${kind}-${++textCount}`;
    emit({ type: `${kind}-start`, id });
    emit({ type: `${kind}-delta`, id, delta: value });
    emit({ type: `${kind}-end`, id });
  }

  function graph() {
    return runDir ? readJSON(join(runDir, ".state", "agents.json")) : undefined;
  }

  function pollAgents() {
    const agents = graph();
    if (!agents?.statuses || typeof agents.statuses !== "object") return;
    for (const [agentId, parent] of Object.entries(agents.parent_of || {})) {
      if (parent == null) rootId = agentId;
    }
    const usage = new Map(
      (Array.isArray(record.llm_usage?.agents) ? record.llm_usage.agents : []).map((entry) => [
        String(entry?.agent_id),
        entry,
      ]),
    );
    for (const [agentId, status] of Object.entries(agents.statuses)) {
      if (agentId === rootId || settledBefore.get(agentId) === status) continue;
      settledBefore.delete(agentId);
      const parent = agents.parent_of?.[agentId];
      const child = children.get(agentId);
      const spent = usage.get(agentId);
      const patch = {
        name: String(agents.names?.[agentId] || agentId),
        agentType: "Strix agent",
        status: strixAgentStatus(status),
        task: bounded(agents.metadata?.[agentId]?.task || "", 2_000),
        ...(parent && parent !== rootId ? { parentAgentId: String(parent) } : {}),
        ...(agents.errors?.[agentId] ? { error: bounded(agents.errors[agentId], 1_000) } : {}),
        ...(child?.toolCount ? { toolCount: child.toolCount } : {}),
        ...(child?.currentTool ? { currentTool: child.currentTool } : {}),
        ...(child?.activity ? { activity: child.activity } : {}),
        ...(child?.recent.length ? { recentOutput: [...child.recent] } : {}),
        ...(spent?.model ? { model: String(spent.model) } : {}),
        ...(Number(spent?.requests) ? { requests: Number(spent.requests) } : {}),
        ...(Number(spent?.total_tokens) ? { tokens: Number(spent.total_tokens) } : {}),
        ...(Number(spent?.cost) ? { cost: Number(spent.cost) } : {}),
      };
      const fingerprint = JSON.stringify(patch);
      if (agentFingerprints.get(agentId) === fingerprint) continue;
      agentFingerprints.set(agentId, fingerprint);
      collector.upsertSubagent(agentId, patch);
    }
  }

  function pollTodos() {
    if (!rootId) return;
    const todos = readJSON(join(runDir, ".state", "todos.json"));
    const list = todos?.[rootId];
    const entries = Array.isArray(list)
      ? list
      : list && typeof list === "object"
        ? Object.entries(list)
        : [];
    const tasks = entries
      .map((entry) => (Array.isArray(entry) ? { id: entry[0], ...entry[1] } : entry))
      .filter((todo) => todo && typeof todo === "object")
      .map((todo) => ({
        id: String(todo.id || todo.todo_id || ""),
        content: String(todo.title || todo.content || todo.description || "").trim(),
        status: todoStatus(todo),
        ...(todo.priority ? { priority: String(todo.priority) } : {}),
      }))
      .filter((task) => task.content);
    if (!tasks.length) return;
    const fingerprint = JSON.stringify(tasks);
    if (fingerprint === planFingerprint) return;
    planFingerprint = fingerprint;
    collector.replaceTasks(tasks, "strix-todos");
  }

  function consumeItem(agentId, item) {
    const type = item.type || (item.role ? "message" : "");
    if (agentId !== rootId) {
      // Child agents are summarized on their subagent entry.
      let child = children.get(agentId);
      if (!child)
        children.set(
          agentId,
          (child = { toolCount: 0, currentTool: "", activity: "", recent: [] }),
        );
      const remember = (line) => {
        child.recent.push(line);
        if (child.recent.length > recentChildLines) child.recent.shift();
      };
      if (type === "message" && item.role === "assistant") {
        const note = itemText(item).trim();
        if (note) {
          child.activity = bounded(note.split("\n")[0], 200);
          remember(bounded(note.replace(/\s+/g, " "), 300));
        }
      } else if (type === "function_call") {
        child.toolCount += 1;
        child.currentTool = String(item.name || "");
        remember(`→ ${item.name}`);
      } else if (type === "function_call_output") {
        child.currentTool = "";
      }
      return;
    }
    if (type === "message" && item.role === "assistant") {
      text(itemText(item));
    } else if (type === "reasoning") {
      text(reasoningText(item), "reasoning");
    } else if (type === "function_call" && item.call_id) {
      let input = item.arguments;
      try {
        input = JSON.parse(item.arguments);
      } catch {}
      emit({ type: "tool-input-available", toolCallId: item.call_id, toolName: item.name, input });
    } else if (type === "function_call_output" && item.call_id) {
      emit({
        type: "tool-output-available",
        toolCallId: item.call_id,
        output: bounded(item.output, toolOutputLimitBytes),
      });
    }
  }

  function pollItems() {
    const path = join(runDir, ".state", "agents.db");
    if (!existsSync(path)) return;
    let db;
    try {
      db = new DatabaseSync(path, { readOnly: true });
      db.exec("PRAGMA busy_timeout = 2000");
      for (;;) {
        const rows = db
          .prepare(
            "SELECT id, session_id, message_data FROM agent_messages WHERE id > ? ORDER BY id LIMIT ?",
          )
          .all(lastRowId, rowsPerPoll);
        for (const row of rows) {
          lastRowId = Number(row.id);
          let item;
          try {
            item = JSON.parse(row.message_data);
          } catch {
            continue;
          }
          if (item && typeof item === "object") consumeItem(String(row.session_id), item);
        }
        if (rows.length < rowsPerPoll) break;
      }
    } catch (error) {
      // Strix holds its write lock briefly and creates the table lazily; the
      // next poll catches up.
      if (!/locked|busy|no such table|unable to open/i.test(String(error?.message))) throw error;
    } finally {
      db?.close();
    }
  }

  function pollFindings() {
    for (const finding of findingsOf(runDir)) {
      const key = String(finding.id || finding.title || "");
      if (!key || seenFindings.has(key)) continue;
      seenFindings.add(key);
      const toolCallId = `strix-finding-${key}`;
      emit({
        type: "tool-input-available",
        toolCallId,
        toolName: "strix_finding",
        input: {
          id: finding.id,
          title: finding.title,
          severity: finding.severity,
          ...(finding.cwe ? { cwe: finding.cwe } : {}),
          ...(finding.endpoint ? { endpoint: finding.endpoint } : {}),
        },
      });
      const detail = finding.id
        ? readText(join(runDir, "vulnerabilities", `${finding.id}.md`), findingDetailLimitBytes)
        : undefined;
      emit({
        type: "tool-output-available",
        toolCallId,
        output: detail || `${String(finding.severity || "").toUpperCase()} · ${finding.title}`,
      });
    }
  }

  // Call before Strix starts on a resumed run: the earlier findings were
  // shown by the turn that filed them.
  function prime() {
    runDir ??= findRunDir(runsRoot, cursor.runName);
    if (!runDir) return;
    record = readJSON(join(runDir, "run.json")) || {};
    startUsage = usageOf(record);
    for (const finding of findingsOf(runDir))
      seenFindings.add(String(finding.id || finding.title || ""));
    const agents = graph();
    for (const [agentId, parent] of Object.entries(agents?.parent_of || {})) {
      if (parent == null) rootId = agentId;
    }
    for (const [agentId, status] of Object.entries(agents?.statuses || {})) {
      if (strixAgentStatus(status) !== "running" && strixAgentStatus(status) !== "pending") {
        settledBefore.set(agentId, status);
      }
    }
  }

  function poll() {
    runDir ??= findRunDir(runsRoot, cursor.runName);
    if (!runDir) return undefined;
    record = readJSON(join(runDir, "run.json")) || record;
    startUsage ??= { inputTokens: 0, outputTokens: 0, totalTokens: 0, cost: 0 };
    // The graph names the root agent; read it before the items it filters.
    pollAgents();
    pollItems();
    pollAgents();
    pollTodos();
    pollFindings();
    return record.status;
  }

  // The usage this turn added: Strix keeps one cumulative ledger per run.
  function turnUsage() {
    const end = usageOf(record);
    const start = startUsage || { inputTokens: 0, outputTokens: 0, totalTokens: 0, cost: 0 };
    return {
      inputTokens: Math.max(0, end.inputTokens - start.inputTokens),
      outputTokens: Math.max(0, end.outputTokens - start.outputTokens),
      totalTokens: Math.max(0, end.totalTokens - start.totalTokens),
      cost: Math.max(0, end.cost - start.cost),
      runCost: end.cost,
    };
  }

  // Closing text: the report when the scan finished, otherwise why it stopped.
  function summarize({ budgetUSD }) {
    const status = record.status;
    const findings = findingsOf(runDir);
    const usage = turnUsage();
    const report =
      status === "completed"
        ? readText(join(runDir, "penetration_test_report.md"), reportLimitBytes)
        : undefined;
    if (report) {
      text(report);
    } else if (record.scan_results?.executive_summary) {
      text(String(record.scan_results.executive_summary));
    }
    const counts = {};
    for (const finding of findings) {
      const severity = String(finding.severity || "unknown").toLowerCase();
      counts[severity] = (counts[severity] || 0) + 1;
    }
    const severityText = Object.entries(counts)
      .map(([severity, count]) => `${count} ${severity}`)
      .join(", ");
    const lines = [
      `**Strix ${status || "finished"}** · ${findings.length} finding${findings.length === 1 ? "" : "s"}${severityText ? ` (${severityText})` : ""}`,
    ];
    if (status === "stopped" && budgetUSD && usage.runCost >= Number(budgetUSD) * 0.9) {
      lines.push(
        `Stopped at the $${budgetUSD} budget ($${usage.runCost.toFixed(2)} spent). Send a message to continue the scan.`,
      );
    } else if (status === "stopped") {
      lines.push("Strix stopped before finishing. Send a message to continue the scan.");
    }
    if (usage.cost > 0) lines.push(`Model cost this turn: $${usage.cost.toFixed(4)}`);
    lines.push(`Results: \`${runDir}\``);
    text(lines.join("\n\n"));
    return usage;
  }

  return {
    prime,
    poll,
    summarize,
    turnUsage,
    get runDir() {
      return runDir;
    },
    get status() {
      return record.status;
    },
    get cursor() {
      return runDir ? { runName: runDir.split("/").pop(), lastRowId } : undefined;
    },
  };
}

// Targets beyond the checkout: URLs, domains, IPs or API specs, separated by
// whitespace, commas or newlines.
export function strixTargets(value) {
  return String(value || "")
    .split(/[\s,]+/)
    .map((target) => target.trim())
    .filter(Boolean);
}

// workspaceFiles are { path, dest } pairs placed into the sandbox's
// /workspace; mcpConfig is the operator's own Strix MCP servers file.
export function strixArgs({
  request,
  runName,
  configPath,
  instructionPath,
  options = {},
  workspaceFiles = [],
  mcpConfig,
}) {
  const args = ["-n", "--config", configPath];
  if (runName) {
    // A resumed run keeps its targets, scan mode and scope.
    args.push("--resume", runName);
  } else {
    args.push("--target", request.projectPath);
    for (const target of strixTargets(options.targets)) args.push("--target", target);
    args.push("--scan-mode", options.scan_mode || "quick");
    if (options.scope === "changes") {
      args.push("--scope-mode", "diff");
      if (request.diffBase) args.push("--diff-base", request.diffBase);
    } else {
      args.push("--scope-mode", "full");
    }
  }
  if (instructionPath) args.push("--instruction-file", instructionPath);
  for (const file of workspaceFiles) args.push("--workspace-file", `${file.path}:${file.dest}`);
  if (mcpConfig) args.push("--mcp-config", mcpConfig);
  const budget = Number(options.max_budget_usd);
  if (Number.isFinite(budget) && budget > 0) args.push("--max-budget", String(budget));
  return args;
}

// Files attached to the message become files in Strix's sandbox workspace.
// They stay in the conversation's state directory: Strix places a run's
// files again when it resumes.
export async function strixWorkspaceFiles(request, stateDir) {
  const files = [];
  for (const [index, attachment] of (request.attachments || []).entries()) {
    const match = /^data:([^;,]+);base64,([A-Za-z0-9+/=]+)$/.exec(attachment?.url || "");
    if (!match) throw new Error("Dieter received an invalid attachment");
    const name =
      String(attachment.filename || `attachment-${index + 1}`)
        .replace(/[^A-Za-z0-9._-]+/g, "-")
        .replace(/^\.+/, "") || `attachment-${index + 1}`;
    const directory = join(stateDir, "attachments", String(request.responseMessageId || "turn"));
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const path = join(directory, `${index + 1}-${name}`);
    await writeFile(path, Buffer.from(match[2], "base64"), { mode: 0o600 });
    files.push({ path, dest: `attached/${index + 1}-${name}` });
  }
  return files;
}

export function strixEnvironment({ env = process.env, request, stateDir }) {
  const child = {};
  for (const name of forwardedEnv) {
    if (env[name] != null && env[name] !== "") child[name] = env[name];
  }
  // HOME is private to the conversation; Docker contexts still resolve from
  // the operator's Docker configuration.
  child.HOME = join(stateDir, "home");
  child.DOCKER_CONFIG ??= join(env.HOME || homedir(), ".docker");
  if (request.model) child.STRIX_LLM = request.model;
  if (request.effort) child.STRIX_REASONING_EFFORT = request.effort;
  child.STRIX_TELEMETRY = "0";
  child.STRIX_NO_UPDATE_CHECK = "1";
  child.STRIX_IMAGE = strixSandboxImage;
  child.PYTHONUNBUFFERED = "1";
  return child;
}

// The text of Strix's last console panel, without box-drawing characters.
export function strixConsoleError(output) {
  const lines = String(output || "")
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .split("\n")
    .map((line) => line.replace(/[│╭╮╰╯─━┃┏┓┗┛]/g, "").trim())
    .filter(Boolean);
  return bounded(lines.slice(-12).join("\n"), 2_000);
}

function sessionCursor(session) {
  const data = session?.data;
  if (!data || typeof data !== "object" || typeof data.strixRunName !== "string") return {};
  return { runName: data.strixRunName, lastRowId: Number(data.lastRowId) || 0 };
}

// Runs one turn. Resolves with the worker exit code; the caller exits.
export async function runStrixTurn({ request, send, collector, executable, env = process.env }) {
  const options = request.options || {};
  const stateDir = join(request.runtimeRoot, "strix", request.sessionId);
  const runsRoot = join(stateDir, "strix_runs");
  const configPath = join(stateDir, "turn-config.json");
  const instructionPath = join(stateDir, "turn-instruction.md");
  await mkdir(join(stateDir, "home"), { recursive: true, mode: 0o700 });
  // Strix writes every LLM_* value, including the API key, into its config
  // file. Give it a file that lives only for this turn.
  await writeFile(configPath, '{"env": {}}\n', { mode: 0o600 });

  const cursor = sessionCursor(request.session);
  const runName =
    cursor.runName && findRunDir(runsRoot, cursor.runName) ? cursor.runName : undefined;
  const workspaceFiles = request.continue ? [] : await strixWorkspaceFiles(request, stateDir);
  let prompt = request.continue ? "" : String(request.prompt || "").trim();
  if (workspaceFiles.length) {
    // Strix lists a run's files only in its opening task; say it every turn.
    const listed = workspaceFiles.map((file) => `- /workspace/${file.dest}`).join("\n");
    prompt = `${prompt}\n\nFiles attached to this message, in your workspace:\n${listed}`.trim();
  }
  if (prompt) await writeFile(instructionPath, `${prompt}\n`, { mode: 0o600 });
  const operatorMCP = join(env.HOME || homedir(), ".strix", "mcp-servers.json");
  if (!runName && !prompt && request.continue) {
    send({
      type: "error",
      error: "The interrupted Strix run is gone; send a new message to start a scan.",
    });
    return 1;
  }

  const createdAt = new Date().toISOString();
  const emit = (chunk) => {
    collector.consumeUIChunk?.(chunk);
    send({ type: "chunk", chunk });
  };
  const projection = createStrixProjection({
    runsRoot,
    emit,
    collector,
    cursor: runName ? cursor : {},
  });
  if (runName) projection.prime();
  emit({ type: "start", messageId: request.responseMessageId, messageMetadata: { createdAt } });

  const args = strixArgs({
    request,
    runName,
    configPath,
    instructionPath: prompt ? instructionPath : undefined,
    options,
    workspaceFiles,
    mcpConfig: existsSync(operatorMCP) ? operatorMCP : undefined,
  });
  // Strix stays in the worker's process group, so the daemon's cancel
  // (SIGINT to the group) reaches it directly.
  const child = spawn(executable, args, {
    cwd: stateDir,
    env: strixEnvironment({ env, request, stateDir }),
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  let pullNoted = false;
  const capture = (chunk) => {
    output = (output + chunk).slice(-outputTailBytes);
    if (!pullNoted && /Pulling image/.test(chunk)) {
      pullNoted = true;
      emit({ type: "text-start", id: "strix-pull" });
      emit({
        type: "text-delta",
        id: "strix-pull",
        delta: "Downloading the Strix sandbox image (first run on this machine, about 1.5 GB)…",
      });
      emit({ type: "text-end", id: "strix-pull" });
    }
  };
  child.stdout.on("data", (chunk) => capture(String(chunk)));
  child.stderr.on("data", (chunk) => capture(String(chunk)));

  let interruption;
  const exited = new Promise((resolve) => {
    child.on("error", (error) => resolve({ code: 1, error }));
    child.on("exit", (code, signal) => resolve({ code, signal }));
  });
  const onInterrupt = (signal) => () => {
    interruption ??= signal;
  };
  const onSuspend = () => {
    interruption = "suspend";
    child.kill("SIGINT");
    setTimeout(() => child.kill("SIGKILL"), suspendStopMs).unref();
  };
  const listeners = [
    ["SIGINT", onInterrupt("SIGINT")],
    ["SIGTERM", onInterrupt("SIGTERM")],
    ["SIGUSR1", onSuspend],
  ];
  for (const [signal, listener] of listeners) process.once(signal, listener);
  const timer = setInterval(() => {
    try {
      projection.poll();
    } catch (error) {
      console.error(`strix projection: ${error?.message || error}`);
    }
  }, pollIntervalMs);

  let result;
  try {
    result = await exited;
  } finally {
    clearInterval(timer);
    for (const [signal, listener] of listeners) process.removeListener(signal, listener);
    await rm(configPath, { force: true });
    await rm(instructionPath, { force: true });
  }
  projection.poll();
  const status = projection.status;
  const nextCursor = projection.cursor;
  const session = (continueFrom) =>
    send({
      type: "session",
      state: {
        type: "resume-session",
        data: nextCursor
          ? { strixRunName: nextCursor.runName, lastRowId: nextCursor.lastRowId }
          : {},
        ...(continueFrom ? { continueFrom: { strix: true } } : {}),
      },
    });

  if (interruption === "suspend") {
    // Continue after the restart by resuming the run without a new message.
    session(Boolean(nextCursor));
    return 0;
  }
  if (interruption) {
    session(false);
    collector.finalize("aborted");
    collector.finishTaskPlan("aborted");
    return interruption === "SIGTERM" ? 143 : 130;
  }
  if (!projection.runDir || !terminalRunStatuses.has(status)) {
    const reason = result.error?.message || strixConsoleError(output) || `exit ${result.code}`;
    console.error(`strix exited with ${result.code}: ${reason}`);
    if (nextCursor) session(false);
    send({ type: "error", error: `Strix failed: ${reason}` });
    collector.finalize("failed");
    collector.finishTaskPlan("failed");
    return 1;
  }
  const usage = projection.summarize({ budgetUSD: options.max_budget_usd });
  session(false);
  if (status === "failed") {
    send({
      type: "error",
      error: `Strix failed: ${strixConsoleError(output) || "see the run log"}`,
    });
    collector.finalize("failed");
    collector.finishTaskPlan("failed");
    return 1;
  }
  const metadata = {
    createdAt,
    usage: {
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      totalTokens: usage.totalTokens,
    },
  };
  emit({ type: "finish", finishReason: "stop", messageMetadata: metadata });
  collector.finalize(status === "completed" ? "completed" : "aborted");
  collector.finishTaskPlan(status === "completed" ? "completed" : "stopped");
  return 0;
}
