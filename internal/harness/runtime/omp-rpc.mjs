import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { connect } from "node:net";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHarnessSandboxTemplate } from "@ai-sdk/harness/agent";
import { createACP } from "@ai-sdk/harness-acp";
import { z } from "zod";
import {
  createBackgroundProcessTools,
  backgroundProcessInstructions,
} from "./background-processes.mjs";
import {
  createContentPresentationTool,
  contentPresentationInstructions,
} from "./content-presentation.mjs";
import { createOMPSessionWithBootstrapRetry, prepareOMPConfig } from "./omp-resilience.mjs";
import { ompPackageVersion, ompRuntimeConfig } from "./provider-options.mjs";
import { jsonLines, rpcPayloadLimit, writeJSON } from "./omp-rpc-protocol.mjs";
import { createOMPStream, dialogAnswer, dialogText } from "./omp-rpc-stream.mjs";

// Reuse the SDK's pinned npm installer/cache, without starting an ACP session.
export function ompBootstrapHarness() {
  return createACP({
    harnessId: "omp",
    source: {
      type: "npm-simple",
      packageName: "@oh-my-pi/pi-coding-agent",
      packageVersion: ompPackageVersion,
    },
    executable: "omp",
  });
}

export class OMPConnection {
  queue = [];
  bytes = 0;
  pending = new Map();
  waiters = [];
  error;
  attached;
  constructor(socket) {
    this.socket = socket;
    this.attached = new Promise((resolve, reject) => {
      this.onAttach = resolve;
      this.failAttach = reject;
    });
    this.stopped = new Promise((resolve) => {
      this.onStop = resolve;
    });
    socket.on("error", (error) => this.fail(error));
    void (async () => {
      try {
        for await (const record of jsonLines(socket, rpcPayloadLimit + 1024)) {
          if (record.attached) {
            this.dialogs = record.dialogs || [];
            this.onAttach();
            continue;
          }
          if (record.stopped) {
            this.onStop();
            continue;
          }
          if (record.error) throw new Error(record.error);
          if (!Number.isSafeInteger(record.seq) || !record.frame)
            throw new Error("Invalid OMP bridge event");
          const response = record.frame;
          this.onFrame?.(response);
          if (response.type === "response" && this.pending.has(response.id)) {
            const pending = this.pending.get(response.id);
            this.pending.delete(response.id);
            clearTimeout(pending.timer);
            if (response.success) pending.resolve(response.data);
            else pending.reject(new Error(response.error || `OMP ${response.command} failed`));
          }
          const size = Buffer.byteLength(JSON.stringify(record));
          if (this.queue.length >= 4096 || this.bytes + size > 128 * 1024 * 1024)
            throw new Error("OMP RPC worker event queue exceeded its limit");
          this.bytes += size;
          this.queue.push({ ...record, size });
          this.wake();
        }
        throw new Error("OMP RPC bridge disconnected; the prompt was not replayed");
      } catch (error) {
        this.fail(error);
      }
    })();
  }
  wake() {
    for (const resolve of this.waiters.splice(0)) resolve();
  }
  fail(error) {
    this.error ||= error;
    this.failAttach(error);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    this.wake();
  }
  async next() {
    while (!this.queue.length) {
      if (this.error) throw this.error;
      await new Promise((resolve) => this.waiters.push(resolve));
    }
    const record = this.queue.shift();
    this.bytes -= record.size;
    return record;
  }
  send(frame) {
    return writeJSON(this.socket, { type: "send", frame });
  }
  async command(type, args = {}, timeoutMs = 60_000) {
    if (this.error) throw this.error;
    if (this.pending.size >= 16) throw new Error("Too many pending OMP RPC commands");
    const id = randomUUID();
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`OMP RPC ${type} response timed out; do not replay the prompt`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
    });
    // Install the rejection handler before writing, including a write failure.
    const sending = this.send({ id, type, ...args }).catch((error) => this.fail(error));
    const [, response] = await Promise.all([sending, result]);
    return response;
  }
  close() {
    this.socket.destroy();
    this.fail(new Error("OMP worker detached"));
  }
}

