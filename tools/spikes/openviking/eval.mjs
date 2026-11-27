#!/usr/bin/env node
// Recall-quality check for OpenViking over the replayed Dieter cards: the same
// 18 cases as tools/spikes/agentmemory/eval.mjs, scored by the card in each
// hit's viking://resources/dieter/cards/<card>/… URI.
//
//   OPENVIKING_URL=… node eval.mjs --mode find|search --label L --out eval.json

import { writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const opts = {};
for (let i = 0; i < argv.length; i += 2) opts[argv[i].slice(2)] = argv[i + 1];
const base = process.env.OPENVIKING_URL ?? "http://127.0.0.1:11933";
const mode = opts.mode ?? "find";

const cases = [
  ["Mac stays disconnected after waking from sleep", ["c_2c968e12cbcb9b753c743eda"]],
  [
    "card snaps back to its old lane after dragging until sync finishes",
    ["c_f655dd266c6bf6aa379543df", "c_9e3d656aa4b3f2d131fca4f8"],
  ],
  ["typing lag and lost characters in the Android chat composer", ["c_4bc088a8ee14bc855ffa1bc6"]],
  ["make the gateway unable to read relayed traffic", ["c_f696fe71ce67323d7741f6ec"]],
  ["store passwords and one-time codes that agents can request", ["c_6a2336d6bad3fefbe6ae5256"]],
  [
    "conversation fails but works again when I send another message",
    ["c_d41d7d280d689caeef578e1f"],
  ],
  [
    "screen share should reconnect instead of opening new connections on a flaky network",
    ["c_8c78397d41fe38c53be91c22"],
  ],
  ["presented file opens again every time I return to the chat", ["c_3fc6bf8294de8e0d0721d3ab"]],
  ["notch covers the status badges in the top bar", ["c_bed9938a20d5a1217d47640e"]],
  ["background waiters never come back in Claude and Oh My Pi", ["c_37b6ecbfda981defda3292cc"]],
  [
    "quick task text disappears when opening more options on Android",
    ["c_a575740181cb5475bbd3ee31"],
  ],
  ["do workflow runs or the repository leak credentials", ["c_610916ddd1068bae9cfed9c1"]],
  [
    "deploy the gateway from the main repository instead of the vps repo",
    ["c_6a6c24215b4b15574f9e8ecc"],
  ],
  ["high CPU usage and slow clicks in the native Mac app", ["c_2abfac4aea13510623a02eff"]],
  [
    "move business rules into one shared Kotlin multiplatform layer",
    ["c_110345b8db323582a785d65c", "c_a86c9cfda23f3832fa62d8a6", "c_4bc088a8ee14bc855ffa1bc6"],
  ],
  ["right click to delete a board on macOS", ["c_f99f060f1f5a34f598de4ec9"]],
  [
    "why are builds and emulator tests so slow",
    ["c_36e66b736dc63012924ecc47", "c_430635f7cbcff66f819c54fc", "c_30a95bc6b452a27db6712f01"],
  ],
  ["remove board comments from the daemon and every client", ["c_e809195040376175efa46dd0"]],
];

const cardOf = (uri) => /viking:\/\/resources\/dieter\/cards\/(c_[0-9a-f]+)/.exec(uri ?? "")?.[1];
const rows = [];
for (const [query, expected] of cases) {
  const started = performance.now();
  const response = await fetch(`${base}/api/v1/search/${mode}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, target_uri: "viking://resources/dieter/cards", limit: 50 }),
  });
  const json = await response.json();
  const ms = Math.round(performance.now() - started);
  const cards = [];
  for (const item of json.result?.resources ?? []) {
    const card = cardOf(item.uri);
    if (card && !cards.includes(card)) cards.push(card);
  }
  const rank = cards.findIndex((card) => expected.includes(card));
  rows.push({
    query,
    status: response.status,
    rank: rank < 0 ? null : rank + 1,
    ms,
    top3: cards.slice(0, 3),
  });
}
const hit = (k) => rows.filter((row) => row.rank && row.rank <= k).length;
const sorted = rows.map((row) => row.ms).sort((a, b) => a - b);
const summary = {
  label: opts.label ?? `openviking-${mode}`,
  cases: rows.length,
  hitAt1: hit(1),
  hitAt3: hit(3),
  hitAt5: hit(5),
  mrr: +(rows.reduce((sum, row) => sum + (row.rank ? 1 / row.rank : 0), 0) / rows.length).toFixed(
    3,
  ),
  p50ms: sorted[Math.floor(rows.length / 2)],
  maxMs: sorted[sorted.length - 1],
};
if (opts.out) writeFileSync(opts.out, JSON.stringify({ summary, rows }, null, 2));
for (const row of rows)
  console.error(`${row.rank ?? "-"}\t${row.ms}ms\t${row.status}\t${row.query}`);
console.log(JSON.stringify(summary));
