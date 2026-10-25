import { createHash } from "node:crypto";

export const ompStreamTimeoutSeconds = 30 * 60;

export function ompRuntimeConfig() {
  // ACP ends a prompt when the agent is idle, even while native async jobs
  // are still running. Their promised follow-up is lost when Dieter stops
  // the session. Keep native tools foreground; detached processes belong to
  // Dieter's process manager and must be explicitly read before finalizing.
  return `providers:\n  streamFirstEventTimeoutSeconds: ${ompStreamTimeoutSeconds}\n  streamIdleTimeoutSeconds: ${ompStreamTimeoutSeconds}\nasync:\n  enabled: false\nbash:\n  autoBackground:\n    enabled: false\neval:\n  autoBackground:\n    enabled: false\n`;
}

export function codexConfig(request) {
  const fastMode = request.options?.fast_mode === "true";
  const config = {
    service_tier: fastMode ? "fast" : "default",
    features: { fast_mode: true },
  };
  const hookCommand =
    typeof request.channelHookCommand === "string" ? request.channelHookCommand.trim() : "";
  if (hookCommand) {
    config.features.hooks = true;
    config.hooks = codexChannelHooks(hookCommand);
  }
  return config;
}

// Agent channels claim files before Codex writes them. The PreToolUse group is
// marked trusted with the hash Codex computes for session-flag hooks (the
// scheme @ai-sdk/harness-codex uses for its own apply_patch hook).
export const CODEX_CHANNEL_HOOK_MATCHER = "^(apply_patch|Bash|Edit|Write)$";

export function codexChannelHooks(command) {
  const handler = { type: "command", command, timeout: 10, async: false };
  const hash = `sha256:${createHash("sha256")
    .update(
      JSON.stringify(
        canonicalize({
          event_name: "pre_tool_use",
          matcher: CODEX_CHANNEL_HOOK_MATCHER,
          hooks: [handler],
        }),
      ),
    )
    .digest("hex")}`;
  return {
    PreToolUse: [{ matcher: CODEX_CHANNEL_HOOK_MATCHER, hooks: [handler] }],
    state: {
      "/<session-flags>/config.toml:pre_tool_use:0:0": { enabled: true, trusted_hash: hash },
    },
  };
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value != null && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, canonicalize(item)]),
    );
  return value;
}

// OMP's CLI accepts every selector reported by `omp models`, while its ACP
// model config option exposes only the user's small model-cycling list. Launch
// bridges with the selected CLI model so Dieter's full discovered catalog
// remains executable.
export function ompACPArgs(request, hookPath, configPath) {
  return [
    "acp",
    ...(configPath ? ["--config", configPath] : []),
    "--hook",
    hookPath,
    ...(request.effort ? [`--thinking=${request.effort}`] : []),
    ...(request.options?.advisor === "true" ? ["--advisor"] : []),
    ...(request.model ? [`--model=${request.model}`] : []),
  ];
}

export const dshPackageVersion = "0.2.1-rc.2";

export function dshACPArgs(...extra) {
  return ["--profile", "acp", ...extra];
}
