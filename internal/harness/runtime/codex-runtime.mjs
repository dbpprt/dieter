import { createCodex } from "@ai-sdk/harness-codex";
import { runtimeLinkedBootstrap } from "./runtime-packages.mjs";

// The adapter's bridge pins its own older CLI and installs it with a package
// manager. Link the CLI Dieter's runtime ships (package-lock.json) instead and
// keep the adapter's transport, session resume, tools, and bridge unchanged.
export function createLocalCodex(settings = {}) {
  // Ultra is a CLI orchestration mode, not a Responses API effort. Codex 0.159
  // advertises it, but this adapter's protocol enum stops at max. Its supported
  // arbitrary config channel reaches the same CLI setting without narrowing it.
  const harness = createCodex(
    settings.reasoningEffort === "ultra"
      ? {
          ...settings,
          reasoningEffort: undefined,
          codexConfig: { ...settings.codexConfig, model_reasoning_effort: "ultra" },
        }
      : settings,
  );
  return {
    ...harness,
    async getBootstrap(options) {
      return runtimeLinkedBootstrap(await harness.getBootstrap(options), {
        agent: "codex",
        requires: ["@openai/codex"],
      });
    },
  };
}
