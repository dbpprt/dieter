// Native RPC events projected into Dieter's existing UI-message/capability
// protocol. The clients remain presentation-only.
export function createOMPStream({ request, send, collector, restored }) {
  const state = restored || {
    createdAt: new Date().toISOString(),
    parts: {},
    tools: {},
    totalUsage: {},
  };
  const chunk = (value) => {
    collector.consumeUIChunk(value);
    send({ type: "chunk", chunk: value });
  };
  const metadata = () => ({
    createdAt: state.createdAt,
    usage: state.usage,
    totalUsage: state.totalUsage,
    contextWindowTokens: state.contextWindow || request.contextWindow,
    modelId: state.modelId,
  });
  function part(messageId, index, kind, delta, end = false) {
    const id = `omp-${messageId}-${index}`;
    const previous = state.parts[id] || { kind, length: 0, ended: false };
    if (!state.parts[id]) chunk({ type: `${kind}-start`, id });
    if (delta) {
      previous.length += delta.length;
      for (let offset = 0; offset < delta.length;) {
        let end = Math.min(offset + 128 * 1024, delta.length);
        if (end < delta.length && /[\uD800-\uDBFF]/.test(delta[end - 1])) end--;
        chunk({ type: `${kind}-delta`, id, delta: delta.slice(offset, end) });
        offset = end;
      }
    }
    if (end && !previous.ended) {
      chunk({ type: `${kind}-end`, id });
      previous.ended = true;
    }
    state.parts[id] = previous;
  }
  function toolInput(id, name, input) {
    if (state.tools[id]) return;
    const encoded = JSON.stringify(input ?? null);
    if (Buffer.byteLength(encoded) > 1024 * 1024)
      input = {
        truncated: true,
        preview: encoded.slice(0, 512 * 1024),
        note: "Full input retained in the OMP session.",
      };
    state.tools[id] = { name, input };
    chunk({
      type: "tool-input-available",
      toolCallId: id,
      toolName: name,
      input,
      dynamic: true,
      providerExecuted: true,
    });
  }
  return {
    state,
    start(continuing = false) {
      if (!continuing)
        chunk({ type: "start", messageId: request.responseMessageId, messageMetadata: metadata() });
    },
    text(text, id = `notice-${Object.keys(state.parts).length}`) {
      part(id, 0, "text", text, true);
    },
    resetForReply() {
      state.createdAt = new Date().toISOString();
      state.parts = {};
      state.totalUsage = {};
      state.usage = undefined;
      // A tool waiting for a native dialog started in the previous response.
      for (const [id, tool] of Object.entries(state.tools)) {
        chunk({
          type: "tool-input-available",
          toolCallId: id,
          toolName: tool.name,
          input: tool.input,
          dynamic: true,
          providerExecuted: true,
        });
      }
    },
    snapshot(snapshot) {
      state.contextWindow = snapshot.model?.contextWindow || state.contextWindow;
      if (snapshot.todoPhases?.length)
        collector.consumeOMPEnvelope({
          kind: "task-plan",
          payload: { phases: snapshot.todoPhases, source: "todo" },
        });
      else if (state.hadPlan)
        collector.consumeOMPEnvelope({ kind: "task-plan-clear", payload: {} });
      state.hadPlan = Boolean(snapshot.todoPhases?.length);
    },
    consume(frame) {
      if (frame.type === "command_output" && frame.text) this.text(frame.text);
      if (frame.type === "message_end" && frame.message?.role === "custom") {
        const content = frame.message.content;
        if (typeof content === "string") this.text(content);
        else if (Array.isArray(content))
          for (const item of content) if (item.type === "text") this.text(item.text);
      }
      if (frame.type === "subagent_lifecycle" || frame.type === "subagent_progress") {
        collector.consumeOMPEnvelope({
          kind: frame.type === "subagent_lifecycle" ? "lifecycle" : "progress",
          payload: frame.payload,
        });
      }
      if (frame.type === "message_start" && frame.message?.role === "assistant")
        chunk({ type: "start-step" });
      if (frame.type === "message_update") {
        const event = frame.assistantMessageEvent || {};
        const kind = event.type?.startsWith("thinking_") ? "reasoning" : "text";
        if (/^(text|thinking)_(start|delta|end)$/.test(event.type || "")) {
          part(
            frame.messageId,
            event.contentIndex,
            kind,
            event.type.endsWith("_delta") ? event.delta : "",
            event.type.endsWith("_end"),
          );
        }
        if (event.type === "toolcall_end") {
          const call = event.toolCall || event.partial?.content?.[event.contentIndex];
          if (call?.id) toolInput(call.id, call.name, call.arguments);
        }
      }
      if (frame.type === "message_end" && frame.message?.role === "assistant") {
        const message = frame.message;
        for (const [index, content] of (message.content || []).entries()) {
          if (content.type === "toolCall") toolInput(content.id, content.name, content.arguments);
          if (content.type === "text" || content.type === "thinking") {
            const text = content.text || content.thinking || "";
            const length = state.parts[`omp-${frame.messageId}-${index}`]?.length || 0;
            part(
              frame.messageId,
              index,
              content.type === "text" ? "text" : "reasoning",
              text.slice(length),
              true,
            );
          }
        }
        const usage = message.usage;
        if (usage) {
          const inputTokens = (usage.input || 0) + (usage.cacheRead || 0) + (usage.cacheWrite || 0);
          const outputTokens = usage.output || 0;
          state.usage = {
            inputTokens,
            outputTokens,
            totalTokens: inputTokens + outputTokens,
            inputTokenDetails: {
              cacheReadTokens: usage.cacheRead || 0,
              cacheWriteTokens: usage.cacheWrite || 0,
            },
          };
          for (const key of ["inputTokens", "outputTokens", "totalTokens"])
            state.totalUsage[key] = (state.totalUsage[key] || 0) + state.usage[key];
        }
        if (message.model) state.modelId = `${message.provider}/${message.model}`;
        chunk({ type: "finish-step" });
        chunk({ type: "message-metadata", messageMetadata: metadata() });
      }
      if (frame.type === "tool_execution_start")
        toolInput(frame.toolCallId, frame.toolName, frame.args);
      if (frame.type === "tool_execution_end") {
        toolInput(frame.toolCallId, frame.toolName, frame.args || {});
        const output = frame.result;
        // The daemon's worker frame ceiling is 8 MiB. Large native results are
        // still intact in OMP's session; give a visible bounded transcript preview.
        const encoded = JSON.stringify(output ?? null);
        const bounded =
          Buffer.byteLength(encoded) > 1024 * 1024
            ? {
                truncated: true,
                preview: encoded.slice(0, 512 * 1024),
                note: "Full result retained in the OMP session.",
              }
            : output;
        chunk(
          frame.isError
            ? {
                type: "tool-output-error",
                toolCallId: frame.toolCallId,
                errorText: encoded.slice(0, 512 * 1024),
              }
            : { type: "tool-output-available", toolCallId: frame.toolCallId, output: bounded },
        );
        delete state.tools[frame.toolCallId];
      }
      if (frame.type === "auto_retry_start") {
        send({
          type: "capability",
          capability: {
            id: "provider-status",
            operation: "replace",
            status: {
              provider: "omp",
              messageId: request.responseMessageId,
              state: "reconnecting",
              attempt: frame.attempt,
              maxAttempts: frame.maxAttempts,
              message: String(frame.errorMessage || "OMP is retrying the provider").slice(0, 1024),
              updatedAt: new Date().toISOString(),
            },
          },
        });
      }
      if (frame.type === "auto_retry_end")
        send({ type: "capability", capability: { id: "provider-status", operation: "clear" } });
    },
    finish() {
      for (const [id, value] of Object.entries(state.parts)) {
        if (!value.ended) {
          chunk({ type: `${value.kind}-end`, id });
          value.ended = true;
        }
      }
      chunk({ type: "finish", finishReason: "stop", messageMetadata: metadata() });
    },
  };
}

