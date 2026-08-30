import { open } from 'node:fs/promises';
import { createTerminalStepReconciler } from './stream-reconciliation.mjs';

const terminalStatuses = new Set(['completed', 'failed', 'aborted']);
const terminalPlanStates = new Set(['completed', 'stopped', 'failed', 'aborted']);
const progressHeartbeatMs = 60_000;
const tailerReadChunkBytes = 256 * 1024;

function compactLines(value, limit = 5) {
  const text = typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value);
  return text.split('\n').map(line => line.trim()).filter(Boolean).slice(-limit);
}

function clean(value) {
  return JSON.parse(JSON.stringify(value));
}

export function createSubagentCapabilityCollector({ provider, adapter = provider, messageId, emit, now = () => new Date().toISOString() }) {
  const subagents = new Map();
  const emittedSubagents = new Map();
  const claudeToolNames = new Map();
  const claudeTaskCreates = new Map();
  const claudeTasks = new Map();
  let claudeTaskSequence = 0;
  let taskPlan;
  let taskPlanFingerprint = '';
  let taskPlanRevision = 0;

  function normalizeTaskStatus(status) {
    if (status === 'in_progress' || status === 'inProgress' || status === 'in-progress' || status === 'running') return 'in_progress';
    if (status === 'completed' || status === 'done') return 'completed';
    if (status === 'blocked') return 'blocked';
    if (status === 'abandoned' || status === 'cancelled' || status === 'canceled') return 'abandoned';
    return 'pending';
  }

  function normalizeTask(task, index) {
    if (!task || typeof task !== 'object') return undefined;
    const content = String(task.content || task.text || task.step || task.subject || '').trim();
    if (!content) return undefined;
    return clean({
      ...(task.id ? { id: String(task.id) } : {}),
      content,
      ...(task.activeForm || task.active_form ? { activeForm: String(task.activeForm || task.active_form) } : {}),
      status: normalizeTaskStatus(task.status),
      ...(task.blocker || task.reason ? { blocker: String(task.blocker || task.reason) } : {}),
      ...(task.priority ? { priority: String(task.priority) } : {}),
      order: index,
    });
  }

  function normalizePhases(phases) {
    if (!Array.isArray(phases)) return [];
    return phases.map((phase, phaseIndex) => {
      const source = Array.isArray(phase) ? { tasks: phase } : phase;
      if (!source || typeof source !== 'object') return undefined;
      const tasks = (Array.isArray(source.tasks) ? source.tasks : Array.isArray(source.items) ? source.items : [])
        .map(normalizeTask)
        .filter(Boolean);
      if (!tasks.length) return undefined;
      return clean({
        name: String(source.name || source.phase || (phases.length > 1 ? `Phase ${phaseIndex + 1}` : '')).trim(),
        tasks,
      });
    }).filter(Boolean);
  }

  function tasksToPhase(tasks) {
    const normalized = (Array.isArray(tasks) ? tasks : []).map(normalizeTask).filter(Boolean);
    return normalized.length ? [{ name: '', tasks: normalized }] : [];
  }

  function replaceTaskPlan({ phases, tasks, explanation = '', state = 'active', source = '' }) {
    if ((source === 'acp-plan' || source === 'todo-reminder') && taskPlan?.source === 'todo') return;
    const normalizedPhases = phases ? normalizePhases(phases) : tasksToPhase(tasks);
    if (!normalizedPhases.length) {
      if (taskPlan && state !== 'active') finishTaskPlan(state);
      return;
    }
    const normalizedState = terminalPlanStates.has(state) ? state : 'active';
    const fingerprint = JSON.stringify({ normalizedPhases, explanation: String(explanation || ''), state: normalizedState });
    if (fingerprint === taskPlanFingerprint) return;
    taskPlanRevision += 1;
    taskPlanFingerprint = fingerprint;
    taskPlan = clean({
      id: `${provider}:${messageId}`,
      provider,
      messageId,
      revision: taskPlanRevision,
      state: normalizedState,
      explanation: String(explanation || ''),
      source: String(source || ''),
      phases: normalizedPhases,
      updatedAt: now(),
    });
    emit({ id: 'task-plan', operation: 'replace', plan: taskPlan });
  }

  function finishTaskPlan(state) {
    if (!taskPlan || terminalPlanStates.has(taskPlan.state)) return;
    const tasks = taskPlan.phases.flatMap(phase => phase.tasks);
    const allSettled = tasks.length > 0 && tasks.every(task => task.status === 'completed' || task.status === 'abandoned');
    replaceTaskPlan({
      phases: taskPlan.phases,
      explanation: taskPlan.explanation,
      source: taskPlan.source,
      state: state === 'completed' && !allSettled ? 'stopped' : state,
    });
  }

  function upsert(id, patch, { force = false } = {}) {
    if (!id) return;
    const timestamp = now();
    const previous = subagents.get(id) || {
      id,
      provider,
      messageId,
      status: 'pending',
      startedAt: timestamp,
    };
    const next = clean({
      ...previous,
      ...patch,
      id,
      provider,
      messageId,
      updatedAt: timestamp,
      ...(terminalStatuses.has(patch.status) ? { endedAt: timestamp } : {}),
    });
    subagents.set(id, next);
    const { updatedAt: _updatedAt, durationMs = 0, recentOutput: _recentOutput, ...material } = next;
    const fingerprint = JSON.stringify({ ...material, progressMinute: Math.floor(Number(durationMs) / progressHeartbeatMs) });
    if (!force && emittedSubagents.get(id) === fingerprint) return;
    emittedSubagents.set(id, fingerprint);
    emit({ id: 'subagents', operation: 'upsert', subagent: next });
  }

  function emitClaudeTasks() {
    const tasks = [...claudeTasks.values()].sort((left, right) => Number(left.id) - Number(right.id));
    replaceTaskPlan({ tasks, source: 'Tasks' });
  }

  function consumeUIChunk(chunk) {
    if (!chunk || typeof chunk !== 'object') return;
    const id = chunk.toolCallId;
    if (adapter === 'claude-code' && chunk.type === 'tool-input-available' && id && chunk.toolName) {
      claudeToolNames.set(id, String(chunk.toolName));
    }
    const resolvedToolName = chunk.toolName || claudeToolNames.get(id) || '';
    const toolName = String(resolvedToolName).toLowerCase();
    if (adapter === 'claude-code' && chunk.type === 'tool-input-available' && toolName === 'todowrite') {
      replaceTaskPlan({ tasks: chunk.input?.todos, source: 'TodoWrite' });
      return;
    }
    if (adapter === 'claude-code' && chunk.type === 'tool-input-available' && toolName === 'taskcreate' && id) {
      const input = chunk.input && typeof chunk.input === 'object' ? chunk.input : {};
      const taskId = String(++claudeTaskSequence);
      claudeTaskCreates.set(id, taskId);
      claudeTasks.set(taskId, {
        id: taskId,
        content: input.subject || input.description || `Task ${taskId}`,
        activeForm: input.activeForm,
        status: 'pending',
      });
      emitClaudeTasks();
      return;
    }
    if (adapter === 'claude-code' && chunk.type === 'tool-output-available' && toolName === 'taskcreate' && id) {
      const provisionalId = claudeTaskCreates.get(id);
      const actualId = /Task #(\d+)/i.exec(String(chunk.output || ''))?.[1];
      if (provisionalId && actualId && actualId !== provisionalId) {
        const task = claudeTasks.get(provisionalId);
        claudeTasks.delete(provisionalId);
        if (task) claudeTasks.set(actualId, { ...task, id: actualId });
        emitClaudeTasks();
      }
      return;
    }
    if (adapter === 'claude-code' && chunk.type === 'tool-input-available' && toolName === 'taskupdate') {
      const input = chunk.input && typeof chunk.input === 'object' ? chunk.input : {};
      const taskId = String(input.taskId || '').trim();
      if (!taskId) return;
      const previous = claudeTasks.get(taskId) || { id: taskId, content: `Task ${taskId}`, status: 'pending' };
      claudeTasks.set(taskId, {
        ...previous,
        ...(input.subject ? { content: input.subject } : {}),
        ...(input.activeForm ? { activeForm: input.activeForm } : {}),
        ...(input.status ? { status: input.status } : {}),
        ...(input.blocker || input.reason ? { blocker: input.blocker || input.reason } : {}),
      });
      emitClaudeTasks();
      return;
    }
    if (adapter === 'pi' && chunk.type === 'tool-input-available' && toolName === 'board_task_plan') {
      replaceTaskPlan({ tasks: chunk.input?.tasks, explanation: chunk.input?.explanation, source: 'board_task_plan' });
      return;
    }
    if (adapter !== 'claude-code') return;
    if (toolName !== 'agent' && toolName !== 'task') return;
    if (!id) return;
    if (chunk.type === 'tool-input-available') {
      const input = chunk.input && typeof chunk.input === 'object' ? chunk.input : {};
      upsert(id, {
        parentToolCallId: id,
        name: input.description || input.name || input.subagent_type || 'Subagent',
        agentType: input.subagent_type || resolvedToolName || 'Agent',
        description: input.description || '',
        task: input.prompt || input.task || '',
        status: 'running',
      });
    } else if (chunk.type === 'tool-output-available') {
      upsert(id, {
        status: 'completed',
        recentOutput: compactLines(chunk.output),
      });
    } else if (chunk.type === 'tool-output-error') {
      upsert(id, {
        status: 'failed',
        error: chunk.errorText || 'Subagent failed',
      });
    }
  }

  function consumeOMPEnvelope(envelope) {
    if (adapter !== 'omp-acp' && provider !== 'omp') return;
    if (!envelope || typeof envelope !== 'object') return;
    const payload = envelope.payload;
    if (!payload || typeof payload !== 'object') return;
    if (envelope.kind === 'task-plan') {
      replaceTaskPlan({
        phases: payload.phases,
        tasks: payload.tasks,
        explanation: payload.explanation,
        state: payload.state || 'active',
        source: payload.source || 'todo',
      });
      return;
    }
    if (envelope.kind === 'task-plan-clear') {
      finishTaskPlan('completed');
      return;
    }
    if (envelope.kind === 'lifecycle') {
      const status = payload.status === 'started' ? 'running' : payload.status;
      upsert(payload.id, {
        parentToolCallId: payload.parentToolCallId || '',
        name: payload.description || payload.agent || 'Subagent',
        agentType: payload.agent || '',
        agentSource: payload.agentSource || '',
        description: payload.description || '',
        status,
        detached: Boolean(payload.detached),
        transcriptAvailable: Boolean(payload.sessionFile),
      }, { force: terminalStatuses.has(status) });
      return;
    }
    if (envelope.kind !== 'progress') return;
    const progress = payload.progress && typeof payload.progress === 'object' ? payload.progress : {};
    const retryState = progress.retryState && typeof progress.retryState === 'object' ? progress.retryState : undefined;
    const retryFailure = progress.retryFailure && typeof progress.retryFailure === 'object' ? progress.retryFailure : undefined;
    const status = progress.status || 'running';
    upsert(progress.id || payload.id, {
      parentToolCallId: payload.parentToolCallId || '',
      name: progress.description || payload.description || payload.agent || progress.agent || 'Subagent',
      agentType: payload.agent || progress.agent || '',
      agentSource: payload.agentSource || progress.agentSource || '',
      description: progress.description || payload.description || '',
      task: payload.task || progress.task || '',
      assignment: payload.assignment || progress.assignment || '',
      status,
      detached: Boolean(payload.detached),
      model: progress.resolvedModel || '',
      activity: progress.lastIntent || progress.currentTool || '',
      currentTool: progress.currentTool || '',
      currentToolArgs: progress.currentToolArgs || '',
      toolCount: Number(progress.toolCount) || 0,
      requests: Number(progress.requests) || 0,
      tokens: Number(progress.tokens) || 0,
      contextTokens: Number(progress.contextTokens) || 0,
      contextWindow: Number(progress.contextWindow) || 0,
      cost: Number(progress.cost) || 0,
      durationMs: Number(progress.durationMs) || 0,
      recentOutput: Array.isArray(progress.recentOutput) ? progress.recentOutput.slice(-5).map(String) : [],
      transcriptAvailable: Boolean(payload.sessionFile),
      ...(retryState ? { retry: `Retry ${retryState.attempt}/${retryState.maxAttempts}: ${retryState.errorMessage || 'provider unavailable'}` } : {}),
      ...(retryFailure ? { error: retryFailure.errorMessage || 'Provider retries exhausted' } : {}),
    }, { force: terminalStatuses.has(status) });
  }

  function consumeHarnessEvent(event) {
    if (!event || event.type !== 'raw' || !event.rawValue || typeof event.rawValue !== 'object') return;
    const raw = event.rawValue;
    if ((adapter === 'omp-acp' || provider === 'omp') && raw.sessionUpdate === 'plan') {
      if (!Array.isArray(raw.entries) || raw.entries.length === 0) {
        finishTaskPlan('completed');
        return;
      }
      replaceTaskPlan({ tasks: raw.entries, source: 'acp-plan' });
      return;
    }
    const item = raw.item && typeof raw.item === 'object' ? raw.item : undefined;
    if (adapter === 'codex' && item?.type === 'todo_list') {
      const items = Array.isArray(item.items) ? item.items : [];
      const firstIncomplete = items.findIndex(task => !task?.completed);
      replaceTaskPlan({
        tasks: items.map((task, index) => ({
          id: task?.id,
          content: task?.text,
          status: task?.completed ? 'completed' : index === firstIncomplete ? 'in_progress' : 'pending',
        })),
        source: 'todo_list',
      });
    }
  }

  function consumeBoardTaskPlan(input) {
    replaceTaskPlan({ tasks: input?.tasks, explanation: input?.explanation, source: 'board_task_plan' });
    return { accepted: true, revision: taskPlanRevision };
  }

  function finalize(status) {
    for (const subagent of subagents.values()) {
      if (!terminalStatuses.has(subagent.status)) upsert(subagent.id, { status }, { force: true });
    }
  }

  return { consumeUIChunk, consumeOMPEnvelope, consumeHarnessEvent, consumeBoardTaskPlan, finishTaskPlan, finalize };
}

