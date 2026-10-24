// Summarises atrium.mjs runs: per agent turn usage, board stats, outcome.
// Usage: node atrium-report.mjs results/atrium/*.jsonl
import { readdirSync, readFileSync } from "node:fs";

const k = (n) => (n == null ? "-" : `${(n / 1000).toFixed(1)}k`);
for (const file of process.argv.slice(2)) {
  const recs = readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
  const s = recs.find((r) => r.kind === "summary")?.summary;
  if (!s) {
    console.log(`\n## ${file}: no summary`);
    continue;
  }
  // Codex model requests per agent come from the rollouts (one file per thread).
  const codexRequests = {};
  try {
    const dir = `${file}.transcripts`;
    for (const f of readdirSync(dir).filter((x) => x.startsWith("rollout-"))) {
      const text = readFileSync(`${dir}/${f}`, "utf8");
      const id = text.match(/You are agent (\w)/)?.[1] ?? "?";
      codexRequests[id] = (text.match(/"type":"token_count"/g) ?? []).length;
    }
  } catch {}
  console.log(`\n## ${file.split("/").at(-1)}  (board: ${s.useBoard})`);
  for (const a of s.agents) {
    for (const t of a.turns) {
      const u = t.totalUsage ?? {};
      const req = a.harness === "codex" ? `${codexRequests[a.id] ?? "?"} (all turns)` : t.requests;
      console.log(
        `  ${a.id} ${a.harness.padEnd(11)} ${t.label.padEnd(7)} ${String(Math.round(t.ms / 1000)).padStart(3)} s  requests ${req}  input ${k(u.inputTokens)} (cached ${k(u.inputTokenDetails?.cacheReadTokens)})  tools ${t.tools.join(",")}`,
      );
      console.log(`      → ${t.tail.replace(/\s+/g, " ").slice(-170)}`);
    }
  }
  const st = s.stats;
  console.log(
    `  board: hooks ${st.hookCalls} (outputs ${st.hookOutputs}, ~${st.hookCalls ? Math.round((st.hookSpawnMs ?? 0) / st.hookCalls) : 0} ms spawn each), denies ${st.denies}, hook-push ${st.contexts}, steers ${st.steers} (rejected ${st.steerRejected}), wakes ${st.wakes}, agent posts ${st.posts}, checks ${st.checks}, inbox ${st.inboxReads}`,
  );
  for (const p of s.posts) console.log(`  post ${p}`);
  const f = s.files;
  console.log(
    `  files: m2 reviewed=${!!f["src/module2.js"].reviewedLine} m3 reviewed=${!!f["src/module3.js"].reviewedLine} m3 header='${f["src/module3.js"].header}' m3 MAX_TIER_3=${!!f["src/module3.js"].maxTier} m5 header='${f["src/module5.js"].header}'`,
  );
  console.log(`  commits: ${s.commits.map((c) => c.replace(/\n/g, " ")).join(" | ")}`);
  if (s.maxTierCommit != null) console.log(`  MAX_TIER_3 introduced by: '${s.maxTierCommit}'`);
  console.log(`  dirty: ${s.dirty || "(clean)"}`);
  if (s.papaya != null) console.log(`  papaya delivered via PostToolUse: ${s.papaya}`);
}
