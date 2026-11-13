// Prototype of the Dieter-side projection of a Strix run directory.
//
// Strix writes everything a client needs to its run directory while it runs:
//   run.json                      status, timings, targets, usage and cost
//   .state/agents.json            the agent graph (statuses, names, parent_of, errors)
//   .state/agents.db              per-agent Responses-style items (openai-agents SQLiteSession)
//   .state/todos.json             per-agent todo lists
//   vulnerabilities.json          findings, plus vulnerabilities/<id>.md
//   penetration_test_report.md    the final report
//
// This module tails those files and turns them into what Dieter's harness
// runner already sends to the daemon: AI SDK UI message chunks for the root
// agent, and `subagents` / `task-plan` capability envelopes for the graph. The
// production version would live in internal/harness/runtime/strix-runtime.mjs
// and feed the existing capability collector instead of emitting envelopes.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

const terminalRunStatuses = new Set(["completed", "stopped", "failed", "interrupted"]);

function readJSON(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
}

function compact(value, limit = 600) {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  if (text == null) return "";
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

// The run directory Strix created under runsRoot (strix_runs). A Dieter
// session owns its own cwd, so there is at most one run per session.
export function findRunDir(runsRoot) {
  if (!existsSync(runsRoot)) return undefined;
  const runs = readdirSync(runsRoot)
    .map((name) => join(runsRoot, name))
    .filter((dir) => existsSync(join(dir, "run.json")));
  runs.sort(
    (a, b) => statSync(join(b, "run.json")).mtimeMs - statSync(join(a, "run.json")).mtimeMs,
  );
  return runs[0];
}

function mapAgentStatus(status) {
  switch (status) {
    case "running":
    case "waiting":
      return "running";
    case "completed":
    case "finished":
      return "completed";
    case "stopped":
    case "interrupted":
      return "cancelled";
    case "crashed":
    case "failed":
    case "error":
      return "failed";
    default:
      return "pending";
  }
}

function mapTodoStatus(todo) {
  const status = String(todo.status || "").toLowerCase();
  if (status === "done" || status === "completed") return "completed";
  if (status === "in_progress" || status === "in-progress") return "in_progress";
  if (status === "cancelled" || status === "deleted") return "abandoned";
  return "pending";
}

function textOf(item) {
  if (typeof item.content === "string") return item.content;
  if (!Array.isArray(item.content)) return "";
  return item.content
    .map((part) => (typeof part?.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n");
}

export function createStrixProjector({
  runsRoot,
  messageId,
  emit,
  emitCapability,
  provider = "strix",
}) {
  let runDir;
  let lastRowId = 0;
  let textCount = 0;
  let rootId;
  const agentFingerprints = new Map();
  const childNotes = new Map();
  const toolNames = new Map();
  const seenFindings = new Set();
  let planFingerprint = "";
  let started = false;
  let runRecord = {};

  function start() {
    if (started) return;
    started = true;
    emit({ type: "start", messageId, messageMetadata: { createdAt: new Date().toISOString() } });
  }

  function emitText(text) {
    if (!text.trim()) return;
    const id = `strix-text-${++textCount}`;
    emit({ type: "text-start", id });
    emit({ type: "text-delta", id, delta: text });
    emit({ type: "text-end", id });
  }

  function pollAgents() {
    const graph = readJSON(join(runDir, ".state", "agents.json"));
    if (!graph?.statuses) return;
    for (const [agentId, status] of Object.entries(graph.statuses)) {
      const parent = graph.parent_of?.[agentId] ?? null;
      if (parent == null) {
        rootId = agentId;
        continue;
      }
      const subagent = {
        id: agentId,
        provider,
        messageId,
        name: graph.names?.[agentId] || agentId,
        agentType: "Strix agent",
        status: mapAgentStatus(status),
        ...(parent !== rootId ? { parentAgentId: parent } : {}),
        ...(graph.errors?.[agentId] ? { error: String(graph.errors[agentId]) } : {}),
        ...(childNotes.get(agentId) ? { recentOutput: childNotes.get(agentId) } : {}),
      };
      const fingerprint = JSON.stringify(subagent);
      if (agentFingerprints.get(agentId) === fingerprint) continue;
      agentFingerprints.set(agentId, fingerprint);
      emitCapability({ id: "subagents", operation: "upsert", subagent });
    }
  }

  function pollTodos() {
    const todos = readJSON(join(runDir, ".state", "todos.json"));
    if (!todos || !rootId) return;
    const list = Array.isArray(todos) ? todos : todos[rootId] || todos.todos?.[rootId];
    const entries = Array.isArray(list)
      ? list
      : list && typeof list === "object"
        ? Object.values(list)
        : [];
    const tasks = entries
      .filter((todo) => todo && typeof todo === "object")
      .map((todo, order) => ({
        ...(todo.id ? { id: String(todo.id) } : {}),
        content: String(todo.title || todo.content || todo.description || "").trim(),
        status: mapTodoStatus(todo),
        ...(todo.priority ? { priority: String(todo.priority) } : {}),
        order,
      }))
      .filter((task) => task.content);
    if (!tasks.length) return;
    const fingerprint = JSON.stringify(tasks);
    if (fingerprint === planFingerprint) return;
    planFingerprint = fingerprint;
    emitCapability({
      id: "task-plan",
      operation: "replace",
      plan: {
        id: `${provider}:${messageId}`,
        provider,
        messageId,
        state: "active",
        source: "strix-todos",
        phases: [{ name: "", tasks }],
        updatedAt: new Date().toISOString(),
      },
    });
  }

  function pollSessions() {
    const dbPath = join(runDir, ".state", "agents.db");
    if (!existsSync(dbPath)) return;
    let db;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true });
      db.exec("PRAGMA busy_timeout = 2000");
      const rows = db
        .prepare(
          "SELECT id, session_id, message_data FROM agent_messages WHERE id > ? ORDER BY id LIMIT 500",
        )
        .all(lastRowId);
      for (const row of rows) {
        lastRowId = Number(row.id);
        let item;
        try {
          item = JSON.parse(row.message_data);
        } catch {
          continue;
        }
        consumeItem(String(row.session_id), item);
      }
    } catch (error) {
      // A writer can hold the lock briefly; the next poll catches up.
      if (!/locked|busy|no such table/i.test(String(error?.message))) throw error;
    } finally {
      db?.close();
    }
  }

  function consumeItem(agentId, item) {
    const isRoot = agentId === rootId;
    const type = item.type || (item.role ? "message" : "");
    if (!isRoot) {
      // Children are summarized on their subagent card, not in the transcript.
      if (type === "message" && item.role === "assistant")
        childNotes.set(agentId, compact(textOf(item), 300));
      if (type === "function_call") childNotes.set(agentId, `→ ${item.name}`);
      return;
    }
    if (type === "message" && item.role === "assistant") {
      emitText(textOf(item));
    } else if (type === "function_call") {
      let input = item.arguments;
      try {
        input = JSON.parse(item.arguments);
      } catch {}
      toolNames.set(item.call_id, item.name);
      emit({
        type: "tool-input-available",
        toolCallId: item.call_id,
        toolName: item.name,
        input,
        dynamic: true,
      });
    } else if (type === "function_call_output") {
      emit({
        type: "tool-output-available",
        toolCallId: item.call_id,
        output: compact(item.output, 4000),
        dynamic: true,
      });
    }
  }

  function pollFindings() {
    const findings = readJSON(join(runDir, "vulnerabilities.json"));
    const list = Array.isArray(findings) ? findings : findings?.vulnerabilities;
    if (!Array.isArray(list)) return;
    for (const finding of list) {
      const key = finding.id || finding.title;
      if (!key || seenFindings.has(key)) continue;
      seenFindings.add(key);
      // A dynamic "tool" pair renders as a collapsible card in every client
      // today without a new part type.
      const toolCallId = `strix-finding-${key}`;
      emit({
        type: "tool-input-available",
        toolCallId,
        toolName: "strix_finding",
        input: {
          id: finding.id,
          title: finding.title,
          severity: finding.severity,
          cwe: finding.cwe,
        },
        dynamic: true,
      });
      emit({
        type: "tool-output-available",
        toolCallId,
        output: `${String(finding.severity || "").toUpperCase()} · ${finding.title}\nvulnerabilities/${finding.id}.md`,
        dynamic: true,
      });
    }
  }

  // A follow-up turn resumes the same run. Its earlier items were shown by the
  // previous turn, so start after them. One active turn per conversation
  // (Dieter's runtime lease) makes the files a safe cursor; the production
  // adapter keeps {runName, lastRowId} in the harness session state instead.
  function prime() {
    runDir ??= findRunDir(runsRoot);
    if (!runDir) return;
    const dbPath = join(runDir, ".state", "agents.db");
    if (existsSync(dbPath)) {
      const db = new DatabaseSync(dbPath, { readOnly: true });
      try {
        lastRowId = Number(
          db.prepare("SELECT COALESCE(MAX(id), 0) AS id FROM agent_messages").get().id,
        );
      } finally {
        db.close();
      }
    }
    const findings = readJSON(join(runDir, "vulnerabilities.json"));
    const list = Array.isArray(findings) ? findings : findings?.vulnerabilities || [];
    for (const finding of list) seenFindings.add(finding.id || finding.title);
    const graph = readJSON(join(runDir, ".state", "agents.json"));
    for (const [agentId, parent] of Object.entries(graph?.parent_of || {})) {
      if (parent == null) rootId = agentId;
    }
  }

  function poll() {
    runDir ??= findRunDir(runsRoot);
    if (!runDir) return { runDir: undefined, status: "starting" };
    start();
    runRecord = readJSON(join(runDir, "run.json")) || runRecord;
    pollAgents();
    pollSessions();
    pollTodos();
    pollFindings();
    return { runDir, status: runRecord.status, record: runRecord };
  }

  // Final summary: findings by severity, report location and cost. The report
  // itself is a file Dieter can present in the workspace pane.
  // Exit codes are ambiguous (0 = clean or budget stop, 1 = fatal or
  // interrupted, 2 = findings or a usage error), so run.json decides.
  function finish({ exitCode, budgetUSD }) {
    const state = poll();
    if (!state.runDir) {
      return { failed: true, error: `Strix exited with ${exitCode} before creating a run` };
    }
    // agents.json keeps "running" for agents of an interrupted run; settle them.
    const graph = readJSON(join(runDir, ".state", "agents.json"));
    if (runRecord.status !== "completed") {
      for (const agentId of Object.keys(graph?.statuses || {})) {
        if (agentId === rootId) continue;
        const previous = JSON.parse(agentFingerprints.get(agentId) || "{}");
        if (previous.status !== "running" && previous.status !== "pending") continue;
        const subagent = { ...previous, status: "cancelled" };
        agentFingerprints.set(agentId, JSON.stringify(subagent));
        emitCapability({ id: "subagents", operation: "upsert", subagent });
      }
    }
    const summary = runRecord.scan_results?.executive_summary;
    if (summary) emitText(summary);
    const cost = Number(runRecord.llm_usage?.cost);
    if (runRecord.status === "stopped" && budgetUSD && cost >= Number(budgetUSD) * 0.9) {
      emitText(
        `Stopped at the $${budgetUSD} budget ($${cost.toFixed(4)} spent). Send a message to resume.`,
      );
    } else if (runRecord.status === "interrupted") {
      emitText("Interrupted. Send a message to resume the scan.");
    }
    const findings = readJSON(join(runDir, "vulnerabilities.json"));
    const list = Array.isArray(findings) ? findings : findings?.vulnerabilities || [];
    const bySeverity = {};
    for (const finding of list) {
      const severity = String(finding.severity || "unknown").toLowerCase();
      bySeverity[severity] = (bySeverity[severity] || 0) + 1;
    }
    const usage = runRecord.llm_usage || {};
    const lines = [
      `**Strix ${runRecord.status || "finished"}** · ${list.length} finding(s)` +
        (list.length
          ? ` (${Object.entries(bySeverity)
              .map(([k, v]) => `${v} ${k}`)
              .join(", ")})`
          : ""),
      ...list.map((f) => `- **${String(f.severity || "").toUpperCase()}** ${f.title}`),
      existsSync(join(runDir, "penetration_test_report.md"))
        ? `Report: \`${join(runDir, "penetration_test_report.md")}\``
        : "",
      usage.cost != null ? `Model cost: $${Number(usage.cost).toFixed(4)}` : "",
    ].filter(Boolean);
    emitText(lines.join("\n"));
    const status = runRecord.status;
    const failed = status === "failed" || (exitCode === 1 && !terminalRunStatuses.has(status));
    emit({
      type: "finish",
      messageMetadata: {
        usage: {
          inputTokens: usage.input_tokens,
          outputTokens: usage.output_tokens,
          totalTokens: usage.total_tokens,
        },
      },
    });
    return { failed, status, findings: list.length };
  }

  return {
    poll,
    prime,
    finish,
    get runDir() {
      return runDir;
    },
    get cursor() {
      return { runName: runDir?.split("/").pop(), lastRowId };
    },
  };
}
