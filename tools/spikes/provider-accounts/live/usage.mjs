#!/usr/bin/env node
// Phase 0: read account info and plan usage from the official Claude Code
// binary through the Agent SDK, without sending a prompt.
//   node usage.mjs --runtime DIR      (CLAUDE_CONFIG_DIR from the environment)
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
const q = query({ prompt: input(), options: { cwd: process.cwd(), settingSources: [] } });
const started = Date.now();
const out = {};
try {
  const info = await q.accountInfo();
  out.accountInfo = {
    ...info,
    email: info.email ? "<email>" : undefined,
    organization: info.organization ? "<org>" : undefined,
  };
  const usage = await q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({
    skipBehaviors: true,
  });
  out.usage = {
    subscription_type: usage.subscription_type,
    rate_limits_available: usage.rate_limits_available,
    rate_limits: usage.rate_limits,
  };
} catch (error) {
  out.error = String(error?.message ?? error);
}
out.ms = Date.now() - started;
release();
q.close?.();
console.log(JSON.stringify(out, null, 2));
process.exit(0);
