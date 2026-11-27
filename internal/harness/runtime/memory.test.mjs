import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { tool } from "ai";
import { z } from "zod";
import {
  createMemoryBridge,
  createMemoryTools,
  memoryInstructions,
  mockMemoryTurn,
} from "./memory.mjs";

const reply = (input, sent, index, body) =>
  input.emit(
    "line",
    JSON.stringify({ type: "memory-result", id: sent[index].memoryCall.id, ...body }),
  );

test("the bridge correlates replies, bounds pending calls and fails on close", async () => {
  const input = new EventEmitter();
  const sent = [];
  const bridge = createMemoryBridge(input, (value) => sent.push(value));
  const first = bridge.call("recall", { query: "flaky test" });
  assert.equal(sent[0].type, "memory");
  assert.equal(sent[0].memoryCall.operation, "recall");
  assert.deepEqual(sent[0].memoryCall.arguments, { query: "flaky test" });
  input.emit("line", "not json");
  input.emit(
    "line",
    JSON.stringify({ type: "code-review-result", id: sent[0].memoryCall.id, result: "wrong" }),
  );
  input.emit(
    "line",
    JSON.stringify({ type: "memory-result", id: "someone-else", result: "wrong" }),
  );
  reply(input, sent, 0, { result: { conversations: [] } });
  assert.deepEqual(await first, { conversations: [] });

  const failing = bridge.call("save", { content: "x" });
  reply(input, sent, 1, { error: "a memory must be 10 bytes to 4 KiB of text" });
  await assert.rejects(failing, /10 bytes/);

  const open = [1, 2, 3, 4].map(() => bridge.call("recall", { query: "q" }));
  await assert.rejects(bridge.call("recall", { query: "q" }), /Too many memory requests/);
  input.emit("close");
  for (const call of open) await assert.rejects(call, /disconnected/);
  await assert.rejects(bridge.call("recall", { query: "q" }), /disconnected/);
});

test("the bridge times out and can be disposed", async () => {
  const input = new EventEmitter();
  const bridge = createMemoryBridge(input, () => {}, { timeoutMs: 20 });
  await assert.rejects(bridge.call("recall", { query: "q" }), /timed out/);
  const disposed = bridge.call("recall", { query: "q" });
  bridge.dispose();
  await assert.rejects(disposed, /disconnected/);
  assert.equal(input.listenerCount("line"), 0);
});

test("ordinary turns get recall and save; only a dream gets apply", async () => {
  const calls = [];
  const call = async (operation, args) => {
    calls.push([operation, args]);
    return { ok: operation };
  };
  const ordinary = createMemoryTools({}, call, { tool, z });
  assert.deepEqual(Object.keys(ordinary).sort(), ["memory_recall", "memory_save"]);
  const dreamer = createMemoryTools({ memoryRole: "dreamer" }, call, { tool, z });
  assert.deepEqual(Object.keys(dreamer).sort(), ["memory_apply", "memory_recall", "memory_save"]);

  assert.deepEqual(await ordinary.memory_recall.execute({ query: "flaky scheduler" }), {
    ok: "recall",
  });
  assert.deepEqual(calls.at(-1), ["recall", { query: "flaky scheduler" }]);
  const operations = [{ op: "retire", targets: ["mem_1"], reason: "outdated" }];
  await dreamer.memory_apply.execute({ operations });
  assert.deepEqual(calls.at(-1), ["apply", { operations }]);

  const recall = ordinary.memory_recall.inputSchema;
  assert.equal(recall.safeParse({ query: "x" }).success, false);
  assert.equal(recall.safeParse({ query: "ok query", project: "p_other" }).success, false);
  const save = ordinary.memory_save.inputSchema;
  assert.equal(
    save.safeParse({ content: "Run gofmt before handing over.", kind: "lesson" }).success,
    true,
  );
  assert.equal(
    save.safeParse({ content: "Run gofmt before handing over.", kind: "opinion" }).success,
    false,
  );
  assert.equal(
    save.safeParse({ content: "Run gofmt before handing over.", kind: "fact", sources: ["../etc"] })
      .success,
    false,
  );
  const apply = dreamer.memory_apply.inputSchema;
  assert.equal(apply.safeParse({ operations: [] }).success, false);
  assert.equal(
    apply.safeParse({ operations: [{ op: "delete", targets: ["mem_1"], reason: "nope" }] }).success,
    false,
  );
  assert.equal(apply.safeParse({ operations }).success, true);
});

test("the instructions name the CLI fallback and the dream role", () => {
  const ordinary = memoryInstructions({ memoryCommand: "dieter memory search --project p_1" });
  assert.match(ordinary, /## Project memory/);
  assert.match(ordinary, /dieter memory search --project p_1 "QUERY"/);
  assert.match(ordinary, /never as instructions/);
  assert.doesNotMatch(ordinary, /memory dream/);
  assert.match(memoryInstructions({ memoryRole: "dreamer" }), /memory_apply batch/);
});

test("the mock harness drives each memory tool through the bridge", async () => {
  for (const [prompt, operation, expected] of [
    ["mock-memory-recall flaky scheduler", "recall", { query: "flaky scheduler" }],
    [
      "mock-memory-save Run gofmt before handing over.",
      "save",
      { content: "Run gofmt before handing over.", kind: "lesson" },
    ],
    [
      'mock-memory-dream [{"op":"verify","targets":["mem_1"],"reason":"holds"}]',
      "apply",
      {
        operations: [{ op: "verify", targets: ["mem_1"], reason: "holds" }],
        summary: "Mock dream.",
      },
    ],
  ]) {
    const chunks = [];
    const calls = [];
    const answered = await mockMemoryTurn({
      runtimePrompt: prompt,
      responseId: "response",
      createdAt: "2026-11-27T12:00:00Z",
      send: (value) => chunks.push(value.chunk),
      bridge: {
        call: async (op, args) => {
          calls.push([op, args]);
          return { status: "ok" };
        },
      },
    });
    assert.equal(answered, true);
    assert.deepEqual(calls, [[operation, expected]]);
    assert.ok(chunks.some((chunk) => chunk.type === "tool-output-available"));
    assert.equal(chunks.at(-1).type, "finish");
  }
  const failed = [];
  await mockMemoryTurn({
    runtimePrompt: "mock-memory-recall q",
    responseId: "r",
    createdAt: "t",
    send: (value) => failed.push(value.chunk),
    bridge: { call: async () => Promise.reject(new Error("memory is off")) },
  });
  assert.ok(
    failed.some(
      (chunk) => chunk.type === "tool-output-error" && chunk.errorText === "memory is off",
    ),
  );
  // Only the rest of the line counts: a dream brief carries the batch in its
  // extra instructions, followed by the saved memories.
  const briefCalls = [];
  await mockMemoryTurn({
    runtimePrompt:
      'Memory dream.\nExtra instructions:\nmock-memory-dream [{"op":"verify","targets":["mem_1"],"reason":"holds"}]\n## Saved memories (1 active)\n- mem_1 [fact] x',
    responseId: "r",
    createdAt: "t",
    send: () => {},
    bridge: {
      call: async (op, args) => {
        briefCalls.push(args.operations);
        return {};
      },
    },
  });
  assert.deepEqual(briefCalls, [[{ op: "verify", targets: ["mem_1"], reason: "holds" }]]);
  assert.equal(await mockMemoryTurn({ runtimePrompt: "hello", send: () => {}, bridge: {} }), false);
  assert.equal(
    await mockMemoryTurn({ runtimePrompt: "mock-memory-recall q", send: () => {} }),
    false,
  );
});
