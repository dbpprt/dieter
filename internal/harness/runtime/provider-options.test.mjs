import assert from 'node:assert/strict';
import test from 'node:test';
import { ompACPArgs } from './provider-options.mjs';

test('adds the OMP advisor flag only when the provider option is enabled', () => {
  assert.deepEqual(ompACPArgs({ effort: 'high', options: { advisor: 'true' } }, '/hook.mjs'), ['acp', '--hook', '/hook.mjs', '--thinking=high', '--advisor']);
  assert.deepEqual(ompACPArgs({ options: { advisor: 'false' } }, '/hook.mjs'), ['acp', '--hook', '/hook.mjs']);
});
