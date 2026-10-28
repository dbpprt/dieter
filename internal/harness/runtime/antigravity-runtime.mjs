import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import { HarnessCapabilityUnsupportedError } from "@ai-sdk/harness";

// Google Antigravity CLI (`agy`) as a HarnessV1 adapter.
//
// Every turn is one headless `agy --output-format stream-json` run: the prompt goes
// to stdin, the conversation id from the first run's `init` event is passed back
// with `--conversation` on later turns, so Antigravity keeps the history itself.
// Antigravity executes its own tools (write_file, run_command, …); they are
// surfaced as provider-executed tool calls.
//
// Host-defined tools (present_content, the background process tools) reach agy as an MCP
// server: the adapter serves the running turn's tools over a private HTTP endpoint on
// 127.0.0.1 and agy launches the stdio proxy antigravity-host-tools.mjs, which forwards
// tools/list and tools/call to that endpoint through DIETER_AGY_TOOLS_URL and
// DIETER_AGY_TOOLS_TOKEN in agy's environment. The proxy is registered in agy's own config once
// per worker process (`agy mcp add dieter <node> <proxy>`, an add-or-update of that one entry in
// ~/.gemini/config/mcp_config.json). A call becomes a `tool-call` event, the host executes it
// and `submitToolResult` answers agy.
//
// Turn suspension, history reads, mid-turn messages and image input are not available
// through the CLI (images reach the agent as files, see local-attachments.mjs).
//
// Observed stream (agy 1.4.8):
//   {"event":"init","conversation_id":…,"init":{"cwd":…,"model":…,"tools":[…],"permission_mode":…}}
//   {"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"…"}}
//   {"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","usage":{…}}}
//   {"event":"step_update","step_update":{"step_index":2,"state":"ACTIVE|DONE|ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":…,"parameters":{…},"output":…,"error":{…}}}}
//   {"event":"step_update","step_update":{"step_index":3,"state":"DONE","step_type":"system_message"|"checkpoint"|"user_input"}}
//   {"event":"result","result":{"status":"SUCCESS|ERROR","response":…,"error":…,"usage":{"input_tokens":…,"output_tokens":…,"thinking_tokens":…,"cache_read_tokens":…,"total_tokens":…}}}
// A step's usage is that model request (input_tokens = the context it saw); the result's usage is
// the sum over the turn. Thinking is not streamed, only counted (thinking_tokens).
// MCP calls appear as the tool "call_mcp_tool" with parameters {ServerName, ToolName, Arguments}.
const HARNESS_ID = "antigravity";
// Name of the MCP server through which agy reaches the host tools (antigravity-host-tools.mjs).
export const HOST_TOOLS_SERVER = "dieter";
const HOST_TOOLS_PROXY = fileURLToPath(new URL("./antigravity-host-tools.mjs", import.meta.url));
const CONVERSATION_LOST = Symbol("conversation-lost");
const hostSchemaPath = new RegExp(`/antigravity-cli/mcp/${HOST_TOOLS_SERVER}/[^/]+\\.json$`);

