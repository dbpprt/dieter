import { createClaudeCode } from "@ai-sdk/harness-claude-code";
import { runtimeLinkedBootstrap } from "./runtime-packages.mjs";

import { tool } from "ai";
import { z } from "zod";

// Claude Code adds a native ClaudeDesign tool once the host has signed in to
// Claude Design. The adapter predates it, so declare it here: Dieter can then
// display its calls and deny it together with DesignSync when access is off.
const claudeDesignTool = {
  ...tool({
    description: "Create, edit, import or export Claude Design projects (claude.ai/design)",
    inputSchema: z.looseObject({ operation: z.string().optional() }),
  }),
  toolUseKind: "edit",
};

// Claude Code's artifact tools (Claude Design's home since it moved into
// Claude) are declared for the same reason.
const claudeArtifactTools = Object.fromEntries(
  ["Artifact", "ArtifactComments", "ArtifactData", "ArtifactCheck"].map((name) => [
    name,
    {
      ...tool({
        description: `Claude artifact operation (${name})`,
        inputSchema: z.looseObject({}),
      }),
      toolUseKind: name === "Artifact" ? "edit" : "readonly",
    },
  ]),
);

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
    builtinTools: {
      ClaudeDesign: claudeDesignTool,
      ...claudeArtifactTools,
      ...harness.builtinTools,
    },
    async getBootstrap(options) {
      return runtimeLinkedBootstrap(await harness.getBootstrap(options), {
        agent: "claude",
        requires: ["@anthropic-ai/claude-agent-sdk"],
        omit: ["@anthropic-ai/claude-code"],
      });
    },
  };
}