export async function connectOMP(meta, after) {
  const socket = connect(meta.socketPath);
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  const connection = new OMPConnection(socket);
  await writeJSON(socket, { type: "attach", token: meta.token, after });
  await connection.attached;
  return connection;
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function sessionSnapshot(state) {
  return {
    sessionFile: state.sessionFile,
    sessionId: state.sessionId,
    model: { contextWindow: state.model?.contextWindow },
    todoPhases: state.todoPhases,
    contextUsage: state.contextUsage,
  };
}
async function executeHostTool(tool, args, options) {
  let onAbort;
  const aborted = new Promise((_, reject) => {
    onAbort = () =>
      reject(
        new Error(
          "OMP canceled the host tool request; inspect registered processes before retrying.",
        ),
      );
    if (options.abortSignal.aborted) onAbort();
    else options.abortSignal.addEventListener("abort", onAbort, { once: true });
  });
  try {
    return await Promise.race([aborted, tool.execute(args, options)]);
  } finally {
    options.abortSignal.removeEventListener("abort", onAbort);
  }
}
async function startBridge({ request, sandboxSession, instructions, stateDir }) {
  await createOMPSessionWithBootstrapRetry({
    createSession: async () => {
      const template = await createHarnessSandboxTemplate({ harnesses: [ompBootstrapHarness()] });
      await template.prepare({ session: sandboxSession });
    },
    packageVersion: ompPackageVersion,
    sessionOptions: {},
    onRetry: ({ attempt, maxAttempts }) =>
      console.error(`Preparing pinned OMP RPC runtime (${attempt + 1}/${maxAttempts})`),
  });
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  await chmod(stateDir, 0o700);
  const configPath = await prepareOMPConfig({
    runtimeRoot: request.runtimeRoot,
    content: ompRuntimeConfig(),
  });
  const native = request.session?.data?.ompRPC;
  const legacyId = request.session?.data?.acpSessionId;
  if (request.session && !native && !legacyId)
    throw new Error(
      "OMP session has no native or ACP persistence identity; refusing to start a replacement session",
    );
  const args = [
    "--mode",
    "rpc-ui",
    "--config",
    configPath,
    "--no-title",
    "--no-pty",
    "--yolo",
    ...(request.model ? ["--model", request.model] : []),
    ...(request.effort ? ["--thinking", request.effort] : []),
    ...(request.options?.advisor === "true" ? ["--advisor"] : []),
    ...(instructions ? ["--append-system-prompt", instructions] : []),
    ...(legacyId
      ? ["--resume", legacyId]
      : ["--session-dir", join(request.runtimeRoot, "omp-sessions", request.sessionId)]),
    ...(native?.sessionFile ? ["--resume", native.sessionFile] : []),
  ];
  const config = {
    executable: join(
      homedir(),
      ".ai-sdk-harness",
      ".harness-bootstrap",
      "omp",
      "implementation",
      "node_modules",
      ".bin",
      "omp",
    ),
    args,
    cwd: request.projectPath,
    token: randomUUID(),
    socketPath: join(tmpdir(), `dieter-omp-${randomUUID()}.sock`),
  };
  await writeFile(join(stateDir, "start.json"), JSON.stringify(config), { mode: 0o600 });
  const child = spawn(
    process.execPath,
    [
      join(dirname(fileURLToPath(import.meta.url)), "omp-rpc-bridge.mjs"),
      "--bridge-state-dir",
      stateDir,
    ],
    {
      detached: true,
      stdio: "ignore",
      env: process.env,
    },
  );
  let failure;
  child.on("error", (error) => {
    failure = error;
  });
  child.unref();
  for (let attempt = 0; attempt < 200; attempt++) {
    if (failure) throw failure;
    if (child.exitCode != null)
      throw new Error(`OMP RPC bridge exited ${child.exitCode} during startup`);
    try {
      const meta = JSON.parse(await readFile(join(stateDir, "bridge-meta.json"), "utf8"));
      if (meta.pid === child.pid) return meta;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await delay(25);
  }
  // Only signal the process group we just created.
  process.kill(-child.pid, "SIGTERM");
  throw new Error("OMP RPC bridge startup timed out");
}

// The next normal human chat message answers a pending native dialog. No new
// client operation, question widget, or provider credential copying is needed.
export async function runNativeOMP({
  request,
  runtimePrompt,
  sandboxSession,
  processBridge,
  send,
  collector,
  exitWorker,
  start = startBridge,
}) {
  let connection,
    suspending = false,
    interrupted = false,
    parked = false,
    settled = false,
    cursor = 0,
    promptId,
    dispatched = false;
  const controller = new AbortController();
  const tools = {
    ...(request.contentPresentationEnabled
      ? { present_content: createContentPresentationTool(request, send) }
      : {}),
    ...(processBridge ? createBackgroundProcessTools(request, processBridge.call) : {}),
  };
  const instructions = [
    request.instructions,
    request.contentPresentationEnabled ? contentPresentationInstructions : "",
    processBridge ? backgroundProcessInstructions : "",
    "When you need a human answer, use the ask tool. Dieter displays native RPC questions in chat and delivers the next human message as the answer.",
  ]
    .filter(Boolean)
    .join("\n\n");
  const stateDir = join(request.runtimeRoot, ".agent-runs", request.sessionId, "omp-rpc", "bridge");
  const saved = request.continue
    ? request.session?.continueFrom?.data?.ompRPC
    : request.session?.data?.ompRPC;
  const waiting = saved?.pendingDialog;
  const stream = createOMPStream({
    request,
    send,
    collector,
    restored: request.continue || waiting ? saved?.stream : undefined,
  });
  const activeTools = new Map();
  const canceledTools = new Set();
  let pendingDialog = waiting;
  let snapshot = saved?.snapshot;
  let turnResult;
  function lifecycle(continuing = false) {
    const data = {
      ompRPC: {
        version: 1,
        stateDir,
        sessionFile: snapshot?.sessionFile || saved?.sessionFile,
        snapshot,
        promptId,
        cursor,
        ...(continuing || pendingDialog ? { stream: stream.state } : {}),
        ...(pendingDialog ? { pendingDialog } : {}),
      },
    };
    const state = { type: "resume-session", harnessId: "omp", sessionId: request.sessionId, data };
    if (continuing)
      state.continueFrom = {
        type: "continue-session",
        harnessId: "omp",
        sessionId: request.sessionId,
        data,
      };
    return state;
  }
  const suspend = () => {
    if (suspending || interrupted) return;
    suspending = true;
    // Serialize after the current event's host-tool work has finished. The loop
    // is woken without aborting OMP; no in-flight inference is resubmitted.
    connection?.wake();
    if (dispatched && activeTools.size === 0) {
      send({ type: "session", state: lifecycle(true) });
      connection?.close();
      void exitWorker(0);
    }
  };
  const interrupt = () => {
    if (suspending || interrupted) return;
    interrupted = true;
    controller.abort();
    for (const value of activeTools.values()) value.abort();
    void connection?.command("abort", {}, 5000).catch(() => {});
    connection?.wake();
  };
  process.on("SIGUSR1", suspend);
  process.on("SIGTERM", interrupt);
  process.on("SIGINT", interrupt);
  const forceInterrupt = setInterval(() => {
    if (suspending && !connection) return;
    if (interrupted) void exitWorker(130);
  }, 8000);
  forceInterrupt.unref();
  try {
    if (request.continue || waiting) {
      if (!saved?.promptId || saved.stateDir !== stateDir)
        throw new Error("OMP restart recovery is missing its native continuation");
      const meta = JSON.parse(await readFile(join(stateDir, "bridge-meta.json"), "utf8"));
      connection = await connectOMP(meta, saved.cursor);
      cursor = saved.cursor;
      promptId = saved.promptId;
    } else {
      const meta = await start({ request, sandboxSession, instructions, stateDir });
      connection = await connectOMP(meta, 0);
      // OMP emits ready after its normal settings, plugins and MCP discovery.
      const startupTimer = setTimeout(
        () => connection.fail(new Error("OMP RPC ready timed out")),
        120_000,
      );
      try {
        for (;;) {
          const record = await connection.next();
          cursor = record.seq;
          if (record.frame.type === "ready") break;
        }
      } finally {
        clearTimeout(startupTimer);
      }
      await connection.command("negotiate_protocol", { protocolVersion: 2 });
      await connection.command("set_host_tools", {
        tools: Object.entries(tools).map(([name, value]) => ({
          name,
          description: value.description,
          parameters: z.toJSONSchema(value.inputSchema, { unrepresentable: "any" }),
          loadMode: "essential",
        })),
      });
      await connection.command("set_subagent_subscription", { level: "progress" });
      snapshot = sessionSnapshot(await connection.command("get_state"));
      if (!snapshot.sessionFile)
        throw new Error("OMP RPC did not provide a persisted session file");
      promptId = randomUUID();
    }
    stream.start(request.continue === true);
    connection.onFrame = (frame) => {
      if (frame.type === "host_tool_cancel") {
        canceledTools.add(frame.targetId);
        activeTools.get(frame.targetId)?.abort();
      }
    };
    stream.snapshot(snapshot || {});
    if (waiting && !request.continue) {
      stream.resetForReply();
      let answer;
      if (!connection.dialogs.includes(waiting.id)) {
        stream.text(
          "The earlier OMP question expired. Your message will continue the conversation.",
        );
        pendingDialog = undefined;
        promptId = randomUUID();
        await connection.send({
          type: "prompt",
          id: promptId,
          message: runtimePrompt,
          streamingBehavior: "followUp",
        });
      } else
        try {
          answer = dialogAnswer(waiting, request.prompt);
        } catch (error) {
          stream.text(error.message + "\n\n" + dialogText(waiting));
          parked = true;
        }
      if (answer) {
        await connection.send(answer);
        pendingDialog = undefined;
      }
    } else if (!request.continue) {
      // OMP's text-mode /compact and /handoff dispatch background commands,
      // then acknowledge the prompt before their output arrives. Their native
      // RPC commands have an authoritative response after completion instead.
      const command = /^\/(compact|handoff)(?:\s+(.*))?$/s.exec(
        String(request.prompt || "").trim(),
      );
      await connection.send(
        command
          ? { type: command[1], id: promptId, customInstructions: command[2] }
          : { type: "prompt", id: promptId, message: runtimePrompt },
      );
    }
    dispatched = true;
    while (!parked && !settled) {
      if (suspending || interrupted) break;
      // A suspend signal must also wake an otherwise idle native stream.
      if (!connection.queue.length) {
        if (connection.error) throw connection.error;
        await new Promise((resolve) => connection.waiters.push(resolve));
        continue;
      }
      const record = await connection.next();
      const frame = record.frame;
      stream.consume(frame);
      if (frame.type !== "host_tool_call") cursor = record.seq;
      if (frame.type === "rpc_frame_error")
        throw new Error(frame.error || "OMP RPC transport error");
      if (frame.type === "host_tool_call") {
        const tool = tools[frame.toolName];
        const abort = new AbortController();
        activeTools.set(frame.id, abort);
        try {
          if (!tool) throw new Error(`Unknown Dieter host tool ${frame.toolName}`);
          if (canceledTools.delete(frame.id)) throw new Error("OMP canceled the host tool request");
          const args = tool.inputSchema.parse(frame.arguments);
          const result = await executeHostTool(tool, args, {
            toolCallId: frame.toolCallId,
            abortSignal: abort.signal,
          });
          await connection.send({
            type: "host_tool_result",
            id: frame.id,
            result: { content: [{ type: "text", text: JSON.stringify(result) }], details: result },
          });
        } catch (error) {
          await connection.send({
            type: "host_tool_result",
            id: frame.id,
            isError: true,
            result: { content: [{ type: "text", text: error.message }] },
          });
        } finally {
          activeTools.delete(frame.id);
        }
      }
      if (frame.type === "host_tool_cancel") activeTools.get(frame.targetId)?.abort();
      if (
        frame.type === "tool_execution_end" &&
        ["todo", "todo_write", "TodoWrite"].includes(frame.toolName)
      ) {
        snapshot = sessionSnapshot(await connection.command("get_state"));
        stream.snapshot(snapshot);
      }
      if (frame.type === "extension_ui_request") {
        if (["select", "confirm", "input", "editor"].includes(frame.method)) {
          pendingDialog = frame;
          stream.text(dialogText(frame));
          parked = true;
        } else if (frame.method === "notify") stream.text(frame.message || "");
        else if (frame.method === "open_url")
          stream.text(
            [frame.instructions, frame.launchUrl || frame.url].filter(Boolean).join("\n"),
          );
        else if (frame.method === "cancel" && pendingDialog?.id === frame.targetId)
          pendingDialog = undefined;
      }
      if (frame.type === "prompt_result" && frame.id === promptId) {
        turnResult = frame;
        if (frame.status === "error") throw new Error(frame.error?.message || "OMP prompt failed");
        if (frame.status === "aborted" && !interrupted) throw new Error("OMP prompt was aborted");
        settled = frame.sessionSettled === true;
      }
      if (
        frame.type === "response" &&
        frame.id === promptId &&
        ["compact", "handoff"].includes(frame.command)
      ) {
        stream.text(
          frame.success
            ? frame.command === "compact"
              ? "OMP session compacted."
              : `OMP handoff saved${frame.data?.savedPath ? `: ${frame.data.savedPath}` : "."}`
            : `${frame.command === "compact" ? "Compaction" : "Handoff"} failed: ${frame.error}`,
        );
        settled = true;
      } else if (frame.type === "response" && frame.id === promptId && frame.success === false)
        throw new Error(frame.error || "OMP rejected the prompt");
      // Native built-ins can finish synchronously without prompt_result. OMP
      // explicitly signals this on the prompt response (e.g. /compact, /help).
      if (
        frame.type === "response" &&
        frame.id === promptId &&
        frame.success &&
        frame.data?.agentInvoked === false
      )
        settled = true;
      if (frame.type === "session_settled" && turnResult) settled = true;
      cursor = record.seq;
    }
    if (suspending) {
      send({ type: "session", state: lifecycle(true) });
    } else if (parked) {
      stream.finish();
      send({ type: "session", state: lifecycle() });
    } else {
      if (!interrupted) {
        snapshot = sessionSnapshot(await connection.command("get_state"));
        stream.snapshot(snapshot);
        stream.finish();
        collector.finishTaskPlan("completed");
      } else {
        collector.finalize("aborted");
        collector.finishTaskPlan("aborted");
      }
      pendingDialog = undefined;
      send({ type: "session", state: lifecycle() });
    }
  } catch (error) {
    if (!interrupted) {
      console.error(error.message);
      send({ type: "error", error: error.message });
      process.exitCode = 1;
    }
    // A failed/stopped bridge cannot own a pending UI handle. Preserve native
    // history for the next explicit human turn, without replaying this prompt.
    if (snapshot?.sessionFile || saved?.sessionFile) {
      pendingDialog = undefined;
      send({ type: "session", state: lifecycle() });
    }
    collector.finalize(interrupted ? "aborted" : "failed");
    collector.finishTaskPlan(interrupted ? "aborted" : "failed");
  } finally {
    clearInterval(forceInterrupt);
    process.off("SIGUSR1", suspend);
    process.off("SIGTERM", interrupt);
    process.off("SIGINT", interrupt);
    if (connection && !suspending && !parked) {
      await writeJSON(connection.socket, { type: "stop" }).catch(() => {});
      let timer;
      await Promise.race([
        connection.stopped,
        new Promise((resolve) => {
          timer = setTimeout(resolve, 5000);
        }),
      ]);
      clearTimeout(timer);
    }
    connection?.close();
    processBridge?.dispose();
  }
  await exitWorker(interrupted ? 130 : process.exitCode || 0);
}
