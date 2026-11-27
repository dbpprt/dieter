#!/usr/bin/env node
// Replays finished Dieter cards into OpenViking the only way that works
// without a model provider: as resource files that the built-in local
// embedder indexes. One observation (same mapping as
// ../agentmemory/replay.mjs) becomes one small Markdown file under
// viking://resources/dieter/cards/<card>/, so recall granularity matches the
// agentmemory run. Transcripts are cached in --cache to avoid refetching.
//
//   OPENVIKING_URL=http://127.0.0.1:11933 DIETER=dieter \
//     node replay.mjs --cache DIR --out stats.json [--batch 100] [--wait false] CARD_ID...
// --wait false enqueues indexing and returns; poll GET /api/v1/observer/queue.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const opts = { cards: [] };
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) opts[argv[i].slice(2)] = argv[++i];
  else opts.cards.push(argv[i]);
}
const base = process.env.OPENVIKING_URL ?? "http://127.0.0.1:11933";
const dieter = process.env.DIETER ?? "dieter";
const batchSize = Number(opts.batch ?? 100);
const docLimit = 1500;
if (opts.cache) mkdirSync(opts.cache, { recursive: true });

const clip = (value, limit) => {
  const text = typeof value === "string" ? value : JSON.stringify(value ?? "");
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
};

function transcriptFor(cardId) {
  const cached = opts.cache && join(opts.cache, `${cardId}.json`);
  if (cached && existsSync(cached)) return JSON.parse(readFileSync(cached, "utf8"));
  const raw = execFileSync(dieter, ["card", "transcript", cardId], {
    maxBuffer: 256 << 20,
  }).toString();
  if (cached) writeFileSync(cached, raw, { mode: 0o600 });
  return JSON.parse(raw);
}

function observations(cardId, messages) {
  const out = [];
  for (const message of messages) {
    const parts = message.parts ?? [];
    if (message.role === "user") {
      const prompt = parts
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n")
        .trim();
      if (prompt) out.push({ kind: "prompt", text: `User asked: ${prompt}` });
      continue;
    }
    if (message.role !== "assistant") continue;
    let lastText = "";
    for (const part of parts) {
      const isTool = part.type === "dynamic-tool" || part.type?.startsWith("tool-");
      if (part.type === "text" && part.text?.trim()) lastText = part.text;
      if (!isTool) continue;
      const tool = part.toolName ?? part.type.slice("tool-".length);
      const input = clip(part.input ?? part.inputPreview ?? "", 600);
      if (part.state === "output-error") {
        out.push({
          kind: "failure",
          text: `Tool ${tool} failed.\nInput: ${input}\nError: ${clip(part.errorText ?? part.outputPreview ?? "", 600)}`,
        });
      } else if (part.state === "output-available") {
        out.push({
          kind: "tool",
          text: `Tool ${tool}.\nInput: ${input}\nOutput: ${clip(part.output ?? part.outputPreview ?? "", 600)}`,
        });
      }
    }
    if (lastText.trim()) out.push({ kind: "answer", text: `Assistant answered: ${lastText}` });
  }
  return out;
}

async function batchWrite(rootUri, operations) {
  const started = performance.now();
  const response = await fetch(`${base}/api/v1/content/batch-write`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ root_uri: rootUri, operations, wait: opts.wait !== "false" }),
  });
  const json = await response.json().catch(() => ({}));
  return { status: response.status, json, ms: performance.now() - started };
}

const stats = { cards: [], totals: { documents: 0, failedBatches: 0, ms: 0 } };
for (const cardId of opts.cards) {
  let transcript;
  try {
    transcript = transcriptFor(cardId);
  } catch (error) {
    stats.cards.push({ cardId, error: String(error.message).slice(0, 200) });
    continue;
  }
  const card = transcript.detail?.card ?? {};
  const docs = observations(cardId, transcript.conversation?.messages ?? []);
  const root = `viking://resources/dieter/cards/${cardId}`;
  const header = `Dieter card ${cardId} (${card.provider ?? "unknown"}): ${card.title ?? ""}`;
  const operations = docs.map((doc, index) => ({
    uri: `${root}/${String(index).padStart(5, "0")}-${doc.kind}.md`,
    content: clip(`${header}\n\n${doc.text}`, docLimit),
    mode: "upsert",
  }));
  const started = performance.now();
  let failed = 0;
  // batch-write needs an existing root directory.
  await fetch(`${base}/api/v1/fs/mkdir`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ uri: root }),
  });
  for (let i = 0; i < operations.length; i += batchSize) {
    const result = await batchWrite(root, operations.slice(i, i + batchSize));
    if (result.status !== 200 || result.json?.status !== "ok") {
      failed++;
      if (failed === 1)
        console.error(
          `${cardId} batch ${i}: HTTP ${result.status} ${JSON.stringify(result.json).slice(0, 300)}`,
        );
    }
  }
  const ms = performance.now() - started;
  stats.cards.push({
    cardId,
    documents: operations.length,
    failedBatches: failed,
    ms: Math.round(ms),
  });
  stats.totals.documents += operations.length;
  stats.totals.failedBatches += failed;
  stats.totals.ms += ms;
  console.error(
    `${cardId} ${operations.length} docs, ${failed} failed batches, ${Math.round(ms)} ms (${(ms / Math.max(1, operations.length)).toFixed(1)} ms/doc)`,
  );
}
stats.totals.ms = Math.round(stats.totals.ms);
stats.totals.msPerDocument = stats.totals.documents
  ? +(stats.totals.ms / stats.totals.documents).toFixed(1)
  : null;
if (opts.out) writeFileSync(opts.out, JSON.stringify(stats, null, 2));
console.log(JSON.stringify(stats.totals));