// `agy mcp add` of the proxy, once per process; resolves with a problem description when it failed.
let hostToolsRegistration;
function registerHostTools(command) {
  hostToolsRegistration ??= new Promise((resolve) => {
    const child = spawn(
      command,
      ["mcp", "add", HOST_TOOLS_SERVER, process.execPath, HOST_TOOLS_PROXY],
      { env: process.env, stdio: ["ignore", "ignore", "pipe"] },
    );
    const stderr = [];
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", (error) => resolve(`cannot run ${command} mcp add: ${error.message}`));
    child.on("close", (code, signal) =>
      resolve(
        code === 0
          ? undefined
          : `${command} mcp add exited (${signal || code}): ${stderr.join("").trim()}`,
      ),
    );
  });
  return hostToolsRegistration;
}

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
  if (
    status === "UNAUTHENTICATED" ||
    /authentication required|not logged in|credentials/i.test(text)
  ) {
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
  const command = settings.command || "agy"; // `agy` on PATH of the execution machine, like the other CLIs
  const effort = settings.effort || undefined;
  const unsupported = (message) =>
    new HarnessCapabilityUnsupportedError({ harnessId: HARNESS_ID, message });

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
        throw new Error(
          `lifecycle state belongs to harness '${resume.harnessId}', not '${HARNESS_ID}'`,
        );
      }
      const state = {
        conversationId: resume?.data?.conversationId ?? null,
        instructionsApplied: resume?.data?.instructionsApplied === true,
      };
      const cwd = options.sessionWorkDir;
      // Only Dieter's explicit allow-all mode skips agy's permission prompts; anything else keeps them
      // (headless agy then denies tool use, which is the safe side).
      const allowAll = options.permissionMode === "allow-all";
      const current = { child: undefined }; // the agy process of the running turn (or compaction)
      let hostTools; // created with the first turn that offers host tools

      const lifecycleState = () => ({
        type: "resume-session",
        harnessId: HARNESS_ID,
        specificationVersion: "harness-v1",
        data: {
          conversationId: state.conversationId,
          instructionsApplied: state.instructionsApplied,
        },
      });
      const closeHostTools = () => {
        hostTools?.close();
        hostTools = undefined;
      };

      const session = {
        sessionId: options.sessionId,
        isResume: !!resume,

        async doPromptTurn(turn) {
          if (current.child)
            throw new Error("Antigravity: a turn is already running in this session");
          const prompt = promptToText(turn.prompt);
          const withInstructions = (text) =>
            turn.instructions?.trim()
              ? `<instructions>\n${turn.instructions.trim()}\n</instructions>\n\n${text}`
              : text;
          let tools = turn.tools?.length ? [...turn.tools] : [];
          const warnings = [];
          if (tools.length) {
            const problem = await registerHostTools(command);
            if (problem) {
              warnings.push({
                type: "unsupported",
                message: `Antigravity cannot reach the host tools (${problem}); they are not offered to the agent.`,
              });
              tools = [];
            }
          }
          turn.emit({
            type: "stream-start",
            modelId: turn.model,
            ...(warnings.length ? { warnings } : {}),
          });
          const env = { ...process.env };
          let hostTurn;
          if (tools.length) {
            hostTools ??= createHostToolServer();
            const url = await hostTools.start();
            env.DIETER_AGY_TOOLS_URL = url;
            env.DIETER_AGY_TOOLS_TOKEN = hostTools.token;
            hostTurn = createHostToolTurn({
              tools,
              emit: turn.emit,
              conversationId: () => state.conversationId,
            });
            hostTools.setTurn(hostTurn);
          } else {
            hostTools?.setTurn(undefined);
            delete env.DIETER_AGY_TOOLS_URL;
            delete env.DIETER_AGY_TOOLS_TOKEN;
          }
          const run = (resumeConversation) => {
            const args = ["--output-format", "stream-json"];
            if (turn.model) args.push("--model", turn.model);
            // agy model ids carry their reasoning level (gemini-3.8-flash-high, claude-opus-5-5-low, …) and agy
            // rejects every --effort that differs from it; such a model is run at its own level.
            if (effort && !/-(low|medium|high)$/.test(turn.model || ""))
              args.push("--effort", effort);
            if (resumeConversation) args.push("--conversation", resumeConversation);
            if (allowAll) args.push("--dangerously-skip-permissions"); // Dieter's allow-all permission mode; headless agy denies tools otherwise
            // No system-prompt flag in headless mode: the instructions lead the first prompt of the conversation.
            const text =
              state.instructionsApplied && resumeConversation ? prompt : withInstructions(prompt);
            return runTurn({
              command,
              args,
              cwd,
              env,
              text,
              emit: turn.emit,
              abortSignal: turn.abortSignal,
              state,
              current,
              hostTurn,
              expectConversation: resumeConversation,
            });
          };
          const done = (async () => {
            try {
              const outcome = await run(state.conversationId);
              if (outcome !== CONVERSATION_LOST) return;
              // agy no longer has the stored conversation (it warned and would start a fresh one without
              // Dieter's instructions): say so and start the fresh one with the instructions.
              state.conversationId = null;
              state.instructionsApplied = false;
              const id = "antigravity-conversation-lost";
              turn.emit({ type: "text-start", id });
              turn.emit({
                type: "text-delta",
                id,
                delta:
                  "_Antigravity no longer has the stored conversation of this chat; a new one starts here without the earlier history._\n\n",
              });
              turn.emit({ type: "text-end", id });
              await run(null);
            } finally {
              current.child = undefined;
              hostTurn?.close();
              hostTools?.setTurn(undefined);
            }
          })();
          return {
            done,
            submitToolResult: async (submission) => {
              if (!hostTurn)
                throw unsupported("Antigravity: no host tool call is waiting for a result");
              hostTurn.submitResult(submission);
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
          // agy's own /compact: a headless run of the slash command on the stored conversation.
          if (current.child) throw new Error("Antigravity: cannot compact while a turn is running");
          if (!state.conversationId) return; // nothing stored yet
          await runCompaction({ command, cwd, conversationId: state.conversationId, current });
        },
        async doDetach() {
          return lifecycleState();
        },
        async doStop() {
          if (current.child) {
            current.child.kill("SIGTERM");
          }
          closeHostTools();
          return lifecycleState();
        },
        async doDestroy() {
          if (current.child) current.child.kill("SIGKILL");
          closeHostTools();
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
        if (part?.type === "file" || part?.type === "image")
          return `[attachment ${part.filename || part.mediaType || ""} omitted: Antigravity CLI takes text only]`;
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

// The model-facing text of a host tool result (the harness passes the typed tool output when it
// has one, else the raw execution result).
function modelFacingResult(submission) {
  const typed = submission.toolResult?.output;
  let text;
  let isError = submission.isError === true;
  if (typed && typeof typed === "object" && typeof typed.type === "string") {
    isError ||= typed.type.startsWith("error-");
    if (typed.type === "text" || typed.type === "error-text") text = String(typed.value ?? "");
    else if (typed.type === "content" && Array.isArray(typed.value))
      text = typed.value
        .map((p) => (p?.type === "text" ? p.text : `[${p?.type || "part"}]`))
        .join("\n");
    else text = JSON.stringify(typed.value ?? null);
  } else {
    const value = submission.output;
    text = typeof value === "string" ? value : JSON.stringify(value ?? null);
  }
  return { text, isError };
}

// The host tools of one turn: `call` is what the MCP proxy's tools/call turns into, `submitResult`
// what the host answers with. Each call is one `tool-call` event, answered by the echoed `tool-result`.
function createHostToolTurn({ tools, emit, conversationId }) {
  const pending = new Map(); // toolCallId -> { name, resolve }
  let seq = 0;
  let closed = false;
  const nonce = randomBytes(4).toString("hex");
  return {
    tools,
    call(name, args) {
      const spec = tools.find((t) => t.name === name);
      if (!spec) return Promise.resolve({ text: `unknown tool ${name}`, isError: true });
      if (closed) return Promise.resolve({ text: "the turn has ended", isError: true });
      const toolCallId = `agy-host-${nonce}-${++seq}-${(conversationId() || "c").slice(0, 8)}`;
      return new Promise((resolve) => {
        pending.set(toolCallId, { name, resolve });
        emit({
          type: "tool-call",
          toolCallId,
          toolName: name,
          input: JSON.stringify(args && typeof args === "object" ? args : {}),
          providerExecuted: false,
        });
      });
    },
    submitResult(submission) {
      const entry = pending.get(submission.toolCallId);
      if (!entry) throw new Error(`Antigravity: unknown host tool call '${submission.toolCallId}'`);
      pending.delete(submission.toolCallId);
      const { text, isError } = modelFacingResult(submission);
      entry.resolve({ text, isError });
      emit({
        type: "tool-result",
        toolCallId: submission.toolCallId,
        toolName: entry.name,
        result: submission.output,
        isError: submission.isError === true,
        providerExecuted: false,
      });
    },
    get pendingCount() {
      return pending.size;
    },
    close() {
      closed = true;
      for (const entry of pending.values())
        entry.resolve({ text: "the turn has ended", isError: true });
      pending.clear();
    },
  };
}

// Private HTTP endpoint for antigravity-host-tools.mjs (the stdio MCP proxy agy launches):
//   GET  /tools            -> {"tools":[{name, description, inputSchema}]}
//   POST /call {name, arguments} -> {"output": "<model-facing text>", "isError": bool}
// Bearer token in the Authorization header; one server per harness session, 127.0.0.1 only.
export function createHostToolServer() {
  const token = randomBytes(24).toString("hex");
  let turn;
  let url;
  let starting;
  const server = createServer((req, res) => {
    const reply = (status, body) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.headers.authorization !== `Bearer ${token}`)
      return reply(401, { error: "unauthorized" });
    if (req.method === "GET" && req.url === "/tools") {
      return reply(200, {
        tools: (turn?.tools ?? []).map((t) => ({
          name: t.name,
          description: t.description ?? "",
          inputSchema: t.inputSchema ?? { type: "object" },
        })),
      });
    }
    if (req.method === "POST" && req.url === "/call") {
      const chunks = [];
      let size = 0;
      req.on("data", (c) => {
        size += c.length;
        if (size > 4 * 1024 * 1024) req.destroy();
        else chunks.push(c);
      });
      req.on("end", async () => {
        let body;
        try {
          body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        } catch {
          return reply(400, { error: "invalid JSON" });
        }
        if (!turn) return reply(409, { error: "no turn is running" });
        if (typeof body?.name !== "string") return reply(400, { error: "name missing" });
        try {
          const { text, isError } = await turn.call(body.name, body.arguments);
          reply(200, { output: text, isError });
        } catch (error) {
          reply(500, { error: String(error?.message || error) });
        }
      });
      return;
    }
    reply(404, { error: "not found" });
  });
  server.unref?.();
  return {
    token,
    start() {
      if (url) return Promise.resolve(url);
      starting ??= new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
          url = `http://127.0.0.1:${server.address().port}/`;
          resolve(url);
        });
      });
      return starting;
    },
    setTurn(next) {
      turn = next;
    },
    close() {
      turn = undefined;
      server.close();
      server.closeAllConnections?.();
    },
  };
}

