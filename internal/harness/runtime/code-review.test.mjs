import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { tool } from "ai";
import { z } from "zod";
import {
  REVIEWER_MARKER,
  codeReviewInstructions,
  createCodeReviewBridge,
  createCodeReviewTool,
  mockCodeReviewTurn,
  mockReview,
} from "./code-review.mjs";

test("the bridge correlates the daemon's reply and allows one review at a time", async () => {
  const input = new EventEmitter();
  const sent = [];
  const bridge = createCodeReviewBridge(input, (value) => sent.push(value));
  const pending = bridge.call({ focus: "locks" });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].type, "code-review");
  assert.equal(sent[0].reviewCall.operation, "review");
  assert.deepEqual(sent[0].reviewCall.arguments, { focus: "locks" });
  await assert.rejects(bridge.call({}), /already running/);
  input.emit("line", "not json");
  input.emit(
    "line",
    JSON.stringify({
      type: "background-process-result",
      id: sent[0].reviewCall.id,
      result: "wrong",
    }),
  );
  input.emit(
    "line",
    JSON.stringify({ type: "code-review-result", id: "someone-else", result: "wrong" }),
  );
  input.emit(
    "line",
    JSON.stringify({ type: "code-review-result", id: sent[0].reviewCall.id, result: "2 findings" }),
  );
  assert.equal(await pending, "2 findings");

  const failing = bridge.call({});
  input.emit(
    "line",
    JSON.stringify({
      type: "code-review-result",
      id: sent[1].reviewCall.id,
      error: "reviewer unavailable",
    }),
  );
  await assert.rejects(failing, /reviewer unavailable/);

  const open = bridge.call({});
  input.emit("close");
  await assert.rejects(open, /disconnected/);
  await assert.rejects(bridge.call({}), /disconnected/);
});

test("the bridge times out and can be disposed", async () => {
  const input = new EventEmitter();
  const bridge = createCodeReviewBridge(input, () => {}, { timeoutMs: 20 });
  await assert.rejects(bridge.call({}), /timed out/);
  const disposed = bridge.call({});
  bridge.dispose();
  await assert.rejects(disposed, /disconnected/);
  assert.equal(input.listenerCount("line"), 0);
});

test("the tool forwards its focus and the SDK tool call ID, nothing else", async () => {
  const calls = [];
  const tools = createCodeReviewTool(
    {},
    async (args) => {
      calls.push(args);
      return "review text";
    },
    { tool, z },
  );
  const reviewTool = tools.request_code_review;
  assert.match(reviewTool.description, /separate model/);
  assert.equal(reviewTool.inputSchema.safeParse({ focus: "x".repeat(1001) }).success, false);
  assert.equal(reviewTool.inputSchema.safeParse({ cardId: "other" }).success, false);
  assert.equal(reviewTool.inputSchema.safeParse({}).success, true);
  assert.equal(
    await reviewTool.execute({ focus: "errors" }, { toolCallId: "call_1" }),
    "review text",
  );
  await reviewTool.execute({}, {});
  assert.deepEqual(calls, [{ focus: "errors", toolCallId: "call_1" }, {}]);
});

test("instructions name the tool, the CLI fallback and the round limit", () => {
  const text = codeReviewInstructions({
    reviewCommand: "/bin/dieter chat review c_1 --wait",
    codeReviewMaxRounds: 2,
  });
  assert.match(text, /^## Code review/);
  assert.match(text, /request_code_review/);
  assert.match(text, /run: \/bin\/dieter chat review c_1 --wait/);
  assert.match(text, /more than 2 reviews/);
  const plain = codeReviewInstructions({});
  assert.doesNotMatch(plain, /If the tool is not loaded/);
  assert.match(plain, /more than 3 reviews/);
  assert.match(codeReviewInstructions({ codeReviewMaxRounds: 99 }), /more than 3 reviews/);
});

test("the mock reviewer reports the first changed line of the first file", () => {
  const review = JSON.parse(
    mockReview("## File: lib/a.go\n@@ -3,4 +7,5 @@ func\n    7 +x\n").replace(
      /^```json\n|\n```$/g,
      "",
    ),
  );
  assert.equal(review.findings.length, 1);
  assert.equal(review.findings[0].file, "lib/a.go");
  assert.equal(review.findings[0].start_line, 7);
  const unified = JSON.parse(
    mockReview("diff --git a/x b/x\n+++ b/src/x.ts\n@@ -1 +2 @@\n").replace(
      /^```json\n|\n```$/g,
      "",
    ),
  );
  assert.equal(unified.findings[0].file, "src/x.ts");
  assert.equal(unified.findings[0].start_line, 2);
  const clean = JSON.parse(mockReview("mock-review-clean").replace(/^```json\n|\n```$/g, ""));
  assert.deepEqual(clean.findings, []);
});

test("the mock harness answers reviewer turns and calls the tool for mock-code-review", async () => {
  const sent = [];
  const send = (value) => sent.push(value);
  const reviewer = await mockCodeReviewTurn({
    request: { instructions: `${REVIEWER_MARKER}\nrubric` },
    runtimePrompt: "## File: a.go\n@@ -1 +1 @@\n",
    responseId: "msg_review",
    createdAt: "2026-11-27T00:00:00Z",
    send,
  });
  assert.equal(reviewer, true);
  const text = sent
    .map((frame) => frame.chunk)
    .filter((chunk) => chunk.type === "text-delta")
    .map((chunk) => chunk.delta)
    .join("");
  assert.match(text, /"file":"a.go"/);
  assert.equal(sent.at(-1).chunk.messageMetadata.totalUsage.inputTokens, 1200);

  sent.length = 0;
  const calls = [];
  const agent = await mockCodeReviewTurn({
    request: { instructions: "agent" },
    runtimePrompt: "please mock-code-review",
    responseId: "msg_agent",
    createdAt: "2026-11-27T00:00:00Z",
    send,
    bridge: { call: async (args) => (calls.push(args), "Code review rev_1: no findings") },
  });
  assert.equal(agent, true);
  assert.deepEqual(calls, [{ toolCallId: "tool-review" }]);
  const chunks = sent.map((frame) => frame.chunk);
  assert.equal(
    chunks.find((chunk) => chunk.type === "tool-input-available").toolName,
    "request_code_review",
  );
  assert.equal(
    chunks.find((chunk) => chunk.type === "tool-output-available").output,
    "Code review rev_1: no findings",
  );

  sent.length = 0;
  await mockCodeReviewTurn({
    request: {},
    runtimePrompt: "mock-code-review",
    responseId: "msg_fail",
    createdAt: "2026-11-27T00:00:00Z",
    send,
    bridge: { call: async () => Promise.reject(new Error("busy")) },
  });
  assert.equal(
    sent.map((frame) => frame.chunk).find((chunk) => chunk.type === "tool-output-error").errorText,
    "busy",
  );

  assert.equal(
    await mockCodeReviewTurn({ request: {}, runtimePrompt: "mock-code-review", send }),
    false,
  );
  assert.equal(
    await mockCodeReviewTurn({ request: {}, runtimePrompt: "hello", send, bridge: {} }),
    false,
  );
});
