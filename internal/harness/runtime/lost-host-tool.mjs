// Claude Code reaches Dieter's host tools (the harness-tools MCP server)
// through the adapter's bridge, which hands each call to this worker as a
// tool-call part. On 2026-11-27 one call (list_background_processes) never
// arrived: Claude Code reported the tool as running, with a heartbeat every
// 30 s for 23 hours, while the worker never received the call and so could not
// answer it. The turn never ended and kept its file claims.
//
// A host tool's call reaches the worker within milliseconds of its input being
// complete; one that has not after hostToolDispatchTimeoutMs was lost. The
// worker then stops that stream and resumes the durable session so the agent
// can repeat the call (runner.mjs).

export const hostToolDispatchTimeoutMs = 60_000;
export const maxLostHostToolRetries = 2;

const hostToolPrefix = "mcp__harness-tools__";

// observe() takes every part of one stream; lost() names the first host tool
// call whose input is complete but whose call has not reached the worker for
// timeoutMs.
export function createLostHostToolDetector({
  timeoutMs = hostToolDispatchTimeoutMs,
  now = Date.now,
} = {}) {
  const started = new Map();
  const waiting = new Map();
  const dispatched = new Set();
  // A heartbeat dates the call by Claude Code's own elapsed time, which can
  // only move its start earlier.
  const wait = (toolCallId, toolName, since) => {
    if (dispatched.has(toolCallId)) return;
    const known = waiting.get(toolCallId);
    if (known) known.since = Math.min(known.since, since);
    else waiting.set(toolCallId, { toolName, since });
  };
  return {
    observe(part) {
      switch (part?.type) {
        case "tool-input-start":
          // Provider-executed tools (Bash, Read, …) run inside Claude Code.
          if (part.providerExecuted === false && part.id) started.set(part.id, part.toolName);
          return;
        case "tool-input-end":
          if (started.has(part.id)) wait(part.id, started.get(part.id), now());
          return;
        case "tool-call":
        case "tool-result":
        case "tool-error":
          if (part.toolCallId) {
            dispatched.add(part.toolCallId);
            waiting.delete(part.toolCallId);
          }
          return;
        case "raw": {
          // Claude Code's progress heartbeat for a running MCP tool also
          // covers a call whose input events were never streamed.
          const value = part.rawValue ?? part.raw ?? part.value;
          if (value?.type !== "tool_progress") return;
          const name = String(value.tool_name || "");
          // Heartbeat ids are "<call>-heartbeat-<n>"; the parent is the call.
          const toolCallId =
            value.parent_tool_use_id ||
            String(value.tool_use_id || "").replace(/-heartbeat-\d+$/, "");
          if (!name.startsWith(hostToolPrefix) || !toolCallId) return;
          const elapsed = Number(value.elapsed_time_seconds);
          wait(
            toolCallId,
            name.slice(hostToolPrefix.length),
            now() - (Number.isFinite(elapsed) ? elapsed * 1000 : 0),
          );
          return;
        }
        default:
      }
    },
    lost() {
      const current = now();
      for (const [toolCallId, call] of waiting) {
        if (current - call.since >= timeoutMs) return { toolCallId, toolName: call.toolName };
      }
      return undefined;
    },
  };
}

export function lostHostToolPrompt(toolName) {
  return `Dieter never received your last call to the ${toolName} tool: it was lost before it ran, so it produced no result. If you still need that result, call ${toolName} again. Inspect the current state before repeating any other action, then continue the current task.`;
}

export function lostHostToolNotice(toolName) {
  return `Claude Code lost the call to ${toolName} before it reached Dieter; Dieter resumed the session.\n\n`;
}

export function lostHostToolFailure(toolName) {
  return `Claude Code repeatedly lost the call to ${toolName} before it reached Dieter, so the turn was stopped. The session is preserved: send a message to continue.`;
}
