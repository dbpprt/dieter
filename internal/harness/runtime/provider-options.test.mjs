import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import {
  CODEX_CHANNEL_HOOK_MATCHER,
  codexChannelHooks,
  codexConfig,
  dshACPArgs,
  dshPackageVersion,
  ompACPArgs,
  ompConversationConfig,
  ompPinnedRoles,
  ompRuntimeConfig,
  ompStreamTimeoutSeconds,
  ompTurnFile,
} from "./provider-options.mjs";
test("maps the mutable Codex Fast mode option to an explicit service tier", () => {
  assert.deepEqual(codexConfig({ options: { fast_mode: "true" } }), {
    service_tier: "fast",
    features: { fast_mode: true },
  });
  assert.deepEqual(codexConfig({ options: { fast_mode: "false" } }), {
    service_tier: "default",
    features: { fast_mode: true },
  });
  assert.deepEqual(codexConfig({}), {
    service_tier: "default",
    features: { fast_mode: true },
  });
});

test("installs the agent channel PreToolUse hook as a trusted Codex session hook", () => {
  const command = "'/opt/dieter/bin/dieter' channel hook";
  const config = codexConfig({ channelHookCommand: ` ${command} ` });
  assert.equal(config.features.hooks, true);
  assert.equal(config.features.fast_mode, true);
  const handler = { type: "command", command, timeout: 10, async: false };
  assert.deepEqual(config.hooks.PreToolUse, [
    { matcher: CODEX_CHANNEL_HOOK_MATCHER, hooks: [handler] },
  ]);
  // The trusted hash is Codex's: sha256 of the canonical (sorted-key) group.
  const canonical = JSON.stringify({
    event_name: "pre_tool_use",
    hooks: [{ async: false, command, timeout: 10, type: "command" }],
    matcher: CODEX_CHANNEL_HOOK_MATCHER,
  });
  const expected = `sha256:${createHash("sha256").update(canonical).digest("hex")}`;
  assert.deepEqual(config.hooks.state, {
    "/<session-flags>/config.toml:pre_tool_use:0:0": { enabled: true, trusted_hash: expected },
  });
  assert.deepEqual(codexChannelHooks(command), config.hooks);
  for (const tool of ["apply_patch", "Bash", "Edit", "Write"])
    assert.match(tool, new RegExp(CODEX_CHANNEL_HOOK_MATCHER));
  assert.doesNotMatch("channel_check", new RegExp(CODEX_CHANNEL_HOOK_MATCHER));
  assert.equal(codexConfig({ channelHookCommand: "  " }).hooks, undefined);
});

test("launches OMP with arguments that never depend on the turn", () => {
  const launch = { hookPath: "/hook.mjs", configPath: "/config.yml" };
  assert.deepEqual(ompACPArgs(launch), ["acp", "--config", "/config.yml", "--hook", "/hook.mjs"]);
});

test("pins every OMP chat role to the implementation model and configures the advisor", () => {
  const config = ompConversationConfig({
    model: "anthropic/claude-opus-5-5",
    options: { advisor_model: "openai-codex/gpt-6-sol", advisor_effort: "low" },
  });
  assert.ok(config.startsWith(ompRuntimeConfig().trimEnd()));
  for (const role of ompPinnedRoles) {
    assert.match(config, new RegExp(`\\n  ${role}: "anthropic/claude-opus-5-5"\\n`));
  }
  assert.match(config, /\n  advisor: "openai-codex\/gpt-6-sol:low"\n/);
  assert.match(
    config,
    /\nadvisor:\n  enabled: true\n  reviewMode: agent-end\n  syncBacklog: strict\n$/,
  );
});

test("turns the OMP advisor off without an advisor model", () => {
  for (const options of [{}, { advisor_model: "off" }, { advisor_model: "" }]) {
    const config = ompConversationConfig({ model: "openai-codex/gpt-6-sol", options });
    assert.doesNotMatch(config, /  advisor: /);
    assert.match(config, /\nadvisor:\n  enabled: false\n$/);
  }
});

test("rejects OMP models Dieter does not manage", () => {
  assert.throws(
    () => ompConversationConfig({ model: "openrouter/openai/gpt-6-sol" }),
    /Claude or ChatGPT/,
  );
  assert.throws(
    () =>
      ompConversationConfig({
        model: "anthropic/claude-opus-5-5",
        options: { advisor_model: "tailscale/glm" },
      }),
    /advisor must be a Claude or ChatGPT model/,
  );
});

test("hands the turn's thinking level to the OMP hook", () => {
  assert.deepEqual(ompTurnFile({ effort: "xhigh" }), { thinking: "xhigh" });
  assert.deepEqual(ompTurnFile({ effort: "ultra" }), { thinking: "" });
  assert.deepEqual(ompTurnFile({}), { thinking: "" });
});

test("keeps OMP tools foreground with a thirty-minute provider watchdog", () => {
  assert.equal(ompStreamTimeoutSeconds, 1800);
  assert.equal(
    ompRuntimeConfig(),
    `providers:
  streamFirstEventTimeoutSeconds: 1800
  streamIdleTimeoutSeconds: 1800
async:
  enabled: false
bash:
  autoBackground:
    enabled: false
eval:
  autoBackground:
    enabled: false
`,
  );
});

test("builds a pinned DSH ACP launch without overriding DSH configuration", () => {
  assert.equal(dshPackageVersion, "0.2.1-rc.5");
  assert.deepEqual(dshACPArgs(), ["--profile", "acp"]);
  assert.deepEqual(dshACPArgs("--patch", "/runtime/discovery.patch.yml"), [
    "--profile",
    "acp",
    "--patch",
    "/runtime/discovery.patch.yml",
  ]);
});
