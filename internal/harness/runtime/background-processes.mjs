import { randomUUID, createHash } from 'node:crypto';
import { tool } from 'ai';
import { z } from 'zod';

const text = max => z.string().max(max).refine(value => !value.includes('\0') && Buffer.byteLength(value) <= max, `Maximum ${max} UTF-8 bytes, no NUL`);

// One bounded request/reply channel over the worker's private stdio. A tool
// result acknowledges daemon admission, not merely a request to start work.
export function createProcessHostBridge(input, emit, { timeoutMs = 35_000 } = {}) {
  const pending = new Map();
  let closed = false;
  const failAll = () => {
    closed = true;
    for (const value of pending.values()) { clearTimeout(value.timer); value.reject(new Error('Background process host disconnected')); }
    pending.clear();
  };
  const receive = line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.type !== 'background-process-result') return;
    const value = pending.get(message.id);
    if (!value) return;
    pending.delete(message.id); clearTimeout(value.timer);
    if (message.error) value.reject(new Error(message.error)); else value.resolve(message.result);
  };
  input.on('line', receive); input.on('close', failAll);
  return {
    call(operation, args) {
      if (closed) return Promise.reject(new Error('Background process host disconnected'));
      if (pending.size >= 8) return Promise.reject(new Error('Too many background process requests'));
      const id = randomUUID();
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('Background process request timed out; inspect the process list before retrying')); }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        try { emit({ type: 'background-process', processCall: { id, operation, arguments: args } }); }
        catch (error) { pending.delete(id); clearTimeout(timer); reject(error); }
      });
    },
    dispose() { input.off('line', receive); input.off('close', failAll); failAll(); },
  };
}

export function createBackgroundProcessTools(request, call) {
  const processRef = z.object({ executionId: text(128).min(1) }).strict();
  return {
    start_background_process: tool({
      description: 'Start an exact-argv background process in this conversation’s workspace and return its registered execution ID immediately. Use for dev servers, builds, or tests that should continue while you work. Visible in the Processes workspace tab. No implicit shell; pass /bin/sh and -c explicitly if shell syntax is needed. Closing the tab or finishing this turn does not stop it.',
      inputSchema: z.object({
        argv: z.array(text(8192)).min(1).max(256), name: text(80).optional(),
        workingDirectory: text(4096).optional(), environment: z.record(text(256), text(8192)).optional(),
        timeoutMs: z.number().int().min(0).max(604_800_000).optional(), idempotencyKey: text(128).optional(),
      }).strict().refine(value => Buffer.byteLength(JSON.stringify(value)) <= 120 * 1024, 'Background process input is too large'),
      execute: async (args, options) => {
        const identity = options?.toolCallId || randomUUID();
        const idempotencyKey = args.idempotencyKey || createHash('sha256').update(`${request.sessionId}:${request.responseMessageId}:${identity}`).digest('hex');
        return call('start', { ...args, idempotencyKey });
      },
    }),
    list_background_processes: tool({
      description: 'List this conversation’s retained background processes, their execution IDs, running/completed state, and exit results. The list is bounded by daemon retention.',
      inputSchema: z.object({}).strict(), execute: () => call('list', {}),
    }),
    read_background_process: tool({
      description: 'Read a bounded page of a registered process’s stdout/stderr and current state without waiting for exit. Pass returned afterSequence to read the next page. Only this conversation’s processes can be read.',
      inputSchema: processRef.extend({ afterSequence: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER).optional() }),
      execute: args => call('read', args),
    }),
    stop_background_process: tool({
      description: 'Explicitly stop a background process belonging to this conversation. Use only when it is no longer needed or the user asks to stop it. Output remains available afterward.',
      inputSchema: processRef, execute: args => call('stop', args),
    }),
  };
}

export const backgroundProcessInstructions = 'Use start_background_process for a dev server, build, test, or other command that should continue after your tool call. Dieter registers it to this conversation and shows it in the Processes workspace tab. Use list_background_processes/read_background_process for bounded status/output, and stop_background_process only for explicit cancellation. Do not launch detached shell jobs as a substitute: those are not registered with Dieter. Processes survive turn completion and UI disconnects, but end when the daemon stops.';