const codexTodoNeedle = `    if (item.type === "agent_message" && typeof item.text === "string") {`;
const codexTodoForwarder = `    if (item.type === "todo_list") {
      send({ type: "raw", rawValue: event });
      observeStep();
      return;
    }
${codexTodoNeedle}`;

function patchCodexBridge(content) {
  if (content.includes('send({ type: "raw", rawValue: event });')) return content;
  if (!content.includes(codexTodoNeedle)) throw new Error('Dieter could not find the Codex todo bridge insertion point');
  return content.replace(codexTodoNeedle, codexTodoForwarder);
}

/** Observe native harness events before HarnessAgent converts them to AI SDK UI chunks. */
export function observeHarnessCapabilities(harness, collector) {
  const observed = {
    ...harness,
    async doStart(options) {
      const session = await harness.doStart(options);
      return new Proxy(session, {
        get(target, property, receiver) {
          if (property === 'doPromptTurn' || property === 'doContinueTurn') {
            return turnOptions => {
              const emit = createTerminalStepReconciler(event => {
                collector.consumeHarnessEvent(event);
                turnOptions.emit(event);
              });
              return target[property]({ ...turnOptions, emit });
            };
          }
          const value = Reflect.get(target, property, receiver);
          return typeof value === 'function' ? value.bind(target) : value;
        },
      });
    },
  };
  if (harness.harnessId === 'codex' && harness.getBootstrap) {
    observed.getBootstrap = async options => {
      const recipe = await harness.getBootstrap(options);
      return {
        ...recipe,
        files: recipe.files.map(file => file.path.endsWith('/bridge.mjs') ? { ...file, content: patchCodexBridge(file.content) } : file),
      };
    };
  }
  return observed;
}

