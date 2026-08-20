import { appendFileSync } from 'node:fs';

export default function boardCapabilities(pi) {
  const path = process.env.NAUCLIO_OMP_CAPABILITY_FILE;
  if (!path) return;
  const write = (kind, payload) => {
    try {
      appendFileSync(path, `${JSON.stringify({ kind, payload })}\n`, { encoding: 'utf8', mode: 0o600 });
    } catch (error) {
      pi.logger.warn('Nauclio could not record an OMP capability event', { error: String(error) });
    }
  };
  pi.events.on('task:subagent:lifecycle', payload => write('lifecycle', payload));
  pi.events.on('task:subagent:progress', payload => write('progress', payload));
  pi.on('tool_result', event => {
    if (event.toolName !== 'todo' || event.isError || !Array.isArray(event.details?.phases)) return;
    write('task-plan', { phases: event.details.phases, source: 'todo' });
  });
  pi.on('todo_reminder', event => {
    write('task-plan', { tasks: event.todos, source: 'todo-reminder' });
  });
}
