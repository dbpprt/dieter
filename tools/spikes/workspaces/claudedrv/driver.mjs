// claudedrv driver: runs one Claude Code turn through the Claude Agent SDK.
//
// stdin:  one JSON request {prompt, cwd, model, resume, maxTurns}
// stdout: JSONL — every SDK message verbatim, every PostToolUse /
//         PostToolUseFailure hook input tagged {type:"dieter_hook"}, driver
//         failures as {type:"dieter_error"} and a final {type:"dieter_end"}.
//
// Credentials arrive only through the inherited environment
// (CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CONFIG_DIR); nothing here reads or writes
// them.
import { readFileSync } from "node:fs";
import { query } from "@anthropic-ai/claude-agent-sdk";

function emit(obj) {
  return new Promise((resolve) => {
    if (process.stdout.write(JSON.stringify(obj) + "\n")) resolve();
    else process.stdout.once("drain", resolve);
  });
}

async function exit(code) {
  await new Promise((resolve) => process.stdout.write("", resolve));
  process.exit(code);
}

let req;
try {
  req = JSON.parse(readFileSync(0, "utf8"));
} catch (err) {
  await emit({ type: "dieter_error", error: `bad request: ${err?.message ?? err}` });
  await exit(2);
}

const hook = (name) => async (input) => {
  await emit({ type: "dieter_hook", hook: name, input });
  return {};
};

const options = {
  cwd: req.cwd,
  model: req.model,
  // Mirror Dieter's "allow-all" Claude configuration.
  permissionMode: "bypassPermissions",
  allowDangerouslySkipPermissions: true,
  systemPrompt: { type: "preset", preset: "claude_code" },
  // Isolation: no user/project/local settings, no CLAUDE.md.
  settingSources: [],
  // Flag-layer settings: turn the Bash changed-file diff on explicitly
  // (bypassPermissions alone enables it only behind a rollout gate).
  settings: { bashEditDiffEnabled: true },
  env: {
    ...process.env,
    CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: "1",
    CLAUDE_AGENT_SDK_CLIENT_APP: "dieter-spike-claudedrv/0",
  },
  hooks: {
    PostToolUse: [{ hooks: [hook("PostToolUse")] }],
    PostToolUseFailure: [{ hooks: [hook("PostToolUseFailure")] }],
  },
  stderr: (data) => process.stderr.write(data),
};
if (req.resume) options.resume = req.resume;
if (req.maxTurns) options.maxTurns = req.maxTurns;
if (req.claudePath) options.pathToClaudeCodeExecutable = req.claudePath;

let code = 0;
try {
  for await (const msg of query({ prompt: req.prompt, options })) {
    await emit(msg);
  }
} catch (err) {
  code = 1;
  await emit({ type: "dieter_error", error: String(err?.stack ?? err) });
}
await emit({ type: "dieter_end", code });
await exit(code);
