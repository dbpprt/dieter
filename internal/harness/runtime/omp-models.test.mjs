import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeOMPDiscovery, ompVisibleModelSelectors } from './omp-models.mjs';

test('combines the pinned OMP catalog with its configured default role', () => {
  const model = { selector: 'openai-codex/gpt-6-sol', name: 'GPT-6 Sol' };
  const normalized = normalizeOMPDiscovery({ models: [model] }, {
    default: 'openai-codex/gpt-6-sol:high',
  });
  assert.deepEqual(normalized.models.map(item => item.selector), ompVisibleModelSelectors);
  assert.equal(normalized.models[2], model);
  assert.equal(normalized.defaultModel, 'openai-codex/gpt-6-sol:high');
});

test('keeps a usable OMP catalog when role discovery is unavailable', () => {
  const model = { selector: 'openai-codex/gpt-6-astra', name: 'GPT-6 Astra' };
  const normalized = normalizeOMPDiscovery({ models: [model] });
  assert.deepEqual(normalized.models.map(item => item.selector), ompVisibleModelSelectors);
  assert.equal(normalized.models[3], model);
  assert.throws(() => normalizeOMPDiscovery({ models: [] }), /catalog is empty/);
});

test('publishes only the curated selectors in stable order', () => {
  const catalog = [
    { selector: 'openrouter/other/model', name: 'Other' },
    ...[...ompVisibleModelSelectors].reverse().map(selector => ({ selector, name: selector })),
  ];
  const normalized = normalizeOMPDiscovery({ models: catalog }, { default: 'openrouter/other/model' });
  assert.deepEqual(normalized.models.map(model => model.selector), ompVisibleModelSelectors);
  assert.equal(normalized.defaultModel, undefined);
});

test('fills unavailable curated routes from the stable Dieter catalog', () => {
  const normalized = normalizeOMPDiscovery({ models: [{ selector: 'openrouter/other/model' }] });
  assert.deepEqual(normalized.models.map(model => model.selector), ompVisibleModelSelectors);
  assert.equal(normalized.models[0].contextWindow, 1_000_000);
});
