import { spawn } from "node:child_process";
import readline from "node:readline";
import { HarnessCapabilityUnsupportedError } from "@ai-sdk/harness";

// Google Antigravity CLI (`agy`) as a HarnessV1 adapter.
//
// Every turn is one headless `agy --output-format stream-json` run: the prompt goes
// to stdin, the conversation id from the first run's `init` event is passed back
// with `--conversation` on later turns, so Antigravity keeps the history itself.
// Antigravity executes its own tools (write_file, run_command, …); they are
// surfaced as provider-executed tool calls. Host-defined tools, turn suspension,
// compaction and history reads are not available through the CLI.
//
// Observed stream (agy 1.4.8):
//   {"event":"init","conversation_id":…,"init":{"cwd":…,"tools":[…]}}
//   {"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"…"}}
//   {"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE|DONE|ERROR","step_type":"tool","tool_name":"write_file","tool_info":{"name":…,"parameters":{…},"error":{…}}}}
//   {"event":"result","result":{"status":"SUCCESS|ERROR","response":…,"error":…,"usage":{"input_tokens":…,"output_tokens":…,"thinking_tokens":…,"cache_read_tokens":…,"total_tokens":…}}}
const HARNESS_ID = "antigravity";

// agy prints a structured `AGY_ERROR: {...}` line on stderr when a run fails. Turn it into one
// sentence for the conversation; the raw diagnostics stay out of the user-visible text.
function describeFailure(resultError, stderrText) {
  let info;
  for (const line of stderrText.split("\n")) {
    const i = line.indexOf("AGY_ERROR:");
    if (i < 0) continue;
    try {
      info = JSON.parse(line.slice(i + "AGY_ERROR:".length).trim());
    } catch {
      // not JSON: ignore
    }
  }
  const text = (resultError || info?.short_error || "").trim();
  const resets = text.match(/Resets in ([0-9hms]+)/)?.[1];
  const status = info?.status || "";
  if (status === "RESOURCE_EXHAUSTED" || /quota reached/i.test(text)) {
    return `Antigravity has no quota left for this model${resets ? ` (resets in ${resets})` : ""}. Pick another model (e.g. Gemini 3.8 Flash) or try again later.`;
  }
  if (status === "UNAUTHENTICATED" || /authentication required|not logged in|credentials/i.test(text)) {
    return "Antigravity is not signed in on this machine: refresh the Antigravity credentials in the add-on options.";
  }
  if (!text) return "Antigravity failed without a message.";
  return `Antigravity: ${text.replace(/^error:\s*/i, "")}`;
}

// Thrown errors are logged with their stack by the host; keep the stack to the message only.
function turnError(message) {
  const error = new Error(message);
  error.stack = message;
  return error;
}