function createCapabilityEventCoalescer() {
  const result = [];
  const pendingProgress = new Map();
  let progressSequence = 0;

  function flushProgress() {
    for (const { event } of [...pendingProgress.values()].sort((left, right) => left.sequence - right.sequence)) result.push(event);
    pendingProgress.clear();
  }

  function consume(event) {
    if (event?.kind === 'progress') {
      const id = event.payload?.progress?.id || event.payload?.id;
      if (!id) {
        flushProgress();
        result.push(event);
        return;
      }
      if (!pendingProgress.has(id)) progressSequence += 1;
      pendingProgress.set(id, { event, sequence: pendingProgress.get(id)?.sequence || progressSequence });
      return;
    }
    flushProgress();
    result.push(event);
  }

  return {
    consume,
    finish() {
      flushProgress();
      return result;
    },
  };
}

export function coalesceCapabilityEvents(events) {
  const coalescer = createCapabilityEventCoalescer();
  for (const event of events) coalescer.consume(event);
  return coalescer.finish();
}

export function createNDJSONTailer(path, consume, intervalMs = 40) {
  let offset = 0;
  let remainder = '';
  let pending = Promise.resolve();
  let timer;
  let stopped = false;
  let failure;

  async function readNewLines() {
    let file;
    try {
      file = await open(path, 'r');
    } catch (error) {
      if (error?.code === 'ENOENT') return;
      throw error;
    }
    try {
      const { size } = await file.stat();
      if (size < offset) {
        offset = 0;
        remainder = '';
      }
      if (size === offset) return;
      const coalescer = createCapabilityEventCoalescer();
      while (offset < size) {
        const bytes = Buffer.allocUnsafe(Math.min(tailerReadChunkBytes, size - offset));
        const result = await file.read(bytes, 0, bytes.length, offset);
        if (result.bytesRead === 0) break;
        offset += result.bytesRead;
        const text = remainder + bytes.subarray(0, result.bytesRead).toString('utf8');
        const lines = text.split('\n');
        remainder = lines.pop() || '';
        for (const line of lines) {
          if (!line.trim()) continue;
          try { coalescer.consume(JSON.parse(line)); } catch {}
        }
      }
      for (const event of coalescer.finish()) consume(event);
    } finally {
      await file.close();
    }
  }

  function poll() {
    if (stopped) return;
    pending = readNewLines()
      .catch(error => {
        failure = error;
        stopped = true;
      })
      .finally(() => {
        if (!stopped) {
          timer = setTimeout(poll, intervalMs);
          timer.unref?.();
        }
      });
  }

  timer = setTimeout(poll, intervalMs);
  timer.unref?.();
  return {
    async drain() {
      stopped = true;
      clearTimeout(timer);
      await pending;
      if (failure) throw failure;
      await readNewLines();
      if (remainder.trim()) {
        try { consume(JSON.parse(remainder)); } catch {}
        remainder = '';
      }
    },
  };
}
