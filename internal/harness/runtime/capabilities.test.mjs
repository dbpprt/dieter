import assert from 'node:assert/strict';
import { appendFile, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createNDJSONTailer, createSubagentCapabilityCollector, observeHarnessCapabilities } from './capabilities.mjs';

test('normalizes Claude Agent tool lifecycle', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'claude-code', messageId: 'm1', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'agent-1', toolName: 'Agent', input: { description: 'Inspect tests', prompt: 'Find the failure', subagent_type: 'Explore' } });
  // AI SDK output chunks omit toolName; retain it from the input event.
  collector.consumeUIChunk({ type: 'tool-output-available', toolCallId: 'agent-1', output: 'Found it' });
  assert.equal(events.length, 2);
  assert.deepEqual(events[0].subagent, { id: 'agent-1', provider: 'claude-code', messageId: 'm1', status: 'running', startedAt: '2026-08-15T10:00:00Z', parentToolCallId: 'agent-1', name: 'Inspect tests', agentType: 'Explore', description: 'Inspect tests', task: 'Find the failure', updatedAt: '2026-08-15T10:00:00Z' });
  assert.equal(events[1].subagent.status, 'completed');
  assert.deepEqual(events[1].subagent.recentOutput, ['Found it']);
});

test('normalizes rich OMP progress without exposing its session file', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'omp', messageId: 'm2', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  collector.consumeOMPEnvelope({ kind: 'lifecycle', payload: { id: 'worker-1', status: 'started', agent: 'scout', agentSource: 'bundled', parentToolCallId: 'task-1', sessionFile: '/private/child.jsonl', index: 0 } });
  collector.consumeOMPEnvelope({ kind: 'progress', payload: { agent: 'scout', agentSource: 'bundled', task: 'Inspect the repo', parentToolCallId: 'task-1', sessionFile: '/private/child.jsonl', progress: { id: 'worker-1', status: 'running', description: 'Repository scout', resolvedModel: 'anthropic/sonnet', lastIntent: 'Reading tests', currentTool: 'read', toolCount: 3, requests: 2, tokens: 1200, contextTokens: 800, contextWindow: 200000, cost: 0.03, durationMs: 5000, recentOutput: ['a', 'b'] } } });
  const subagent = events.at(-1).subagent;
  assert.equal(subagent.status, 'running');
  assert.equal(subagent.model, 'anthropic/sonnet');
  assert.equal(subagent.transcriptAvailable, true);
  assert.equal('sessionFile' in subagent, false);
});

test('samples OMP heartbeats at most once per minute', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'omp', adapter: 'omp-acp', messageId: 'm-heartbeat', emit: event => events.push(event), now: () => '2026-08-30T10:00:00Z' });
  collector.consumeOMPEnvelope({ kind: 'lifecycle', payload: { id: 'worker', status: 'started', agent: 'scout' } });
  for (let index = 1; index <= 10_000; index += 1) {
    collector.consumeOMPEnvelope({ kind: 'progress', payload: { id: 'worker', agent: 'scout', task: 'Inspect', progress: {
      id: 'worker', status: 'running', description: 'Repository scout', toolCount: 1, requests: 1,
      tokens: 500, contextTokens: 400, contextWindow: 1000, durationMs: index * 150, recentOutput: [`tick ${index}`],
    } } });
  }
  collector.consumeOMPEnvelope({ kind: 'lifecycle', payload: { id: 'worker', status: 'completed', agent: 'scout' } });
  assert.equal(events.length, 28);
  assert.equal(events[1].subagent.durationMs, 150);
  assert.equal(events.at(-1).subagent.status, 'completed');
  assert.equal(events.at(-1).subagent.durationMs, 1_500_000);
});

