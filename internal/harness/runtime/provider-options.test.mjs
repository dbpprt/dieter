import assert from "node:assert/strict";
import test from "node:test";
import {
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
  assert.equal(dshPackageVersion, "0.1.2-rc.1");
  assert.deepEqual(dshACPArgs(), ["--profile", "acp"]);
  assert.deepEqual(dshACPArgs("--patch", "/runtime/discovery.patch.yml"), [
    "--profile",
    "acp",
    "--patch",
    "/runtime/discovery.patch.yml",
  ]);
});
