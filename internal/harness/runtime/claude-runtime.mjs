import { createClaudeCode } from "@ai-sdk/harness-claude-code";
import { runtimeLinkedBootstrap } from "./runtime-packages.mjs";

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
