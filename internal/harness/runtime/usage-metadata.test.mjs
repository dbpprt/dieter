import assert from 'node:assert/strict';
import test from 'node:test';
import { createMessageMetadataTracker } from './usage-metadata.mjs';

test('reports current step usage during a turn and preserves cumulative final usage', () => {
  const metadata = createMessageMetadataTracker({ createdAt: '2026-08-30T10:00:00Z', contextWindowTokens: 1000 });
  assert.deepEqual(metadata({ part: { type: 'start' } }), { createdAt: '2026-08-30T10:00:00Z' });
  assert.deepEqual(metadata({ part: { type: 'finish-step', usage: { inputTokens: 300, outputTokens: 20, totalTokens: 320 } } }), {
    createdAt: '2026-08-30T10:00:00Z',
    usage: { inputTokens: 300, outputTokens: 20, totalTokens: 320 },
    contextWindowTokens: 1000,
  });
  assert.deepEqual(metadata({ part: { type: 'finish-step', usage: { inputTokens: 450, outputTokens: 25, totalTokens: 475 } } }).usage.totalTokens, 475);
  const final = metadata({ part: { type: 'finish', totalUsage: { inputTokens: 750, outputTokens: 45, totalTokens: 795 } } });
  assert.equal(final.usage.totalTokens, 475);
  assert.equal(final.totalUsage.totalTokens, 795);
});

test('falls back to cumulative usage when a provider omits step usage', () => {
  const metadata = createMessageMetadataTracker({ createdAt: 'now', contextWindowTokens: 2000 });
  assert.equal(metadata({ part: { type: 'finish-step' } }), undefined);
  const final = metadata({ part: { type: 'finish', totalUsage: { totalTokens: 80 } } });
  assert.equal(final.usage.totalTokens, 80);
});
