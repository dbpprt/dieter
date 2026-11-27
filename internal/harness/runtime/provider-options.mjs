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

// Every chat role OMP may route a request through. Dieter pins them all to
// the turn's implementation model, so no role resolves through OMP's own
// priority chains, which could reach the other provider's account (ADR 0007).
export const ompPinnedRoles = Object.freeze([
  "default",
  "smol",
  "slow",
  "vision",
  "plan",
  "commit",
  "tiny",
  "memory",
  "task",
  "widget",
]);

const ompSelector = /^(anthropic|openai-codex)\/[A-Za-z0-9._-]+$/;
const ompThinking = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);

function requireOMPSelector(value, what) {
  if (typeof value !== "string" || !ompSelector.test(value)) {
    throw new Error(
      `Oh My Pi ${what} must be a Claude or ChatGPT model, not ${JSON.stringify(value)}`,
    );
  }
  return value;
}

// The per-conversation settings overlay: Dieter's runtime settings, every
// chat role pinned to the implementation model, and the advisor. A reviewing
// advisor holds the main agent until its notes are in (syncBacklog strict),
// because notes that arrive after the ACP prompt ends would be lost.
export function ompConversationConfig(request) {
  const model = requireOMPSelector(request.model, "model");
  const advisorModel = request.options?.advisor_model;
  const advisorOn =
    typeof advisorModel === "string" && advisorModel !== "" && advisorModel !== "off";
  const lines = [ompRuntimeConfig().trimEnd(), "modelRoles:"];
  for (const role of ompPinnedRoles) lines.push(`  ${role}: ${JSON.stringify(model)}`);
  if (advisorOn) {
    const effort = request.options?.advisor_effort;
    const level = ompThinking.has(effort) ? `:${effort}` : "";
    lines.push(`  advisor: ${JSON.stringify(requireOMPSelector(advisorModel, "advisor") + level)}`);
    lines.push("advisor:", "  enabled: true", "  reviewMode: agent-end", "  syncBacklog: strict");
  } else {
    lines.push("advisor:", "  enabled: false");
  }
  return `${lines.join("\n")}\n`;
}

// What the capabilities hook applies at the start of each prompt. The model
// itself reaches OMP through ACP's model config option (modelMapping).
export function ompTurnFile(request) {
  return { thinking: ompThinking.has(request.effort) ? request.effort : "" };
}

// Launch arguments never depend on the request: they are part of the ACP
// implementation identity a conversation's next turn must match to resume.
export function ompACPArgs({ hookPath, configPath }) {
  return ["acp", "--config", configPath, "--hook", hookPath];
}

export const dshPackageVersion = "0.2.1-rc.5";

export function dshACPArgs(...extra) {
  return ["--profile", "acp", ...extra];
}
