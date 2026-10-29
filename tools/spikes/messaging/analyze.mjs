// Summarises spike runs: per-request usage (Claude finish-step parts, Codex
// rollout token_count events), steer latency and outcome flags.
// Usage: node analyze.mjs results/*.jsonl
import { readdirSync, readFileSync } from "node:fs";

const rows = [];
for (const file of process.argv.slice(2)) {
  const recs = readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
  const summary = recs.find((r) => r.kind === "summary")?.summary;
  if (!summary) continue;
  let requests = recs
    .filter((r) => r.kind === "finish-step" && r.usage?.inputTokens > 0)
    .map((r) => r.usage);
  if (requests.length === 0) {
    // Codex reports usage per turn only; read each model request from the rollout.
    const dir = `${file}.transcripts`;
    requests = [];
    for (const f of readdirSync(dir)) {
      for (const line of readFileSync(`${dir}/${f}`, "utf8").trim().split("\n")) {
        const ev = JSON.parse(line);
        const u =
          ev.payload?.type === "token_count" ? ev.payload.info?.last_token_usage : undefined;
        if (!u) continue;
        requests.push({
          inputTokens: u.input_tokens,
          inputTokenDetails: {
            cacheReadTokens: u.cached_input_tokens,
            cacheWriteTokens: u.cache_write_input_tokens ?? 0,
          },
          outputTokens: u.output_tokens,
        });
      }
    }
  }
  const sum = (f) => requests.reduce((a, u) => a + (f(u) ?? 0), 0);
  const steer = summary.steers?.find((s) => s.acceptedAt != null);
  const outcome = Object.entries(summary)
    .filter(([k]) =>
      [
        "compliedPineapple",
        "ranStep4",
        "mango",
        "kiwi",
        "burstWords",
        "shellSteps",
        "boardReads",
      ].includes(k),
    )
    .map(([k, v]) => `${k}=${Array.isArray(v) ? v.join("") : v}`)
    .join(" ");
  rows.push({
    run: `${summary.adapter}/${summary.scenario}`,
    requests: requests.length,
    input: sum((u) => u.inputTokens),
    cacheRead: sum((u) => u.inputTokenDetails?.cacheReadTokens),
    uncached: sum((u) => u.inputTokens - (u.inputTokenDetails?.cacheReadTokens ?? 0)),
    output: sum((u) => u.outputTokens),
    perRequestInput: requests.map((u) => u.inputTokens).join(","),
    steerAcceptMs: steer ? steer.acceptedAt - steer.requestedAt : "",
    outcome,
  });
}
console.table(rows);
