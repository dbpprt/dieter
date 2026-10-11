// Deterministic native RPC peer: no provider credentials or model calls.
import readline from "node:readline";
import { appendFileSync } from "node:fs";
const emit = (frame) => process.stdout.write(JSON.stringify(frame) + "\n");
const input = readline.createInterface({ input: process.stdin });
let prompt,
  timer,
  todoPhases = [],
  hostTools = [];
const sessionFile = process.env.OMP_RPC_FIXTURE_SESSION;
const log = (message) =>
  appendFileSync(process.env.OMP_RPC_FIXTURE_LOG, JSON.stringify(message) + "\n");
const answer = (text) => {
  emit({ type: "message_start", messageId: "answer", message: { role: "assistant" } });
  emit({
    type: "message_update",
    messageId: "answer",
    assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: text },
  });
  emit({
    type: "message_end",
    messageId: "answer",
    message: {
      role: "assistant",
      content: [{ type: "text", text }],
      usage: { input: 10, output: 3, cacheRead: 2 },
      provider: "fixture",
      model: "rpc",
      stopReason: "stop",
    },
  });
};
const finish = (status = "completed", sessionSettled = true) =>
  emit({ type: "prompt_result", id: prompt.id, agentInvoked: true, status, sessionSettled });
emit({ type: "ready", protocolVersion: 1, supportedProtocolVersions: [1, 2] });
input.on("line", (line) => {
  const command = JSON.parse(line);
  log(command);
  const respond = (data) =>
    emit({ type: "response", command: command.type, id: command.id, success: true, data });
  switch (command.type) {
    case "negotiate_protocol":
      if (command.protocolVersion !== 2) throw new Error("Protocol v2 was not negotiated");
      respond({ protocolVersion: 2 });
      break;
    case "set_host_tools":
      hostTools = command.tools;
      respond({ toolNames: hostTools.map((t) => t.name) });
      break;
    case "set_subagent_subscription":
      if (command.level !== "progress") throw new Error("Subagent progress not subscribed");
      respond({ level: command.level });
      break;
    case "get_state":
      respond({
        sessionFile,
        sessionId: "fixture-session",
        model: { contextWindow: 1000 },
        todoPhases,
        isSettled: !timer,
      });
      break;
    case "compact":
      timer = setTimeout(() => {
        timer = undefined;
        respond({ summary: "Compacted fixture", tokensBefore: 20 });
      }, 100);
      break;
    case "prompt": {
      prompt = command;
      if (command.message === "/local") {
        emit({ type: "command_output", text: "Native local command output" });
        respond({ agentInvoked: false });
        break;
      }
      respond();
      if (command.message === "question") {
        emit({
          type: "tool_execution_start",
          toolCallId: "ask-1",
          toolName: "ask",
          args: { question: "Choose color" },
        });
        emit({
          type: "extension_ui_request",
          id: "dialog-1",
          method: "select",
          title: "Choose color",
          options: ["Red", "Blue"],
        });
      } else if (command.message === "host-tools" || command.message === "invalid-host-tool") {
        if (
          !hostTools.some(
            (t) => t.name === "present_content" && t.parameters && t.loadMode === "essential",
          )
        )
          throw new Error("Host tools missing");
        const args = { path: command.message === "host-tools" ? "report.txt" : "../outside.txt" };
        emit({
          type: "tool_execution_start",
          toolCallId: "present-1",
          toolName: "present_content",
          args,
        });
        emit({
          type: "host_tool_call",
          id: "host-1",
          toolCallId: "present-1",
          toolName: "present_content",
          arguments: args,
        });
      } else if (command.message === "slow-host") {
        emit({
          type: "tool_execution_start",
          toolCallId: "slow-1",
          toolName: "list_background_processes",
          args: {},
        });
        emit({
          type: "host_tool_call",
          id: "host-1",
          toolCallId: "slow-1",
          toolName: "list_background_processes",
          arguments: {},
        });
      } else if (command.message === "long" || command.message === "detached-cancel") {
        emit({ type: "message_start", messageId: "long", message: { role: "assistant" } });
        emit({
          type: "message_update",
          messageId: "long",
          assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "before " },
        });
        timer = setTimeout(() => {
          if (command.message === "detached-cancel") {
            emit({
              type: "tool_execution_start",
              toolCallId: "slow-1",
              toolName: "list_background_processes",
              args: {},
            });
            emit({
              type: "host_tool_call",
              id: "host-1",
              toolCallId: "slow-1",
              toolName: "list_background_processes",
              arguments: {},
            });
            emit({ type: "host_tool_cancel", targetId: "host-1" });
            timer = undefined;
            return;
          }
          emit({
            type: "message_update",
            messageId: "long",
            assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "after" },
          });
          emit({
            type: "message_end",
            messageId: "long",
            message: { role: "assistant", content: [{ type: "text", text: "before after" }] },
          });
          timer = undefined;
          finish();
        }, 800);
      } else if (command.message === "async") {
        answer("first");
        finish("completed", false);
        timer = setTimeout(() => {
          answer("settled");
          timer = undefined;
          emit({ type: "session_settled" });
        }, 100);
      } else if (command.message === "error") {
        emit({
          type: "prompt_result",
          id: prompt.id,
          status: "error",
          sessionSettled: true,
          error: { message: "fixture provider exhausted retries", retryable: true },
        });
      } else {
        answer(command.message);
        finish();
      }
      break;
    }
    case "host_tool_result":
      if (prompt.message === "slow-host" || prompt.message === "detached-cancel") {
        emit({
          type: "tool_execution_end",
          toolCallId: "slow-1",
          toolName: "list_background_processes",
          result: command.result,
        });
        answer(
          prompt.message === "detached-cancel"
            ? "Canceled host request skipped"
            : "Host admission completed",
        );
        finish();
        break;
      }
      emit({
        type: "tool_execution_end",
        toolCallId: "present-1",
        toolName: "present_content",
        result: command.result,
        isError: command.isError,
      });
      emit({
        type: "subagent_lifecycle",
        payload: { id: "child-1", agent: "worker", status: "started" },
      });
      emit({
        type: "subagent_progress",
        payload: { id: "child-1", progress: { id: "child-1", status: "completed", tokens: 20 } },
      });
      todoPhases = [{ name: "Verify", tasks: [{ content: "Report", status: "completed" }] }];
      emit({
        type: "tool_execution_end",
        toolCallId: "todo-1",
        toolName: "todo_write",
        result: { content: [] },
      });
      answer(command.isError ? "host error recovered" : "host tools completed");
      finish();
      break;
    case "extension_ui_response":
      if (command.id !== "dialog-1" || command.value !== "Blue")
        throw new Error("Native UI answer mismatch");
      emit({
        type: "tool_execution_end",
        toolCallId: "ask-1",
        toolName: "ask",
        result: { content: [{ type: "text", text: command.value }] },
      });
      answer("Selected Blue");
      finish();
      break;
    case "abort":
      clearTimeout(timer);
      timer = undefined;
      respond();
      finish("aborted");
      break;
    default:
      throw new Error(`Unexpected native command ${command.type}`);
  }
});
