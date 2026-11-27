#!/usr/bin/env node
// REST contract probe for an isolated agentmemory server. Exercises exactly
// the calls a Dieter-native integration would make: session start/end per
// conversation turn, capture with stable event ids (idempotency), recall
// (smart-search, context) and explicit saves, and records status codes and
// latencies.
//
//   AGENTMEMORY_URL=http://127.0.0.1:13111 AGENTMEMORY_SECRET_FILE=/tmp/.../secret \
//     node probe.mjs --out results/probe.json
//
// Never point this at an operator's agentmemory: it writes probe sessions.

import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

const base = process.env.AGENTMEMORY_URL ?? "http://127.0.0.1:13111";
const secret = readFileSync(process.env.AGENTMEMORY_SECRET_FILE, "utf8").trim();
const outIndex = process.argv.indexOf("--out");
const out = outIndex > 0 ? process.argv[outIndex + 1] : undefined;
const results = { base, startedAt: new Date().toISOString(), calls: [], checks: {} };

async function call(method, path, body, { auth = true } = {}) {
  const started = performance.now();
  const response = await fetch(`${base}/agentmemory${path}`, {
    method,
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(auth ? { Authorization: `Bearer ${secret}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  const ms = Math.round(performance.now() - started);
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = text.slice(0, 200);
  }
  results.calls.push({ method, path, status: response.status, ms });
  return { status: response.status, json, ms };
}

const eventId = (...parts) =>
  createHash("sha256").update(parts.join("\u0000")).digest("hex").slice(0, 32);
const sessionId = `c_probe_${Date.now().toString(36)}`;
const project = "dieter-probe";
const cwd = "/tmp/dieter-probe";
const now = () => new Date().toISOString();

// Unauthenticated calls are refused; livez is public.
results.checks.unauthenticatedHealth = (
  await call("GET", "/health", undefined, { auth: false })
).status;
results.checks.livez = (await call("GET", "/livez", undefined, { auth: false })).status;

// One Dieter turn = session/start (idempotent upsert) + prompt + tools + stop + session/end(final:false).
const start = await call("POST", "/session/start", {
  sessionId,
  project,
  cwd,
  title: "Probe card",
  agentId: "claude-code",
});
results.checks.sessionStart = {
  status: start.status,
  contextChars: String(start.json?.context ?? "").length,
};

const observations = [
  {
    hookType: "prompt_submit",
    data: { prompt: "Why does the Mac transcript jump when new chunks stream in?" },
  },
  {
    hookType: "post_tool_use",
    data: {
      tool_name: "Read",
      tool_input: {
        file_path: "apps/apple/mac/Sources/Transcript/TranscriptScrollController.swift",
      },
      tool_output:
        "final class TranscriptScrollController { // owns scroll position natively; SwiftUI ScrollView anchoring caused jumps }",
    },
  },
  {
    hookType: "post_tool_use",
    data: {
      tool_name: "Bash",
      tool_input: { command: "just mac test_unit" },
      tool_output: "Test run with 412 tests passed after 38.2 seconds.",
    },
  },
  {
    hookType: "post_tool_failure",
    data: {
      tool_name: "Bash",
      tool_input: { command: "just e2e mac flows:transcript" },
      error: "DieterMac is running; Mac flows refuse to run.",
    },
  },
  {
    hookType: "stop",
    data: {
      last_assistant_message:
        "The jump came from SwiftUI's ScrollView re-anchoring on content-size changes. Scroll position is now owned by a native NSScrollView controller (TranscriptScrollController); pinned-to-bottom follows new chunks, otherwise the offset is preserved.",
    },
  },
];
const accepted = [];
for (const [index, observation] of observations.entries()) {
  const body = {
    ...observation,
    sessionId,
    project,
    cwd,
    timestamp: now(),
    eventId: eventId(sessionId, "turn-1", String(index)),
  };
  const response = await call("POST", "/observe", body);
  accepted.push({
    hookType: observation.hookType,
    status: response.status,
    state: response.json?.status,
  });
}
results.checks.observe = accepted;

// Replaying the same event id must be answered as a duplicate (200), not stored twice.
const replay = await call("POST", "/observe", {
  ...observations[1],
  sessionId,
  project,
  cwd,
  timestamp: now(),
  eventId: eventId(sessionId, "turn-1", "1"),
});
results.checks.duplicateReplay = { status: replay.status, state: replay.json?.status };

results.checks.sessionEnd = (
  await call("POST", "/session/end", { sessionId, final: false })
).status;

// Explicit save (what a memory_save host tool would send).
const remember = await call("POST", "/remember", {
  content:
    "Mac E2E flows refuse to run while any DieterMac process runs; close the operator app or use the isolated fixture loop.",
  type: "lesson",
  concepts: ["mac", "e2e", "maestro"],
  project,
  agentId: "claude-code",
});
results.checks.remember = { status: remember.status, keys: Object.keys(remember.json ?? {}) };

// Recall. Give the BM25 index a moment (compression/index is async).
await new Promise((resolve) => setTimeout(resolve, 1500));
const queries = [
  "transcript scroll jumps",
  "TranscriptScrollController",
  "why do mac e2e flows fail",
  "scrolling glitch in chat window", // semantic paraphrase: expected to miss in keyless BM25 mode
];
results.checks.search = [];
for (const query of queries) {
  const response = await call("POST", "/smart-search", { query, project, limit: 5 });
  const items = response.json?.results ?? response.json?.items ?? [];
  results.checks.search.push({
    query,
    status: response.status,
    ms: response.ms,
    hits: Array.isArray(items) ? items.length : null,
    top: Array.isArray(items) && items[0] ? JSON.stringify(items[0]).slice(0, 240) : null,
    resultKeys: Object.keys(response.json ?? {}),
  });
}

// Cross-project isolation: the same query under another project must not leak.
const other = await call("POST", "/smart-search", {
  query: "TranscriptScrollController",
  project: "some-other-project",
  limit: 5,
});
results.checks.otherProjectHits = (other.json?.results ?? []).length;

// Context block for a new session in the same project (what turn-start injection would use).
const context = await call("POST", "/context", {
  sessionId: `${sessionId}_next`,
  project,
  budget: 800,
});
results.checks.context = {
  status: context.status,
  ms: context.ms,
  chars: String(context.json?.context ?? "").length,
  preview: String(context.json?.context ?? "").slice(0, 600),
};

const sessions = await call("GET", `/sessions?project=${encodeURIComponent(project)}`);
results.checks.sessions = {
  status: sessions.status,
  count: (sessions.json?.sessions ?? []).length,
};

results.finishedAt = new Date().toISOString();
if (out) writeFileSync(out, JSON.stringify(results, null, 2));
console.log(JSON.stringify(results.checks, null, 2));
