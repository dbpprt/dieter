#!/usr/bin/env node
// REST probe for an isolated OpenViking server, run keyless (built-in local
// embedding, no VLM): can Dieter capture card turns as sessions or resources
// and find them again without a model provider?
//
//   OPENVIKING_URL=http://127.0.0.1:11933 node probe.mjs --out probe.json
//
// Never point this at an operator's OpenViking: it writes sessions and files.

import { writeFileSync } from "node:fs";

const base = process.env.OPENVIKING_URL ?? "http://127.0.0.1:11933";
const apiKey = process.env.OPENVIKING_API_KEY;
const outIndex = process.argv.indexOf("--out");
const out = outIndex > 0 ? process.argv[outIndex + 1] : undefined;
const results = { base, startedAt: new Date().toISOString(), calls: [], checks: {} };

async function call(method, path, body) {
  const started = performance.now();
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(apiKey ? { "X-API-Key": apiKey } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  const ms = Math.round(performance.now() - started);
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = text.slice(0, 300);
  }
  results.calls.push({ method, path: path.split("?")[0], status: response.status, ms });
  return { status: response.status, json, ms };
}
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const brief = (value) => JSON.stringify(value).slice(0, 500);

results.checks.health = (await call("GET", "/health")).json;

// (a) Card = session; one turn = messages + commit.
const sessionId = `c_probe_${Date.now().toString(36)}`;
const created = await call("POST", "/api/v1/sessions", { session_id: sessionId });
const batch = await call("POST", `/api/v1/sessions/${sessionId}/messages/batch`, {
  messages: [
    { role: "user", content: "Why does the Mac transcript jump when new chunks stream in?" },
    {
      role: "assistant",
      parts: [
        {
          type: "tool",
          tool_id: "call_1",
          tool_name: "Read",
          tool_input: {
            file_path: "apps/apple/mac/Sources/Transcript/TranscriptScrollController.swift",
          },
          tool_status: "completed",
          tool_output:
            "final class TranscriptScrollController { // owns scroll position natively }",
        },
        {
          type: "text",
          text: "The jump came from SwiftUI's ScrollView re-anchoring on content-size changes. Scroll position is now owned by a native NSScrollView controller (TranscriptScrollController).",
        },
      ],
    },
  ],
});
const commit = await call("POST", `/api/v1/sessions/${sessionId}/commit`, {});
results.checks.session = {
  create: created.status,
  batch: { status: batch.status, body: brief(batch.json) },
  commit: { status: commit.status, ms: commit.ms, body: brief(commit.json) },
};
const taskId = commit.json?.result?.task_id;
if (taskId) {
  let task;
  for (let i = 0; i < 30; i++) {
    task = await call("GET", `/api/v1/tasks/${taskId}`);
    const status = task.json?.result?.status;
    if (status && !["pending", "running", "queued"].includes(status)) break;
    await wait(1000);
  }
  results.checks.session.task = brief(task.json);
}

// (b) Card digest = resource file.
const uri = `viking://resources/dieter/cards/${sessionId}.md`;
const digest = [
  `# Card ${sessionId}: Mac transcript scroll jumps`,
  "",
  "User: Why does the Mac transcript jump when new chunks stream in?",
  "Tool Read apps/apple/mac/Sources/Transcript/TranscriptScrollController.swift",
  "Answer: The jump came from SwiftUI's ScrollView re-anchoring on content-size changes. Scroll position is now owned by a native NSScrollView controller (TranscriptScrollController).",
].join("\n");
const write = await call("POST", "/api/v1/content/write", {
  uri,
  content: digest,
  mode: "create",
  wait: true,
});
results.checks.resourceWrite = { status: write.status, ms: write.ms, body: brief(write.json) };
await wait(3000);

for (const [label, query] of [
  ["exact", "TranscriptScrollController"],
  ["paraphrase", "transcript scrolling jumps while streaming"],
]) {
  const find = await call("POST", "/api/v1/search/find", { query, limit: 5 });
  const result = find.json?.result ?? {};
  results.checks[`find_${label}`] = {
    status: find.status,
    ms: find.ms,
    memories: (result.memories ?? []).length,
    resources: (result.resources ?? []).map((item) => item.uri),
    error: find.status >= 400 ? brief(find.json) : undefined,
  };
}
const search = await call("POST", "/api/v1/search/search", {
  query: "transcript scroll jumps",
  limit: 5,
});
results.checks.search = { status: search.status, ms: search.ms, body: brief(search.json) };
const grep = await call("POST", "/api/v1/search/grep", {
  pattern: "TranscriptScrollController",
  uri: "viking://",
});
results.checks.grep = { status: grep.status, ms: grep.ms, body: brief(grep.json) };
const sessionContext = await call("GET", `/api/v1/sessions/${sessionId}/context?token_budget=2000`);
results.checks.sessionContext = { status: sessionContext.status, body: brief(sessionContext.json) };

results.finishedAt = new Date().toISOString();
if (out) writeFileSync(out, JSON.stringify(results, null, 2));
console.log(JSON.stringify(results.checks, null, 2));
