import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeOMPDiscovery } from './omp-models.mjs';

test('combines the pinned OMP catalog with its configured default role', () => {
  const model = { selector: 'provider/model', name: 'Model' };
  assert.deepEqual(normalizeOMPDiscovery({ models: [model] }, {
    default: 'provider/model:high',
  }), {
    models: [model],
    defaultModel: 'provider/model:high',
  });
});

test('keeps a usable OMP catalog when role discovery is unavailable', () => {
  const model = { selector: 'provider/model', name: 'Model' };
  assert.deepEqual(normalizeOMPDiscovery({ models: [model] }), { models: [model] });
  assert.throws(() => normalizeOMPDiscovery({ models: [] }), /catalog is empty/);
});
