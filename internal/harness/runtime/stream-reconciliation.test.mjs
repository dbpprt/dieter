import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { HarnessAgent } from '@ai-sdk/harness/agent';
import { tool } from 'ai';
import { z } from 'zod';
import { observeHarnessCapabilities } from './capabilities.mjs';
import { createLocalSandboxProvider } from './local-sandbox.mjs';
import { createTerminalStepReconciler } from './stream-reconciliation.mjs';

const finish = {
  type: 'finish',
  finishReason: { unified: 'stop', raw: 'stop' },
  totalUsage: {
    inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
    outputTokens: { total: 5, text: 5 },
  },
};

test('detaches unresolved provider-executed tools before terminal finish', () => {
  const events = [];
  const emit = createTerminalStepReconciler(event => events.push(event));
  emit({ type: 'tool-call', toolCallId: 'process-1', toolName: 'bash', input: '{}', providerExecuted: true });
  emit({ type: 'text-start', id: 'answer' });
  emit({ type: 'text-delta', id: 'answer', delta: 'Done.' });
  emit({ type: 'text-end', id: 'answer' });
  emit(finish);

  assert.deepEqual(events.map(event => event.type), [
    'tool-call', 'text-start', 'text-delta', 'text-end',
    'tool-result', 'finish-step', 'finish',
  ]);
  assert.deepEqual(events[4].result, {
    status: 'running',
    detached: true,
    output: 'The external process was left running after the agent turn completed.',
  });
});

test('does not synthesize a result for a completed provider tool', () => {
  const events = [];
  const emit = createTerminalStepReconciler(event => events.push(event));
  emit({ type: 'tool-call', toolCallId: 'tool-1', toolName: 'bash', input: '{}', providerExecuted: true });
  emit({ type: 'tool-result', toolCallId: 'tool-1', toolName: 'bash', result: { status: 'completed' } });
  emit({ type: 'finish-step', finishReason: finish.finishReason, usage: finish.totalUsage });
  emit(finish);

  assert.deepEqual(events.map(event => event.type), ['tool-call', 'tool-result', 'finish-step', 'finish']);
});

test('does not detach host-executed tools', () => {
  const events = [];
  const emit = createTerminalStepReconciler(event => events.push(event));
  emit({ type: 'tool-call', toolCallId: 'host-1', toolName: 'custom', input: '{}', providerExecuted: false });
  emit(finish);

  assert.equal(events.some(event => event.type === 'tool-result'), false);
});

test('closes trailing content from any provider before terminal finish', () => {
  const events = [];
  const emit = createTerminalStepReconciler(event => events.push(event));
  emit({ type: 'text-start', id: 'answer' });
  emit({ type: 'text-delta', id: 'answer', delta: 'Done.' });
  emit({ type: 'text-end', id: 'answer' });
  emit(finish);

  assert.deepEqual(events.map(event => event.type), [
    'text-start', 'text-delta', 'text-end', 'finish-step', 'finish',
  ]);
});

test('wraps every supported provider session with terminal reconciliation', async () => {
  for (const harnessId of ['codex', 'claude-code', 'pi', 'omp', 'dsh']) {
    const events = [];
    const harness = {
      specificationVersion: 'harness-v1',
      harnessId,
      builtinTools: {},
      async doStart() {
        return {
          async doPromptTurn(options) {
            options.emit({ type: 'tool-call', toolCallId: `${harnessId}-process`, toolName: 'bash', input: '{}', providerExecuted: true });
            options.emit(finish);
            return { done: Promise.resolve() };
          },
        };
      },
    };
    const observed = observeHarnessCapabilities(harness, { consumeHarnessEvent: event => events.push(event) });
    const session = await observed.doStart({});
    await session.doPromptTurn({ emit() {} });

    assert.deepEqual(events.map(event => event.type), ['tool-call', 'tool-result', 'finish-step', 'finish'], harnessId);
    assert.equal(events[1].result.detached, true, harnessId);
  }
});

test('HarnessAgent accepts a completed turn with a detached provider process', async () => {
  const root = await mkdtemp(join(tmpdir(), 'board-terminal-reconcile-'));
  const builtinTools = {
    bash: tool({
      description: 'Execute a shell command',
      inputSchema: z.object({ command: z.string() }),
    }),
  };
  const baseHarness = {
    specificationVersion: 'harness-v1',
    harnessId: 'integration-test',
    builtinTools,
    async doStart({ sessionId }) {
      return {
        sessionId,
        isResume: false,
        modelId: 'test-model',
        async doPromptTurn(options) {
          options.emit({ type: 'stream-start', modelId: 'test-model' });
          options.emit({ type: 'tool-call', toolCallId: 'server', toolName: 'bash', input: JSON.stringify({ command: 'start-server' }), providerExecuted: true });
          options.emit({ type: 'text-start', id: 'answer' });
          options.emit({ type: 'text-delta', id: 'answer', delta: 'The server is running.' });
          options.emit({ type: 'text-end', id: 'answer' });
          options.emit(finish);
          return { done: Promise.resolve() };
        },
        async doStop() {
          return {
            type: 'resume-session',
            harnessId: 'integration-test',
            specificationVersion: 'harness-v1',
            data: {},
          };
        },
      };
    },
  };
  const harness = observeHarnessCapabilities(baseHarness, { consumeHarnessEvent() {} });
  const sandbox = await createLocalSandboxProvider({ root, projectPath: process.cwd() });
  const agent = new HarnessAgent({ harness, sandbox, permissionMode: 'allow-all' });

  try {
    const session = await agent.createSession({ sessionId: 'terminal-reconcile-test' });
    const result = await agent.generate({ session, prompt: 'Start the server' });
    assert.equal(result.text, 'The server is running.');
    assert.equal(result.finishReason, 'stop');
    await session.stop();
  } finally {
    await sandbox.stopAll();
    await rm(root, { recursive: true, force: true });
  }
});
