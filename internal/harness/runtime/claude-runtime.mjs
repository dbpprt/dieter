import { createClaudeCode } from "@ai-sdk/harness-claude-code";
import { runtimeLinkedBootstrap } from "./runtime-packages.mjs";

// Claude Code tools Dieter removes from the model's tool list (they reach the
// bridge as disallowedTools). Each one answers after the reply or waits for a
// prompt Dieter does not show:
// - askUserQuestions (AskUserQuestion) pauses the turn for an interactive
//   answer: the question never reached the transcript, and a pending answer
//   failed any follow-up prompt in the same worker. Agents ask in their reply.
// - Monitor, ScheduleWakeup, CronCreate and Workflow promise a later
//   notification or wake-up, but the bridge ends the query at the turn's
//   result and Dieter stops the Claude process, so the follow-up is lost (the
//   same reason createLocalClaudeCode disables background Bash and Agent calls).
export const dieterDisabledClaudeTools = Object.freeze([
  "askUserQuestions",
  "Monitor",
  "ScheduleWakeup",
  "CronCreate",
  "CronDelete",
  "CronList",
  "Workflow",
]);

// HarnessAgent rejects names the adapter does not declare; keep the ones the
// pinned adapter knows.
export function claudeInactiveBuiltinTools(harness) {
  const declared = new Set(Object.keys(harness?.builtinTools ?? {}));
  return dieterDisabledClaudeTools.filter((name) => declared.has(name));
}

// The adapter's bridge recipe pins its own Claude Agent SDK and installs it
// with a package manager. Keep the adapter's transport and bridge, but link
// the SDK Dieter's runtime ships (package-lock.json) instead. The SDK runs the
// Claude Code executable from its own platform package, so the separate
// @anthropic-ai/claude-code CLI package the bridge also declares is unused.
export function createLocalClaudeCode(settings = {}) {
  const harness = createClaudeCode({
    ...settings,
    // The bridge closes its query at the final result; native background
    // task notifications cannot resume a completed Dieter turn. Keep Bash
    // and Agent calls foreground and use Dieter's tools for durable processes.
    env: { ...settings.env, CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: "1" },
  });
  return {
    ...harness,
    async getBootstrap(options) {
      return runtimeLinkedBootstrap(await harness.getBootstrap(options), {
        agent: "claude",
        requires: ["@anthropic-ai/claude-agent-sdk"],
        omit: ["@anthropic-ai/claude-code"],
      });
    },
  };
}
