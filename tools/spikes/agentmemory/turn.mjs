#!/usr/bin/env node
// Runs one real harness turn through the same adapters, local sandbox and
// HarnessAgent that internal/harness/runtime/runner.mjs uses, with two
// Dieter-style host tools backed by an agentmemory server:
//   memory_recall {query, limit?} -> smart-search (project scoped) + expand
//   memory_save   {content, kind?, concepts?} -> remember
// Run it in an empty project directory so memory is the only source of the
// answer, then check whether the agent reached for the tool unprompted.
//
//   AGENTMEMORY_URL=… AGENTMEMORY_SECRET_FILE=… \
//   node turn.mjs --runtime internal/harness/runtime --harness claude-code|codex \
//     --project /tmp/empty --root /tmp/root --prompt TEXT --out turn.ndjson [--model M]
//
// --backend builtin --index-bin BIN --index-db DB answers memory_recall from
// the built-in index prototype (../memory-index) instead of agentmemory.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

const opts = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const key = argv[i].replace(/^--/, "");
  if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) opts[key] = argv[++i];
  else opts[key] = true;
}
const runtimeDir = opts.runtime;
const base = process.env.AGENTMEMORY_URL ?? "http://127.0.0.1:13111";
const builtin = opts.backend === "builtin";
const secret = builtin ? "" : readFileSync(process.env.AGENTMEMORY_SECRET_FILE, "utf8").trim();
const memoryProject = opts["memory-project"] ?? "dieter";
process.chdir(runtimeDir);
const t0 = Date.now();
const log = (record) =>
  appendFileSync(opts.out, JSON.stringify({ t: Date.now() - t0, ...record }) + "\n");
const imp = (path) => import(join(process.cwd(), path));
const [
  { HarnessAgent },
  { tool },
  { z },
  { createLocalCodex },
  { createLocalClaudeCode },
  { createLocalSandboxProvider },
] = await Promise.all([
  imp("node_modules/@ai-sdk/harness/dist/agent/index.js").catch(() =>
    imp("node_modules/@ai-sdk/harness/dist/agent/index.mjs"),
  ),
  imp("node_modules/ai/dist/index.js"),
  imp("node_modules/zod/index.js"),
  imp("codex-runtime.mjs"),
  imp("claude-runtime.mjs"),
  imp("local-sandbox.mjs"),
]);

async function memory(path, body) {
  const response = await fetch(`${base}/agentmemory${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${secret}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error(`agentmemory ${path}: HTTP ${response.status}`);
  return response.json();
}
const clip = (text, limit) =>
  text && text.length > limit ? `${text.slice(0, limit)}…` : (text ?? "");

const tools = {
  memory_recall: tool({
    description:
      "Search this project's memory of earlier Dieter conversations (prompts, tool calls, results and final answers from every harness). Returns the best matches with the card each came from; read a card in full with `dieter card transcript CARD`.",
    inputSchema: z.object({
      query: z.string().min(2).max(500),
      limit: z.number().int().min(1).max(10).optional(),
    }),
    execute: async ({ query, limit = 6 }) => {
      const started = Date.now();
      if (builtin) {
        const raw = execFileSync(opts["index-bin"], [
          "-db",
          opts["index-db"],
          "-query",
          query,
          "-limit",
          String(limit),
        ]);
        const { hits } = JSON.parse(raw.toString());
        log({
          kind: "host-tool",
          name: "memory_recall",
          backend: "builtin",
          query,
          hits: hits.length,
          ms: Date.now() - started,
        });
        return { hits };
      }
      const compact = await memory("/smart-search", { query, project: memoryProject, limit });
      const expandIds = (compact.results ?? [])
        .filter((item) => item.obsId)
        .map((item) => ({ obsId: item.obsId, sessionId: item.sessionId }));
      const expanded = expandIds.length
        ? await memory("/smart-search", { project: memoryProject, expandIds })
        : { results: [] };
      const hits = (expanded.results ?? []).map((item) => ({
        card: item.sessionId,
        at: item.observation?.timestamp,
        kind: item.observation?.type,
        title: item.observation?.title,
        text: clip(item.observation?.narrative, 600),
      }));
      const memories = (compact.results ?? [])
        .filter((item) => item.layer === "memory")
        .map((item) => clip(JSON.stringify(item), 600));
      log({
        kind: "host-tool",
        name: "memory_recall",
        query,
        hits: hits.length,
        ms: Date.now() - started,
      });
      return { hits, memories };
    },
  }),
  memory_save: tool({
    description:
      "Save a durable lesson, decision or fact about this project so later conversations can recall it. Save only what will still be true and useful later; never secrets.",
    inputSchema: z.object({
      content: z.string().min(10).max(4000),
      kind: z.enum(["lesson", "decision", "fact", "pattern"]).optional(),
      concepts: z.array(z.string().max(64)).max(10).optional(),
    }),
    execute: async ({ content, kind, concepts }) => {
      if (builtin) {
        log({
          kind: "host-tool",
          name: "memory_save",
          backend: "builtin",
          content: clip(content, 300),
        });
        return { saved: false, reason: "the spike's built-in index is read-only" };
      }
      const result = await memory("/remember", {
        content,
        type: kind ?? "fact",
        concepts,
        project: memoryProject,
        agentId: opts.harness,
      });
      log({ kind: "host-tool", name: "memory_save", content: clip(content, 300) });
      return { saved: result.success === true, id: result.memory?.id };
    },
  }),
};

const instructions = [
  "You are running inside Dieter's agentmemory spike. Be brief.",
  "Project memory: earlier Dieter conversations in this project are searchable with the memory_recall tool. Before investigating a problem from scratch, recall what earlier conversations found; each hit names the card where the work happened. Save durable lessons with memory_save.",
].join("\n\n");

const harness =
  opts.harness === "codex"
    ? createLocalCodex({ reasoningEffort: "low", codexConfig: { service_tier: "default" } })
    : createLocalClaudeCode({ effort: "low" });
const workDir = "workspaces/spike/repo";
const sandbox = await createLocalSandboxProvider({
  root: opts.root,
  projectPath: opts.project,
  workDir,
});
const agent = new HarnessAgent({
  harness,
  sandbox,
  model: opts.model,
  instructions,
  tools,
  permissionMode: "allow-all",
  sandboxConfig: { workDir },
  ...(opts.harness === "claude-code" ? { inactiveTools: [] } : {}),
});
log({ kind: "config", harness: opts.harness, model: opts.model ?? null, prompt: opts.prompt });
const session = await agent.createSession({ sessionId: `am-spike-${Date.now().toString(36)}` });
const result = await agent.stream({ session, prompt: opts.prompt });
let text = "";
const toolCalls = [];
for await (const part of result.stream) {
  if (part.type === "text-delta") text += part.text ?? part.delta ?? "";
  else if (part.type === "tool-call") {
    toolCalls.push(part.toolName);
    log({
      kind: "tool-call",
      name: part.toolName,
      input: JSON.stringify(part.input).slice(0, 300),
    });
  } else if (part.type === "error")
    log({ kind: "stream-error", error: String(part.error?.message ?? part.error).slice(0, 600) });
  else if (part.type === "finish")
    log({ kind: "finish", finishReason: part.finishReason, usage: part.totalUsage });
}
await session.stop();
log({ kind: "done", toolCalls, text: text.slice(0, 2000) });
console.log(JSON.stringify({ toolCalls, text: text.slice(0, 1500) }, null, 2));
process.exit(0);