export function createAntigravity(settings = {}) {
  const command = settings.command || process.env.DIETER_ANTIGRAVITY_BIN || "agy";
  const effort = settings.effort || undefined;
  const unsupported = (message) => new HarnessCapabilityUnsupportedError({ harnessId: HARNESS_ID, message });

  return {
    specificationVersion: "harness-v1",
    harnessId: HARNESS_ID,
    builtinTools: {},
    supportsBuiltinToolApprovals: false,
    supportsBuiltinToolFiltering: false,

    async doStart(options) {
      if (options.continueFrom) throw unsupported("Antigravity cannot continue a suspended turn");
      const resume = options.resumeFrom;
      if (resume && resume.harnessId !== HARNESS_ID) {
        throw new Error(`lifecycle state belongs to harness '${resume.harnessId}', not '${HARNESS_ID}'`);
      }
      const state = {
        conversationId: resume?.data?.conversationId ?? null,
        instructionsApplied: resume?.data?.instructionsApplied === true,
      };
      const cwd = options.sessionWorkDir;
      const allowAll = (options.permissionMode ?? "allow-all") === "allow-all";
      let child;

      const lifecycleState = () => ({
        type: "resume-session",
        harnessId: HARNESS_ID,
        specificationVersion: "harness-v1",
        data: { conversationId: state.conversationId, instructionsApplied: state.instructionsApplied },
      });

      const session = {
        sessionId: options.sessionId,
        isResume: !!resume,

        async doPromptTurn(turn) {
          if (child) throw new Error("Antigravity: a turn is already running in this session");
          let text = promptToText(turn.prompt);
          if (!state.instructionsApplied && turn.instructions?.trim()) {
            // No system-prompt flag in headless mode: the instructions lead the first prompt of the conversation.
            text = `<instructions>\n${turn.instructions.trim()}\n</instructions>\n\n${text}`;
          }
          if (turn.tools?.length) {
            turn.emit({ type: "stream-start", warnings: [{ type: "unsupported", message: "Antigravity cannot call host-defined tools; they are not offered to the agent." }], modelId: turn.model });
          } else {
            turn.emit({ type: "stream-start", modelId: turn.model });
          }
          const args = ["--output-format", "stream-json"];
          if (turn.model) args.push("--model", turn.model);
          if (effort) args.push("--effort", effort);
          if (state.conversationId) args.push("--conversation", state.conversationId);
          if (allowAll) args.push("--dangerously-skip-permissions"); // Dieter's allow-all permission mode; headless agy denies tools otherwise
          const run = runTurn({ command, args, cwd, text, emit: turn.emit, abortSignal: turn.abortSignal, state });
          child = run.child;
          const done = run.done.finally(() => {
            child = undefined;
          });
          return {
            done,
            submitToolResult: async () => {
              throw unsupported("Antigravity does not accept host tool results");
            },
          };
        },
        async doContinueTurn() {
          throw unsupported("Antigravity cannot continue a suspended turn");
        },
        async doSuspendTurn() {
          throw unsupported("Antigravity cannot suspend a turn");
        },
        async doCompact() {
          throw unsupported("Antigravity has no manual compaction");
        },
        async doDetach() {
          return lifecycleState();
        },
        async doStop() {
          if (child) {
            child.kill("SIGTERM");
          }
          return lifecycleState();
        },
        async doDestroy() {
          if (child) child.kill("SIGKILL");
        },
      };
      return session;
    },
  };
}

function promptToText(prompt) {
  if (typeof prompt === "string") return prompt;
  const content = prompt?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (part?.type === "text") return part.text ?? "";
        if (part?.type === "file" || part?.type === "image") return `[attachment ${part.filename || part.mediaType || ""} omitted: Antigravity CLI takes text only]`;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return String(prompt ?? "");
}

function usageOf(u) {
  const n = (v) => (typeof v === "number" ? v : undefined);
  const input = n(u?.input_tokens);
  const cacheRead = n(u?.cache_read_tokens);
  const output = n(u?.output_tokens);
  const reasoning = n(u?.thinking_tokens);
  return {
    inputTokens: {
      total: input,
      noCache: input !== undefined && cacheRead !== undefined ? input - cacheRead : input,
      cacheRead,
      cacheWrite: undefined,
    },
    outputTokens: {
      total: output,
      text: output !== undefined && reasoning !== undefined ? output - reasoning : output,
      reasoning,
    },
    raw: u && typeof u === "object" ? u : undefined,
  };
}

