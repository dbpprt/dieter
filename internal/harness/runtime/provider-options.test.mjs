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
  ompRuntimeConfig,
  ompStreamTimeoutSeconds,
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

test("adds the OMP advisor flag only when the provider option is enabled", () => {
  assert.deepEqual(
    ompACPArgs({ effort: "high", options: { advisor: "true" } }, "/hook.mjs", "/config.yml"),
    ["acp", "--config", "/config.yml", "--hook", "/hook.mjs", "--thinking=high", "--advisor"],
  );
  assert.deepEqual(ompACPArgs({ options: { advisor: "false" } }, "/hook.mjs"), [
    "acp",
    "--hook",
    "/hook.mjs",
  ]);
});
test("launches OMP bridges with the selected model", () => {
  const request = { model: "openrouter/openai/gpt-6-sol", effort: "max" };
  assert.deepEqual(ompACPArgs(request, "/hook.mjs", "/config.yml"), [
    "acp",
    "--config",
    "/config.yml",
    "--hook",
    "/hook.mjs",
    "--thinking=max",
    "--model=openrouter/openai/gpt-6-sol",
  ]);
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
  assert.equal(dshPackageVersion, "0.2.1-rc.2");
  assert.deepEqual(dshACPArgs(), ["--profile", "acp"]);
  assert.deepEqual(dshACPArgs("--patch", "/runtime/discovery.patch.yml"), [
    "--profile",
    "acp",
    "--patch",
    "/runtime/discovery.patch.yml",
  ]);
});
