import { randomUUID } from "node:crypto";
import { access, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Node built-ins only: the mock harness loads this module without the AI SDK.
// createCodeReviewTool receives the SDK's tool() and zod from the runner.

// The reviewer's own instructions start with this line (internal/engine/
// reviewer); the mock harness answers them with a deterministic review.
export const REVIEWER_MARKER = "You are Dieter's code reviewer.";

// A review takes minutes. The daemon bounds it (quick 10 min, thorough
// 20 min); the bridge waits a little longer so the daemon's answer, including
// its own timeout, always arrives first.
const DEFAULT_TIMEOUT_MS = 25 * 60_000;

// One request/reply channel over the worker's private stdio: the worker
// writes {type:"code-review", reviewCall:{id, operation, arguments}} and the
// daemon answers with {type:"code-review-result", id, result|error}.
export function createCodeReviewBridge(input, emit, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const pending = new Map();
  let closed = false;
  const failAll = () => {
    closed = true;
    for (const value of pending.values()) {
      clearTimeout(value.timer);
      value.reject(new Error("The code reviewer disconnected"));
    }
    pending.clear();
  };
  const receive = (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message?.type !== "code-review-result") return;
    const value = pending.get(message.id);
    if (!value) return;
    pending.delete(message.id);
    clearTimeout(value.timer);
    if (message.error) value.reject(new Error(message.error));
    else value.resolve(message.result);
  };
  input.on("line", receive);
  input.on("close", failAll);
  return {
    call(args) {
      if (closed) return Promise.reject(new Error("The code reviewer disconnected"));
      if (pending.size >= 1)
        return Promise.reject(
          new Error("A code review is already running; wait for its result before asking again"),
        );
      const id = randomUUID();
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error("The code review timed out"));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        try {
          emit({ type: "code-review", reviewCall: { id, operation: "review", arguments: args } });
        } catch (error) {
          pending.delete(id);
          clearTimeout(timer);
          reject(error);
        }
      });
    },
    dispose() {
      input.off("line", receive);
      input.off("close", failAll);
      failAll();
    },
  };
}

export function createCodeReviewTool(request, call, { tool, z }) {
  const focusText = z
    .string()
    .max(1000)
    .refine((value) => !value.includes("\0"), "No NUL characters");
  return {
    request_code_review: tool({
      description:
        "Ask Dieter's code reviewer, a separate model, to review every change in this conversation's workspace against its base (committed and uncommitted, untracked files included). It reads the code itself and returns findings: bugs, security and significant performance problems introduced by the change, each with file, lines, severity and a suggested fix. Takes one to several minutes; the user sees the findings in the conversation. Call it when a change is complete, before you report the task done.",
      inputSchema: z
        .object({
          focus: focusText
            .optional()
            .describe("Optional: what the reviewer should look at most closely"),
        })
        .strict(),
      // The SDK's tool call ID lets the daemon link the review to this call.
      execute: async (args, options) =>
        call({
          ...(args.focus ? { focus: args.focus } : {}),
          ...(options?.toolCallId ? { toolCallId: String(options.toolCallId).slice(0, 128) } : {}),
        }),
    }),
  };
}

// The reviewer instructions; request.reviewCommand is the CLI equivalent for
// harnesses that load host tools on demand.
export function codeReviewInstructions(request) {
  const fallback = request.reviewCommand
    ? ` If the tool is not loaded, run: ${request.reviewCommand} (it waits for the review and prints the findings).`
    : "";
  return `## Code review
This conversation has Dieter's code reviewer. When a change is complete, and before you report the task done, call request_code_review.${fallback} Fix the findings you agree with; for each one you reject, say why in your reply. After substantial fixes, request one more review. Do not request more than ${maxRounds(request)} reviews for one task, and do not ask for a review of unchanged work.`;
}

function maxRounds(request) {
  const value = Number(request.options?.codeReviewMaxRounds ?? request.codeReviewMaxRounds ?? 3);
  return Number.isInteger(value) && value >= 1 && value <= 10 ? value : 3;
}

// Deterministic behaviour of the mock harness, for daemon, client and device
// tests. Returns true when it answered the turn.
// The mock agent's change: with a workspace it first writes this file (once), so
// device flows review a real change and show a finding.
export const MOCK_CHANGE_FILE = "mock-review.txt";

export async function mockCodeReviewTurn({
  request,
  runtimePrompt,
  responseId,
  createdAt,
  send,
  bridge,
  workspace,
}) {
  if (String(request.instructions ?? "").startsWith(REVIEWER_MARKER)) {
    const text = mockReview(runtimePrompt);
    for (const chunk of [
      { type: "start", messageId: responseId, messageMetadata: { createdAt } },
      { type: "text-start", id: "review" },
      { type: "text-delta", id: "review", delta: text },
      { type: "text-end", id: "review" },
      {
        type: "finish",
        finishReason: "stop",
        messageMetadata: {
          createdAt,
          totalUsage: { inputTokens: 1200, outputTokens: 80, totalTokens: 1280 },
        },
      },
    ])
      send({ type: "chunk", chunk });
    return true;
  }
  if (!runtimePrompt.includes("mock-code-review") || !bridge) return false;
  if (workspace) {
    const file = join(workspace, MOCK_CHANGE_FILE);
    const exists = await access(file).then(
      () => true,
      () => false,
    );
    if (!exists) await writeFile(file, "A change for the mock code reviewer.\n");
  }
  send({
    type: "chunk",
    chunk: { type: "start", messageId: responseId, messageMetadata: { createdAt } },
  });
  send({
    type: "chunk",
    chunk: {
      type: "tool-input-available",
      toolCallId: "tool-review",
      toolName: "request_code_review",
      input: {},
    },
  });
  let output;
  try {
    output = await bridge.call({ toolCallId: "tool-review" });
    send({
      type: "chunk",
      chunk: { type: "tool-output-available", toolCallId: "tool-review", output },
    });
  } catch (error) {
    send({
      type: "chunk",
      chunk: {
        type: "tool-output-error",
        toolCallId: "tool-review",
        errorText: String(error?.message ?? error),
      },
    });
  }
  for (const chunk of [
    { type: "text-start", id: "text-review" },
    { type: "text-delta", id: "text-review", delta: "Mock agent read the code review." },
    { type: "text-end", id: "text-review" },
    { type: "finish", finishReason: "stop", messageMetadata: { createdAt } },
  ])
    send({ type: "chunk", chunk });
  return true;
}

// A review of the first changed file at its first added line, or none when
// the change contains "mock-review-clean".
export function mockReview(prompt) {
  if (prompt.includes("mock-review-clean")) {
    return '```json\n{"summary":"Mock review of a clean change.","findings":[],"security_concerns":"No"}\n```';
  }
  // The reviewer prompt names each file "## File: PATH" (internal/engine/
  // reviewer); a plain unified diff names it "+++ b/PATH".
  const file =
    (/^## File: (\S+)/m.exec(prompt) ?? /^\+\+\+ b\/(.+)$/m.exec(prompt))?.[1]?.trim() ??
    "README.md";
  const line = Number(/^@@ -\d+(?:,\d+)? \+(\d+)/m.exec(prompt)?.[1] ?? 1) || 1;
  const review = {
    summary: "Mock review of the change.",
    findings: [
      {
        file,
        start_line: line,
        end_line: line,
        severity: "medium",
        confidence: 7,
        title: "Mock finding",
        body: `The mock reviewer always reports the first changed line of ${file}.`,
        suggestion: "Nothing to fix; this is a test review.",
      },
    ],
    security_concerns: "No",
  };
  return "```json\n" + JSON.stringify(review) + "\n```";
}