export function dialogText(dialog) {
  const lines = [dialog.title || "OMP needs your input", dialog.message];
  if (dialog.method === "select")
    lines.push(
      ...(dialog.options || []).map(
        (option, index) =>
          `${index + 1}. ${option}${dialog.optionDetails?.[index]?.description ? ` — ${dialog.optionDetails[index].description}` : ""}`,
      ),
    );
  lines.push(
    dialog.method === "confirm"
      ? "Reply yes or no in chat."
      : "Reply in chat, or reply /cancel to cancel this question.",
  );
  return lines.filter(Boolean).join("\n");
}

export function dialogAnswer(dialog, text) {
  const value = String(text || "").trim();
  const base = { type: "extension_ui_response", id: dialog.id };
  if (value === "/cancel") return { ...base, cancelled: true };
  if (dialog.method === "confirm") {
    if (!/^(yes|y|no|n)$/i.test(value))
      throw new Error("Reply yes or no to the pending OMP question.");
    return { ...base, confirmed: /^(yes|y)$/i.test(value) };
  }
  if (dialog.method === "select") {
    const option = /^\d+$/.test(value)
      ? dialog.options?.[Number(value) - 1]
      : dialog.options?.find((item) => item === value);
    if (!option) throw new Error("Reply with an option number or its exact text.");
    return { ...base, value: option };
  }
  return { ...base, value: text };
}
