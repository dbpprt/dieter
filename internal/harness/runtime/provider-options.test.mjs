import assert from 'node:assert/strict';
import test from 'node:test';
import {
  dshACPArgs,
  dshPackageVersion,
  ompACPArgs,
  ompACPModelMapping,
} from './provider-options.mjs';

test('maps the selected Dieter model to the OMP ACP model option', () => {
  assert.deepEqual(ompACPModelMapping, {
    type: 'session-config-option',
    path: 'model',
  });
});
test('adds the OMP advisor flag only when the provider option is enabled', () => {
  assert.deepEqual(ompACPArgs({ effort: 'high', options: { advisor: 'true' } }, '/hook.mjs'), ['acp', '--hook', '/hook.mjs', '--thinking=high', '--advisor']);
  assert.deepEqual(ompACPArgs({ options: { advisor: 'false' } }, '/hook.mjs'), ['acp', '--hook', '/hook.mjs']);
});

test('builds a pinned DSH ACP launch without overriding DSH configuration', () => {
  assert.equal(dshPackageVersion, '0.1.2-rc.1');
  assert.deepEqual(dshACPArgs(), ['--profile', 'acp']);
  assert.deepEqual(dshACPArgs('--patch', '/runtime/discovery.patch.yml'), [
    '--profile', 'acp', '--patch', '/runtime/discovery.patch.yml',
  ]);
});
