#!/usr/bin/env node
// Prototype of a Dieter-native capture sink: reads finished Dieter
// conversations through the Dieter CLI (any harness: Codex, Claude Code, OMP,
// …) and maps their normalized UI message parts onto agentmemory
// observations, exactly as the daemon would at turn end. No harness hooks,
// no edits to ~/.claude, ~/.codex or other agent config.
//
//   AGENTMEMORY_URL=http://127.0.0.1:13111 AGENTMEMORY_SECRET_FILE=/tmp/.../secret \
//   DIETER=/opt/homebrew/var/dieter/service/bin/dieter \
//     node replay.mjs --project dieter --cwd /path/to/checkout --out stats.json CARD_ID...
//
// Mapping (one Dieter card = one agentmemory session; agentId = harness):
//   user text part                  -> prompt_submit {prompt}
//   tool part, output-available     -> post_tool_use {tool_name, tool_input, tool_output}
//   tool part, output-error         -> post_tool_failure {tool_name, tool_input, error}
//   last assistant text of a reply  -> stop {last_assistant_message}
//   reasoning parts                 -> skipped (never captured)
// Event ids hash (card, message id, part index): harness tool call ids such as
// Codex's "item_2" repeat across turns and are not unique on their own.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const opts = { cards: [] };
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) opts[argv[i].slice(2)] = argv[++i];
  else opts.cards.push(argv[i]);
}
const base = process.env.AGENTMEMORY_URL ?? "http://127.0.0.1:13111";
const secret = readFileSync(process.env.AGENTMEMORY_SECRET_FILE, "utf8").trim();
const dieter = process.env.DIETER ?? "dieter";
const project = opts.project ?? "dieter";
const cwd = opts.cwd ?? process.cwd();
const maxText = 4000;

const clip = (value, limit = maxText) => {
  const text = typeof value === "string" ? value : JSON.stringify(value ?? "");
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
};
const eventId = (...parts) =>
  createHash("sha256").update(parts.join("\u0000")).digest("hex").slice(0, 32);

async function post(path, body) {
  const started = performance.now();
  const response = await fetch(`${base}/agentmemory${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${secret}` },
    body: JSON.stringify(body),
  });
  const json = await response.json().catch(() => ({}));
  return { status: response.status, json, ms: performance.now() - started };
}

export function observationsFor(cardId, messages, fallbackTime) {
  const out = [];
  for (const message of messages) {
    const timestamp = message.createdAt ?? fallbackTime;
    const parts = message.parts ?? [];
    if (message.role === "user") {
      const prompt = parts
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n")
        .trim();
      if (prompt)
        out.push({
          hookType: "prompt_submit",
          timestamp,
          data: { prompt: clip(prompt) },
          key: [cardId, message.id, "prompt"],
        });
      continue;
    }
    if (message.role !== "assistant") continue;
    let lastText = "";
    parts.forEach((part, index) => {
      const isTool = part.type === "dynamic-tool" || part.type?.startsWith("tool-");
      if (part.type === "text" && part.text?.trim()) lastText = part.text;
      if (!isTool) return;
      const toolName = part.toolName ?? part.type.slice("tool-".length);
      // Full payloads live in the daemon's store; the CLI transcript carries
      // bounded previews, which is also roughly what a sink should send.
      const input = part.input ?? part.inputPreview ?? "";
      const key = [cardId, message.id, String(index)];
      if (part.state === "output-error") {
        out.push({
          hookType: "post_tool_failure",
          timestamp,
          key,
          data: {
            tool_name: toolName,
            tool_input: clip(input),
            error: clip(part.errorText ?? part.outputPreview ?? ""),
          },
        });
      } else if (part.state === "output-available") {
        out.push({
          hookType: "post_tool_use",
          timestamp,
          key,
          data: {
            tool_name: toolName,
            tool_input: clip(input),
            tool_output: clip(part.output ?? part.outputPreview ?? ""),
          },
        });
      }
    });
    if (lastText.trim())
      out.push({
        hookType: "stop",
        timestamp,
        key: [cardId, message.id, "stop"],
        data: { last_assistant_message: clip(lastText, 8000) },
      });
  }
  return out;
}

const stats = {
  project,
  cards: [],
  totals: { observations: 0, accepted: 0, duplicate: 0, other: 0, ms: 0 },
};
for (const cardId of opts.cards) {
  let transcript;
  try {
    transcript = JSON.parse(
      execFileSync(dieter, ["card", "transcript", cardId], { maxBuffer: 256 << 20 }).toString(),
    );
  } catch (error) {
    stats.cards.push({ cardId, error: String(error.message).slice(0, 200) });
    continue;
  }
  const card = transcript.detail?.card ?? {};
  const messages = transcript.conversation?.messages ?? [];
  const fallbackTime = card.lastActivityAt ?? new Date().toISOString();
  const start = await post("/session/start", {
    sessionId: cardId,
    project,
    cwd,
    title: card.title ?? cardId,
    agentId: card.provider ?? "unknown",
  });
  const observations = observationsFor(cardId, messages, fallbackTime);
  const counts = { accepted: 0, duplicate: 0, other: 0 };
  const started = performance.now();
  // Bounded concurrency, like a daemon-side queue would use.
  const queue = [...observations];
  await Promise.all(
    Array.from({ length: 4 }, async () => {
      while (queue.length) {
        const observation = queue.shift();
        const { key, ...rest } = observation;
        const response = await post("/observe", {
          ...rest,
          sessionId: cardId,
          project,
          cwd,
          eventId: eventId(...key),
        });
        if (response.status === 201) counts.accepted++;
        else if (response.status === 200) counts.duplicate++;
        else counts.other++;
      }
    }),
  );
  const ms = performance.now() - started;
  await post("/session/end", { sessionId: cardId, final: true });
  stats.cards.push({
    cardId,
    title: card.title,
    harness: card.provider,
    sessionStart: start.status,
    observations: observations.length,
    ...counts,
    ms: Math.round(ms),
  });
  stats.totals.observations += observations.length;
  stats.totals.accepted += counts.accepted;
  stats.totals.duplicate += counts.duplicate;
  stats.totals.other += counts.other;
  stats.totals.ms += ms;
  console.error(
    `${cardId} ${card.provider} ${observations.length} obs (${counts.accepted} new, ${counts.duplicate} dup, ${counts.other} other) ${Math.round(ms)} ms — ${card.title}`,
  );
}
stats.totals.ms = Math.round(stats.totals.ms);
stats.totals.msPerObservation = stats.totals.observations
  ? +(stats.totals.ms / stats.totals.observations).toFixed(2)
  : null;
if (opts.out) writeFileSync(opts.out, JSON.stringify(stats, null, 2));
console.log(JSON.stringify(stats.totals));