test('projects Claude TodoWrite as a versioned task plan', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'claude-code', messageId: 'm3', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'todo-1', toolName: 'TodoWrite', input: { todos: [
    { content: 'Inspect', activeForm: 'Inspecting', status: 'completed' },
    { content: 'Implement', activeForm: 'Implementing', status: 'in_progress' },
  ] } });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'todo-2', toolName: 'TodoWrite', input: { todos: [
    { content: 'Inspect', activeForm: 'Inspecting', status: 'completed' },
    { content: 'Implement', activeForm: 'Implementing', status: 'completed' },
  ] } });
  collector.finishTaskPlan('completed');
  assert.equal(events.length, 3);
  assert.equal(events[0].id, 'task-plan');
  assert.equal(events[0].plan.phases[0].tasks[1].status, 'in_progress');
  assert.equal(events[1].plan.revision, 2);
  assert.equal(events[2].plan.state, 'completed');
});

test('aggregates current Claude TaskCreate and TaskUpdate lifecycle', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'claude-code', messageId: 'm3-tasks', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'create-1', toolName: 'TaskCreate', input: { subject: 'Inspect', activeForm: 'Inspecting' } });
  collector.consumeUIChunk({ type: 'tool-output-available', toolCallId: 'create-1', output: 'Task #1 created successfully: Inspect' });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'create-2', toolName: 'TaskCreate', input: { subject: 'Answer', activeForm: 'Answering' } });
  collector.consumeUIChunk({ type: 'tool-output-available', toolCallId: 'create-2', output: 'Task #2 created successfully: Answer' });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'update-1', toolName: 'TaskUpdate', input: { taskId: '1', status: 'in_progress' } });
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'update-2', toolName: 'TaskUpdate', input: { taskId: '1', status: 'completed' } });
  assert.equal(events.at(-1).plan.phases[0].tasks.length, 2);
  assert.equal(events.at(-1).plan.phases[0].tasks[0].content, 'Inspect');
  assert.equal(events.at(-1).plan.phases[0].tasks[0].status, 'completed');
  assert.equal(events.at(-1).plan.phases[0].tasks[1].status, 'pending');
  assert.equal(events.at(-1).plan.source, 'Tasks');
});

test('preserves OMP phases and richer blocked state over ACP fallback', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'omp', adapter: 'omp-acp', messageId: 'm4', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  collector.consumeOMPEnvelope({ kind: 'task-plan', payload: { source: 'todo', phases: [{ name: 'Delivery', tasks: [{ content: 'Wait for review', status: 'blocked', blocker: 'Reviewer' }] }] } });
  collector.consumeHarnessEvent({ type: 'raw', rawValue: { sessionUpdate: 'plan', entries: [{ content: 'Wait for review', status: 'pending' }] } });
  assert.equal(events.length, 1);
  assert.equal(events[0].plan.phases[0].name, 'Delivery');
  assert.equal(events[0].plan.phases[0].tasks[0].status, 'blocked');
  assert.equal(events[0].plan.phases[0].tasks[0].blocker, 'Reviewer');
});

test('completes the OMP plan when ACP clears it', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'omp', adapter: 'omp-acp', messageId: 'm4-clear', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  collector.consumeHarnessEvent({ type: 'raw', rawValue: { sessionUpdate: 'plan', entries: [{ content: 'Inspect', status: 'completed' }] } });
  collector.consumeHarnessEvent({ type: 'raw', rawValue: { sessionUpdate: 'plan', entries: [] } });
  assert.equal(events.length, 2);
  assert.equal(events[1].plan.state, 'completed');
});

