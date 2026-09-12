import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { createBackgroundProcessTools, createProcessHostBridge } from './background-processes.mjs';

test('background tools bind conversation identity and keep exact argv with stable admission keys', async () => {
  const calls = [];
  const tools = createBackgroundProcessTools({ sessionId: 'owner', responseMessageId: 'turn' }, async (operation, input) => {
    calls.push({ operation, input }); return { id: 'registered', status: 'running' };
  });
  const args = { argv: ['printf', '%s', 'literal $() ; |'], name: 'Preview' };
  assert.equal(tools.start_background_process.inputSchema.safeParse({ ...args, cardId: 'other' }).success, false);
  const first = await tools.start_background_process.execute(args, { toolCallId: 'call' });
  await tools.start_background_process.execute(args, { toolCallId: 'call' });
  assert.equal(first.id, 'registered');
  assert.deepEqual(calls[0].input.argv, args.argv);
  assert.equal(calls[0].input.idempotencyKey, calls[1].input.idempotencyKey);
  await tools.stop_background_process.execute({ executionId: 'registered' });
  assert.equal(calls[2].operation, 'stop');
});

test('private host bridge correlates replies, bounds pending calls, and rejects on disposal', async () => {
  const input = new EventEmitter(); const sent = [];
  const bridge = createProcessHostBridge(input, value => sent.push(value));
  const response = bridge.call('start', { argv: ['echo'] });
  input.emit('line', JSON.stringify({ type: 'background-process-result', id: sent[0].processCall.id, result: { id: 'real-execution' } }));
  assert.deepEqual(await response, { id: 'real-execution' });
  const one = bridge.call('read', { executionId: 'one' });
  const two = bridge.call('read', { executionId: 'two' });
  input.emit('line', JSON.stringify({ type: 'background-process-result', id: sent[2].processCall.id, result: { id: 'two' } }));
  input.emit('line', JSON.stringify({ type: 'background-process-result', id: sent[1].processCall.id, result: { id: 'one' } }));
  assert.deepEqual(await Promise.all([one, two]), [{ id: 'one' }, { id: 'two' }]);
  const pending = Array.from({ length: 8 }, () => bridge.call('list', {}).catch(error => error.message));
  await assert.rejects(bridge.call('list', {}), /Too many/);
  bridge.dispose();
  assert.ok((await Promise.all(pending)).every(message => /disconnected/.test(message)));
});