function runTurn({
  command,
  args,
  cwd,
  env,
  text,
  emit,
  abortSignal,
  state,
  current,
  hostTurn,
  expectConversation,
}) {
  const child = spawn(command, args, { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
  current.child = child;
  const stderr = [];
  let result;
  let aborted = false;
  let conversationLost = false;
  let emitted = false; // any model output shown to the user
  const openText = new Map(); // step_index -> part id
  const openReasoning = new Map();
  const toolsStarted = new Set();
  const skippedSteps = new Set(); // agy's call_mcp_tool steps for Dieter's own host tools (shown by the host path)
  let pendingStep; // usage of the latest finished model request, closed with the next one or at the end

  const toolCallId = (su) => `agy-${su.step_index}-${(state.conversationId || "c").slice(0, 8)}`;
  const closeParts = () => {
    for (const id of openText.values()) emit({ type: "text-end", id });
    openText.clear();
    for (const id of openReasoning.values()) emit({ type: "reasoning-end", id });
    openReasoning.clear();
  };
  const flushStep = (finishReason) => {
    if (!pendingStep) return;
    emit({ type: "finish-step", finishReason, usage: usageOf(pendingStep) });
    pendingStep = undefined;
  };
  const onStep = (su) => {
    const idx = su.step_index ?? 0;
    switch (su.step_type) {
      case "agent_response": {
        if (typeof su.text_delta === "string" && su.text_delta.length) {
          let id = openText.get(idx);
          if (!id) {
            // a new model request: the previous one went on to call tools
            flushStep({ unified: "tool-calls", raw: "tool-calls" });
            id = `text-${idx}`;
            openText.set(idx, id);
            emit({ type: "text-start", id });
          }
          emitted = true;
          emit({ type: "text-delta", id, delta: su.text_delta });
        }
        if (su.state === "DONE" || su.state === "ERROR") {
          const id = openText.get(idx);
          if (id) {
            emit({ type: "text-end", id });
            openText.delete(idx);
          } else flushStep({ unified: "tool-calls", raw: "tool-calls" });
          if (su.usage) pendingStep = su.usage;
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
        const params = su.tool_info?.parameters;
        // agy loads an MCP tool's schema on demand by reading ~/.gemini/antigravity-cli/mcp/<server>/<tool>.json
        if (
          skippedSteps.has(idx) ||
          (hostTurn && name === "call_mcp_tool" && params?.ServerName === HOST_TOOLS_SERVER) ||
          (hostTurn && hostSchemaPath.test(String(params?.Path ?? params?.AbsolutePath ?? "")))
        ) {
          skippedSteps.add(idx);
          return;
        }
        const id = toolCallId(su);
        const input = JSON.stringify(params ?? {});
        if (!toolsStarted.has(idx)) {
          toolsStarted.add(idx);
          emitted = true;
          emit({
            type: "tool-call",
            toolCallId: id,
            toolName: name,
            input,
            providerExecuted: true,
            dynamic: true,
            nativeName: name,
          });
        }
        if (su.state === "DONE" || su.state === "ERROR") {
          const isError = su.state === "ERROR";
          const info = su.tool_info ?? {};
          const result = isError
            ? { error: info.error ?? { message: "tool failed" } }
            : {
                output: info.output ?? info.result ?? "",
                durationSeconds: su.duration_seconds ?? null,
              };
          emit({
            type: "tool-result",
            toolCallId: id,
            toolName: name,
            result,
            isError,
            providerExecuted: true,
            dynamic: true,
          });
        }
        return;
      }
      case "user_input":
      case "system_message":
      case "checkpoint":
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
    readline.createInterface({ input: child.stderr, crlfDelay: Infinity }).on("line", (line) => {
      stderr.push(`${line}\n`);
      if (stderr.length > 200) stderr.shift();
      // `warning: conversation "<id>" not found`: agy goes on in a fresh conversation. Before any
      // output, stop it and let the turn restart with Dieter's instructions; later, only re-apply them next time.
      const lost = line.match(/conversation "([^"]+)" not found/);
      if (lost && expectConversation && lost[1] === expectConversation) {
        if (emitted) state.instructionsApplied = false;
        else {
          conversationLost = true;
          child.kill("SIGTERM");
        }
      }
    });
    const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => {
      if (!line.trim() || conversationLost) return;
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
          if (typeof result.conversation_id === "string")
            state.conversationId = result.conversation_id;
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
      if (conversationLost) {
        state.conversationId = null;
        return resolve(CONVERSATION_LOST);
      }
      closeParts();
      if (!result) {
        return fail(
          turnError(
            describeFailure(`${command} exited (${signal || code}) without a result`, stderrText),
          ),
        );
      }
      const ok = result.status === "SUCCESS";
      const finishReason = { unified: ok ? "stop" : "error", raw: String(result.status ?? "") };
      flushStep(finishReason);
      emit({ type: "finish", finishReason, totalUsage: usageOf(result.usage) });
      if (!ok)
        return reject(
          turnError(
            describeFailure(
              result.error || `turn failed (${result.status || "unknown"})`,
              stderrText,
            ),
          ),
        );
      resolve();
    });
    child.stdin.on("error", () => {});
    child.stdin.end(text.endsWith("\n") ? text : `${text}\n`);
  });
  return done;
}

// `/compact` as a headless run on the stored conversation; resolves when agy reports success.
function runCompaction({ command, cwd, conversationId, current }) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      command,
      ["--output-format", "stream-json", "--conversation", conversationId],
      { cwd, env: process.env, stdio: ["pipe", "pipe", "pipe"] },
    );
    current.child = child;
    const stderr = [];
    let result;
    child.on("error", (error) => reject(turnError(`cannot start ${command}: ${error.message}`)));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr.push(chunk);
      if (stderr.length > 200) stderr.shift();
    });
    readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", (line) => {
      try {
        const ev = JSON.parse(line);
        if (ev.event === "result") result = ev.result ?? {};
      } catch {
        // not JSON: ignore
      }
    });
    child.on("close", (code, signal) => {
      current.child = undefined;
      const stderrText = stderr.join("");
      if (!result)
        return reject(
          turnError(
            describeFailure(`${command} exited (${signal || code}) without a result`, stderrText),
          ),
        );
      if (result.status !== "SUCCESS")
        return reject(turnError(describeFailure(result.error || "compaction failed", stderrText)));
      resolve();
    });
    child.stdin.on("error", () => {});
    child.stdin.end("/compact\n");
  });
}
