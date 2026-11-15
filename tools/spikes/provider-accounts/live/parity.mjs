#!/usr/bin/env node
// Phase 0: what a Claude config directory gives a session — slash commands
// (incl. skills and plugin commands), agents, MCP servers — read through the
// SDK control channel without a prompt. Options mirror the adapter's bridge
// (no settingSources override). Prints names so two directories can be diffed.
//   node parity.mjs --runtime DIR      (CLAUDE_CONFIG_DIR from the environment)
import { join } from "node:path";
const runtime = process.argv[process.argv.indexOf("--runtime") + 1];
const { query } = await import(
  join(runtime, "node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs")
);
let release;
const idle = new Promise((r) => (release = r));
async function* input() {
  await idle;
}
const q = query({ prompt: input(), options: { cwd: process.cwd() } });
const out = {};
try {
  out.commands = (await q.supportedCommands()).map((c) => c.name).sort();
  out.agents = (await q.supportedAgents()).map((a) => a.name).sort();
  out.mcp = (await q.mcpServerStatus()).map((s) => `${s.name}:${s.status}`).sort();
  const init = await q.initializationResult();
  out.pluginsApplied = (init.plugins_applied ?? []).map((p) => p.name ?? p).sort();
} catch (error) {
  out.error = String(error?.message ?? error);
}
release();
q.close?.();
console.log(JSON.stringify(out));
process.exit(0);
