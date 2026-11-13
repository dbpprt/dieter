#!/usr/bin/env node
// Replay finished Strix run directories through the projector and check the
// invariants a Dieter transcript depends on. Exits non-zero on a violation.
//
// Usage: node replay.mjs STATE_DIR... (each containing strix_runs/<run>)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createStrixProjector, findRunDir } from "./projector.mjs";

let failures = 0;
for (const state of process.argv.slice(2)) {
  const runsRoot = join(state, "strix_runs");
  const chunks = [];
  const capabilities = [];
  const projector = createStrixProjector({
    runsRoot,
    messageId: "msg_replay",
    emit: (chunk) => chunks.push(chunk),
    emitCapability: (capability) => capabilities.push(capability),
  });
  try {
    const result = projector.finish({ exitCode: 0 });
    const runDir = findRunDir(runsRoot);
    const record = JSON.parse(readFileSync(join(runDir, "run.json"), "utf8"));
    const inputs = chunks.filter((c) => c.type === "tool-input-available").map((c) => c.toolCallId);
    const outputs = new Set(
      chunks.filter((c) => c.type === "tool-output-available").map((c) => c.toolCallId),
    );
    assert.equal(chunks[0]?.type, "start", "first chunk is start");
    assert.equal(chunks.at(-1)?.type, "finish", "last chunk is finish");
    assert.equal(new Set(inputs).size, inputs.length, "tool call ids are unique");
    if (record.status === "completed") {
      for (const id of inputs) assert.ok(outputs.has(id), `tool call ${id} has an output`);
    }
    const lastBySubagent = new Map();
    for (const c of capabilities.filter((c) => c.id === "subagents"))
      lastBySubagent.set(c.subagent.id, c.subagent);
    for (const subagent of lastBySubagent.values()) {
      assert.ok(
        ["completed", "cancelled", "failed"].includes(subagent.status),
        `subagent ${subagent.name} ends terminal (got ${subagent.status})`,
      );
    }
    // Strix writes vulnerabilities.json only once there is a finding.
    let findings = [];
    try {
      findings = JSON.parse(readFileSync(join(runDir, "vulnerabilities.json"), "utf8"));
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const findingCards = chunks.filter(
      (c) => c.type === "tool-input-available" && c.toolName === "strix_finding",
    );
    assert.equal(
      findingCards.length,
      (Array.isArray(findings) ? findings : findings.vulnerabilities || []).length,
      "one card per finding",
    );
    console.log(
      `ok   ${state}: status=${result.status} chunks=${chunks.length} tools=${inputs.length} subagents=${lastBySubagent.size} findings=${findingCards.length}`,
    );
  } catch (error) {
    failures++;
    console.log(`FAIL ${state}: ${error.message}`);
  }
}
process.exit(failures ? 1 : 0);
