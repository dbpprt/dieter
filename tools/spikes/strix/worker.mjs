#!/usr/bin/env node
// Stand-in for a Dieter harness worker turn with a `strix` adapter.
//
// One Dieter turn = one Strix process. The first turn starts a scan of the
// card's checkout; later turns resume the same run with the new message as
// the instruction. Frames go to --out as NDJSON in the same envelope the
// runner sends to the daemon ({type:"chunk"} / {type:"capability"}).
//
// Usage:
//   node worker.mjs --session S --project PATH --prompt TEXT --out FILE
//                   [--scan-mode quick] [--budget USD] [--interrupt-after SEC]

import { spawn } from "node:child_process";
import { appendFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { createStrixProjector, findRunDir } from "./projector.mjs";

const { values } = parseArgs({
  options: {
    session: { type: "string" },
    project: { type: "string" },
    prompt: { type: "string", default: "" },
    out: { type: "string" },
    "scan-mode": { type: "string", default: "quick" },
    budget: { type: "string", default: "" },
    "interrupt-after": { type: "string", default: "" },
    "spike-root": { type: "string", default: "/Volumes/External/strix-spike" },
  },
});

const here = dirname(fileURLToPath(import.meta.url));
const state = join(values["spike-root"], "state", values.session);
const runsRoot = join(state, "strix_runs");
const messageId = `msg_${Date.now().toString(36)}`;
writeFileSync(values.out, "");
const t0 = Date.now();
const send = (frame) =>
  appendFileSync(values.out, JSON.stringify({ t: Date.now() - t0, ...frame }) + "\n");

const priorRun = findRunDir(runsRoot);
const args = ["-n"];
if (priorRun) {
  // Follow-up message: continue the same Strix run.
  args.push("--resume", basename(priorRun));
  if (values.prompt) args.push("--instruction", values.prompt);
} else {
  args.push("--target", values.project, "--scan-mode", values["scan-mode"]);
  if (values.prompt) args.push("--instruction", values.prompt);
}
if (values.budget) args.push("--max-budget", values.budget);

// Prime before spawning so no new item can slip under the cursor.
const projector = createStrixProjector({
  runsRoot,
  messageId,
  emit: (chunk) => send({ type: "chunk", chunk }),
  emitCapability: (capability) => send({ type: "capability", capability }),
});
if (priorRun) projector.prime();
send({ type: "spawn", args, resume: Boolean(priorRun) });
const child = spawn(join(here, "run-strix.sh"), [values.session, ...args], {
  stdio: ["ignore", "pipe", "pipe"],
  detached: true,
  env: { ...process.env, SPIKE_ROOT: values["spike-root"] },
});
let stdoutTail = "";
let stderrTail = "";
child.stdout.on("data", (d) => (stdoutTail = (stdoutTail + d).slice(-20000)));
child.stderr.on("data", (d) => (stderrTail = (stderrTail + d).slice(-20000)));

let firstRunAt;
const timer = setInterval(() => {
  const s = projector.poll();
  if (s.runDir && firstRunAt == null) {
    firstRunAt = Date.now() - t0;
    send({ type: "run-dir", runDir: s.runDir, afterMs: firstRunAt });
  }
}, 500);

let interruptedAt;
if (values["interrupt-after"]) {
  setTimeout(
    () => {
      interruptedAt = Date.now() - t0;
      send({ type: "interrupt", signal: "SIGINT" });
      // The shell script execs nothing; signal its process group.
      process.kill(-child.pid, "SIGINT");
    },
    Number(values["interrupt-after"]) * 1000,
  );
}

child.on("exit", (code, signal) => {
  clearInterval(timer);
  const result = projector.finish({ exitCode: code, budgetUSD: values.budget });
  send({
    type: "exit",
    code,
    signal,
    result,
    durationMs: Date.now() - t0,
    interruptToExitMs: interruptedAt != null ? Date.now() - t0 - interruptedAt : undefined,
  });
  writeFileSync(values.out.replace(/\.ndjson$/, ".stdout.txt"), stdoutTail);
  writeFileSync(values.out.replace(/\.ndjson$/, ".stderr.txt"), stderrTail);
  process.exit(0);
});
