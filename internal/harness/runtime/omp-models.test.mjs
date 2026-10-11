import assert from "node:assert/strict";
import test from "node:test";
import { normalizeOMPDiscovery } from "./omp-models.mjs";

test("publishes the complete authenticated OMP catalog without fabricating routes", () => {
  const models = [
    {
      provider: "anthropic",
      id: "claude-sonnet-5",
      name: "Claude Sonnet 5",
      thinking: ["low", "high"],
    },
    {
      provider: "openai-codex",
      id: "gpt-5.6-luna",
      name: "GPT-5.6 Luna",
      thinking: ["low", "medium"],
    },
    { selector: "tailscale/deepseek", name: "DeepSeek", contextWindow: 1_048_576 },
    { selector: "openrouter/vendor/model:free", name: "Free", thinking: ["high"] },
  ];
  const normalized = normalizeOMPDiscovery(
    { models },
    { default: "anthropic/claude-sonnet-5:high" },
  );
  assert.deepEqual(normalized.models, models);
  assert.equal(normalized.defaultModel, "anthropic/claude-sonnet-5:high");
});

test("keeps native selectors containing colons and rejects unsupported default efforts", () => {
  const models = [{ selector: "openrouter/vendor/model:free", name: "Free", thinking: ["high"] }];
  assert.equal(
    normalizeOMPDiscovery({ models }, { default: "openrouter/vendor/model:free" }).defaultModel,
    "openrouter/vendor/model:free",
  );
  assert.equal(
    normalizeOMPDiscovery({ models }, { default: "openrouter/vendor/model:free:high" })
      .defaultModel,
    "openrouter/vendor/model:free:high",
  );
  assert.equal(
    normalizeOMPDiscovery({ models }, { default: "openrouter/vendor/model:free:max" }).defaultModel,
    undefined,
  );
});

test("retains the native catalog when role discovery is unavailable or references an unavailable model", () => {
  const models = [{ provider: "anthropic", id: "claude-sonnet-5", name: "Claude Sonnet 5" }];
  assert.deepEqual(normalizeOMPDiscovery({ models }), { models });
  assert.deepEqual(normalizeOMPDiscovery({ models }, { default: "unavailable/model" }), { models });
  assert.deepEqual(normalizeOMPDiscovery({ models: [] }), { models: [] });
  assert.throws(() => normalizeOMPDiscovery({}), /catalog is invalid/);
});
