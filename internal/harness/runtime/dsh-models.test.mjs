import assert from 'node:assert/strict';
import test from 'node:test';
import { parseDSHModelOptions } from './dsh-models.mjs';

test('projects DSH grouped ACP model options and orders the current route first', () => {
  const models = parseDSHModelOptions([{
    id: 'model',
    type: 'select',
    currentValue: '["local","small"]',
    options: [{
      group: 'local',
      name: 'Local inference',
      options: [
        { value: '["local","large"]', name: 'Large' },
        { value: '["local","small"]', name: 'Small' },
      ],
    }],
  }]);
  assert.deepEqual(models, [
    { id: 'local/small', name: 'Small · Local inference', runtimeModel: '["local","small"]', current: true },
    { id: 'local/large', name: 'Large · Local inference', runtimeModel: '["local","large"]', current: false },
  ]);
});

test('rejects missing or malformed DSH model catalogs', () => {
  assert.throws(() => parseDSHModelOptions([]), /standard ACP model option/);
  assert.throws(() => parseDSHModelOptions([{
    id: 'model', type: 'select', currentValue: '', options: [{ value: 'not-json', name: 'Broken' }],
  }]), /no usable ACP model values/);
});

test('ignores duplicate, empty, and non-route values', () => {
  assert.deepEqual(parseDSHModelOptions([{
    id: 'model',
    type: 'select',
    currentValue: '["configured","model"]',
    options: [
      { value: '["configured","model"]', name: 'Configured' },
      { value: '["configured","model"]', name: 'Duplicate' },
      { value: '["configured",""]', name: 'Empty model' },
      { value: '{"provider":"configured","model":"object"}', name: 'Wrong shape' },
      { value: '["configured","unnamed"]', name: ' ' },
    ],
  }]), [{
    id: 'configured/model',
    name: 'Configured · configured',
    runtimeModel: '["configured","model"]',
    current: true,
  }]);
});