test('observes Codex todo_list before UI conversion and patches its bootstrap bridge', async () => {
  const capabilities = [];
  const forwarded = [];
  const collector = createSubagentCapabilityCollector({ provider: 'custom-codex', adapter: 'codex', messageId: 'm5', emit: event => capabilities.push(event), now: () => '2026-08-15T10:00:00Z' });
  const harness = observeHarnessCapabilities({
    harnessId: 'codex',
    builtinTools: {},
    async getBootstrap() { return { harnessId: 'codex', bootstrapDir: '.x', commands: [], files: [{ path: '.x/bridge.mjs', content: '    if (item.type === "agent_message" && typeof item.text === "string") {' }] }; },
    async doStart() {
      return {
        doPromptTurn(options) {
          options.emit({ type: 'raw', rawValue: { type: 'item.updated', item: { type: 'todo_list', items: [{ text: 'Inspect', completed: false }, { text: 'Ship', completed: false }] } } });
          return { done: Promise.resolve() };
        },
      };
    },
  }, collector);
  const recipe = await harness.getBootstrap();
  assert.match(recipe.files[0].content, /item\.type === "todo_list"/);
  const session = await harness.doStart({});
  session.doPromptTurn({ emit: event => forwarded.push(event) });
  assert.equal(forwarded.length, 1);
  assert.equal(capabilities[0].plan.phases[0].tasks[0].status, 'in_progress');
  assert.equal(capabilities[0].plan.phases[0].tasks[1].status, 'pending');
});

test('supports the Pi host task-plan tool without duplicate snapshots', () => {
  const events = [];
  const collector = createSubagentCapabilityCollector({ provider: 'pi', messageId: 'm6', emit: event => events.push(event), now: () => '2026-08-15T10:00:00Z' });
  const input = { explanation: 'Two steps', tasks: [{ content: 'Inspect', status: 'in_progress' }, { content: 'Answer', status: 'pending' }] };
  const result = collector.consumeBoardTaskPlan(input);
  collector.consumeUIChunk({ type: 'tool-input-available', toolCallId: 'plan-1', toolName: 'board_task_plan', input });
  assert.equal(result.accepted, true);
  assert.equal(events.length, 1);
  assert.equal(events[0].plan.source, 'board_task_plan');
});

test('tails complete NDJSON events', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'board-capabilities-'));
  try {
    const path = join(dir, 'events.ndjson');
    await writeFile(path, '');
    const events = [];
    const tailer = createNDJSONTailer(path, event => events.push(event), 1000);
    await writeFile(path, '{"kind":"lifecycle","payload":{"id":"one"}}\n');
    await tailer.drain();
    assert.equal(events[0].payload.id, 'one');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('drains a large OMP backlog incrementally and coalesces adjacent progress', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'board-capabilities-load-'));
  try {
    const path = join(dir, 'events.ndjson');
    const task = 'Review the repository carefully. '.repeat(80);
    const records = [JSON.stringify({ kind: 'lifecycle', payload: { id: 'worker', status: 'started', agent: 'scout' } })];
    for (let index = 1; index <= 12_000; index += 1) {
      records.push(JSON.stringify({ kind: 'progress', payload: { id: 'worker', task, progress: { id: 'worker', status: 'running', toolCount: index, durationMs: index * 150 } } }));
    }
    records.push(JSON.stringify({ kind: 'lifecycle', payload: { id: 'worker', status: 'completed', agent: 'scout' } }));
    await writeFile(path, `${records.join('\n')}\n`);
    const events = [];
    const tailer = createNDJSONTailer(path, event => events.push(event), 1000);
    await tailer.drain();
    assert.equal(events.length, 3);
    assert.equal(events[1].payload.progress.toolCount, 12_000);
    assert.equal(events[2].payload.status, 'completed');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('tails appended records without replaying earlier bytes', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'board-capabilities-append-'));
  try {
    const path = join(dir, 'events.ndjson');
    await writeFile(path, '{"kind":"lifecycle","payload":{"id":"one"}}\n');
    const events = [];
    const tailer = createNDJSONTailer(path, event => events.push(event), 10);
    await new Promise(resolve => setTimeout(resolve, 30));
    await appendFile(path, '{"kind":"lifecycle","payload":{"id":"two"}}\n');
    await tailer.drain();
    assert.deepEqual(events.map(event => event.payload.id), ['one', 'two']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
