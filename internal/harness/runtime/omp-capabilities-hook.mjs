import { appendFileSync, readFileSync } from "node:fs";

// Dieter's OMP extension. It applies the turn's thinking level at the start of
// each prompt (the launch arguments stay fixed across turns, ADR 0007), and it
// records subagent and task-plan events for Dieter's capability view.
export default function boardCapabilities(pi) {
  const turnFile = process.env.DIETER_OMP_TURN_FILE;
  if (turnFile) {
    pi.on("before_agent_start", () => {
      try {
        const turn = JSON.parse(readFileSync(turnFile, "utf8"));
        if (
          typeof turn.thinking === "string" &&
          turn.thinking &&
          pi.getThinkingLevel() !== turn.thinking
        ) {
          pi.setThinkingLevel(turn.thinking);
        }
      } catch (error) {
        pi.logger.warn("Dieter could not apply the turn thinking level", { error: String(error) });
      }
    });
  }
  const path = process.env.DIETER_OMP_CAPABILITY_FILE;
  if (!path) return;
  const write = (kind, payload) => {
    try {
      appendFileSync(path, `${JSON.stringify({ kind, payload })}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
    } catch (error) {
      pi.logger.warn("Dieter could not record an OMP capability event", { error: String(error) });
    }
  };
  pi.events.on("task:subagent:lifecycle", (payload) => write("lifecycle", payload));
  pi.events.on("task:subagent:progress", (payload) => write("progress", payload));
  pi.on("tool_result", (event) => {
    if (event.toolName !== "todo" || event.isError || !Array.isArray(event.details?.phases)) return;
    write("task-plan", { phases: event.details.phases, source: "todo" });
  });
  pi.on("todo_reminder", (event) => {
    write("task-plan", { tasks: event.todos, source: "todo-reminder" });
  });
}