function runTurn({ command, args, cwd, text, emit, abortSignal, state }) {
  const child = spawn(command, args, { cwd, env: process.env, stdio: ["pipe", "pipe", "pipe"] });
  const stderr = [];
  let result;
  let aborted = false;
  const openText = new Map(); // step_index -> part id
  const openReasoning = new Map();
  const toolsStarted = new Set();
  let stepUsage;

  const toolCallId = (su) => `agy-${su.step_index}-${(state.conversationId || "c").slice(0, 8)}`;
  const closeParts = () => {
    for (const id of openText.values()) emit({ type: "text-end", id });
    openText.clear();
    for (const id of openReasoning.values()) emit({ type: "reasoning-end", id });
    openReasoning.clear();
  };
  const onStep = (su) => {
    const idx = su.step_index ?? 0;
    switch (su.step_type) {
      case "agent_response": {
        if (typeof su.text_delta === "string" && su.text_delta.length) {
          let id = openText.get(idx);
          if (!id) {
            id = `text-${idx}`;
            openText.set(idx, id);
            emit({ type: "text-start", id });
          }
          emit({ type: "text-delta", id, delta: su.text_delta });
        }
        if (su.state === "DONE" || su.state === "ERROR") {
          const id = openText.get(idx);
          if (id) {
            emit({ type: "text-end", id });
            openText.delete(idx);
          }
          if (su.usage) stepUsage = su.usage;
        }
        return;
      }
      case "thinking":
      case "planner_response": {
        const delta = su.thinking_delta ?? su.text_delta;
        if (typeof delta === "string" && delta.length) {
          let id = openReasoning.get(idx);
          if (!id) {
            id = `reasoning-${idx}`;
            openReasoning.set(idx, id);
            emit({ type: "reasoning-start", id });
          }
          emit({ type: "reasoning-delta", id, delta });
        }
        if (su.state === "DONE" || su.state === "ERROR") {
          const id = openReasoning.get(idx);
          if (id) {
            emit({ type: "reasoning-end", id });
            openReasoning.delete(idx);
          }
        }
        return;
      }
      case "tool": {
        const name = su.tool_name || su.tool_info?.name || "tool";
        const id = toolCallId(su);
        const input = JSON.stringify(su.tool_info?.parameters ?? {});
        if (!toolsStarted.has(idx)) {
          toolsStarted.add(idx);
          emit({ type: "tool-call", toolCallId: id, toolName: name, input, providerExecuted: true, dynamic: true, nativeName: name });
        }
        if (su.state === "DONE" || su.state === "ERROR") {
          const isError = su.state === "ERROR";
          const info = su.tool_info ?? {};
          const result = isError
            ? { error: info.error ?? { message: "tool failed" } }
            : { output: info.output ?? info.result ?? "", durationSeconds: su.duration_seconds ?? null };
          emit({ type: "tool-result", toolCallId: id, toolName: name, result, isError, providerExecuted: true, dynamic: true });
        }
        return;
      }
      case "user_input":
        return;
      default:
        emit({ type: "raw", rawValue: su });
    }
  };

  const done = new Promise((resolve, reject) => {
    const fail = (error) => {
      try {
        closeParts();
        emit({ type: "error", error });
      } catch {
        // the host may already have torn the stream down
      }
      reject(error);
    };
    const onAbort = () => {
      aborted = true;
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 5_000).unref?.();
    };
    if (abortSignal?.aborted) onAbort();
    else abortSignal?.addEventListener("abort", onAbort, { once: true });

    child.on("error", (error) => fail(turnError(`cannot start ${command}: ${error.message}`)));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr.push(chunk);
      if (stderr.length > 200) stderr.shift();
    });
    const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => {
      if (!line.trim()) return;
      let ev;
      try {
        ev = JSON.parse(line);
      } catch {
        return;
      }
      try {
        if (ev.event === "init") {
          if (typeof ev.conversation_id === "string") state.conversationId = ev.conversation_id;
          state.instructionsApplied = true;
        } else if (ev.event === "step_update" && ev.step_update) {
          onStep(ev.step_update);
        } else if (ev.event === "result") {
          result = ev.result ?? {};
          if (typeof result.conversation_id === "string") state.conversationId = result.conversation_id;
        } else {
          emit({ type: "raw", rawValue: ev });
        }
      } catch (error) {
        fail(error);
      }
    });
    child.on("close", (code, signal) => {
      abortSignal?.removeEventListener?.("abort", onAbort);
      const stderrText = stderr.join("");
      if (aborted) return fail(turnError("agent turn interrupted"));
      closeParts();
      if (!result) {
        return fail(turnError(describeFailure(`${command} exited (${signal || code}) without a result`, stderrText)));
      }
      const usage = usageOf(result.usage ?? stepUsage);
      const ok = result.status === "SUCCESS";
      const finishReason = { unified: ok ? "stop" : "error", raw: String(result.status ?? "") };
      emit({ type: "finish-step", finishReason, usage });
      emit({ type: "finish", finishReason, totalUsage: usage });
      if (!ok) return reject(turnError(describeFailure(result.error || `turn failed (${result.status || "unknown"})`, stderrText)));
      resolve();
    });
    child.stdin.on("error", () => {});
    child.stdin.end(text.endsWith("\n") ? text : `${text}\n`);
  });
  return { child, done };
}
