#!/usr/bin/env node
// Phase 0 turn driver: runs one turn through the same adapters, local sandbox
// and HarnessAgent that internal/harness/runtime/runner.mjs uses, with an
// explicit adapter `auth` value, so account wiring can be checked end to end.
//
//   node turn.mjs --runtime DIR --harness claude-code|codex --project DIR
//                 --root DIR --prompt TEXT --out FILE
//                 [--auth JSON | --auth-from-env A,B] [--resume FILE] [--save FILE] [--model M]
//                 [--web-search] [--host-tool]
//
// The caller controls the process environment (CLAUDE_CONFIG_DIR, CODEX_HOME,
// CODEX_API_KEY, …). --auth is passed to createLocalClaudeCode or
// createLocalCodex unchanged; omit it to get today's runner behaviour.
// --host-tool adds a Dieter-style host tool (present_content stand-in) so a
// turn shows whether the provider route accepts Dieter's tool shape.

import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const opts = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const key = argv[i].replace(/^--/, "");
  if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) opts[key] = argv[++i];
  else opts[key] = true;
}
const runtimeDir = opts.runtime;
process.chdir(runtimeDir);
const t0 = Date.now();
const log = (rec) =>
  appendFileSync(opts.out, JSON.stringify({ t: Date.now() - t0, ...rec }) + "\n");
const imp = (p) => import(join(runtimeDir, p));
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

// --auth-from-env A,B builds the auth object from those environment variables,
// so tokens never appear in argv.
const auth = opts["auth-from-env"]
  ? Object.fromEntries(
      String(opts["auth-from-env"])
        .split(",")
        .filter((k) => process.env[k])
        .map((k) => [k, process.env[k]]),
    )
  : opts.auth
    ? JSON.parse(opts.auth)
    : undefined;
log({
  kind: "config",
  harness: opts.harness,
  model: opts.model,
  authKeys: auth ? Object.keys(auth) : null,
  configDir: process.env.CLAUDE_CONFIG_DIR,
  codexHome: process.env.CODEX_HOME,
});
const settings = { ...(auth === undefined ? {} : { auth }) };
const harness =
  opts.harness === "codex"
    ? createLocalCodex({
        ...settings,
        reasoningEffort: "low",
        webSearch: opts["web-search"] === true,
        codexConfig: {
          service_tier: "default",
          features: { fast_mode: true },
          ...(opts["codex-config"] ? JSON.parse(opts["codex-config"]) : {}),
        },
      })
    : createLocalClaudeCode({ ...settings, effort: "low" });

const workDir = "workspaces/spike/repo";
const sandbox = await createLocalSandboxProvider({
  root: opts.root,
  projectPath: opts.project,
  workDir,
});
const tools = {};
if (opts["host-tool"]) {
  tools.present_content = tool({
    description: "Show a file or URL to the user in the workspace pane.",
    inputSchema: z.object({ path: z.string().optional(), url: z.string().optional() }),
    execute: async (input) => {
      log({ kind: "host-tool", input });
      return { requested: true };
    },
  });
}
const agent = new HarnessAgent({
  harness,
  sandbox,
  model: opts.model,
  instructions: "You are running inside Dieter's provider-accounts spike. Be brief.",
  tools,
  permissionMode: "allow-all",
  sandboxConfig: { workDir },
});
const resumeFrom = opts.resume ? JSON.parse(readFileSync(opts.resume, "utf8")) : undefined;
const session = await agent.createSession({
  sessionId: opts["session-id"] ?? "p0-spike",
  ...(resumeFrom ? { resumeFrom } : {}),
});
const result = await agent.stream({ session, prompt: opts.prompt });
let text = "";
const counts = {};
for await (const part of result.stream) {
  counts[part.type] = (counts[part.type] ?? 0) + 1;
  if (part.type === "text-delta") text += part.text ?? part.delta ?? "";
  else if (part.type === "tool-call")
    log({
      kind: "tool-call",
      name: part.toolName,
      input: JSON.stringify(part.input).slice(0, 200),
    });
  else if (part.type === "tool-result")
    log({
      kind: "tool-result",
      name: part.toolName,
      output: JSON.stringify(part.output ?? part.result ?? "").slice(0, 200),
    });
  else if (part.type === "error")
    log({ kind: "stream-error", error: String(part.error?.message ?? part.error).slice(0, 600) });
  else if (part.type === "finish")
    log({ kind: "finish", finishReason: part.finishReason, usage: part.totalUsage });
  else if (part.type.startsWith("data-") || part.type === "raw")
    log({ kind: part.type, data: JSON.stringify(part.data ?? part.rawValue ?? "").slice(0, 400) });
}
const state = await session.stop();
if (opts.save) writeFileSync(opts.save, JSON.stringify(state));
log({
  kind: "done",
  text: text.slice(0, 1200),
  counts,
  sessionKeys: Object.keys(state?.data ?? {}),
});
console.log(JSON.stringify({ text: text.slice(0, 600), counts }));
process.exit(0);
