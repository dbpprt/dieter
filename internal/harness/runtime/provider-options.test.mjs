import assert from 'node:assert/strict';
import test from 'node:test';
import {
  codexConfig,
  dshACPArgs,
  dshPackageVersion,
  ompACPArgs,
  ompACPModelMapping,
  ompImplementations,
  ompPackageVersion,
  ompPackageVersions,
  ompRuntimeConfig,
  ompStreamTimeoutSeconds,
} from './provider-options.mjs';
test('maps the mutable Codex Fast mode option to an explicit service tier', () => {
  assert.deepEqual(codexConfig({ options: { fast_mode: 'true' } }), {
    service_tier: 'fast',
    features: { fast_mode: true },
  });
  assert.deepEqual(codexConfig({ options: { fast_mode: 'false' } }), {
    service_tier: 'default',
    features: { fast_mode: true },
  });
  assert.deepEqual(codexConfig({}), {
    service_tier: 'default',
    features: { fast_mode: true },
  });
});

test('retains the OMP ACP model mapping for legacy session resumes', () => {
  assert.deepEqual(ompACPModelMapping, {
    type: 'session-config-option',
    path: 'model',
  });
});
test('pins OMP discovery and turns while retaining bounded session compatibility', () => {
  assert.equal(ompPackageVersion, '18.2.9');
  assert.deepEqual(ompPackageVersions, ['18.2.9', '18.1.10']);
  assert.deepEqual(ompImplementations, [
    { packageVersion: '18.2.9', modelStrategy: 'launch-argument' },
    { packageVersion: '18.1.10', modelStrategy: 'session-config-option' },
  ]);
  assert.equal(Object.isFrozen(ompPackageVersions), true);
  assert.equal(Object.isFrozen(ompImplementations), true);
});
test('adds the OMP advisor flag only when the provider option is enabled', () => {
  assert.deepEqual(ompACPArgs({ effort: 'high', options: { advisor: 'true' } }, '/hook.mjs', '/config.yml'), ['acp', '--config', '/config.yml', '--hook', '/hook.mjs', '--thinking=high', '--advisor']);
  assert.deepEqual(ompACPArgs({ options: { advisor: 'false' } }, '/hook.mjs'), ['acp', '--hook', '/hook.mjs']);
});
test('launches new OMP bridges with the selected model while legacy resumes keep ACP mapping', () => {
  const request = { model: 'openrouter/openai/gpt-6-sol', effort: 'max' };
  assert.deepEqual(ompACPArgs(request, '/hook.mjs', '/config.yml', 'launch-argument'), [
    'acp', '--config', '/config.yml', '--hook', '/hook.mjs', '--thinking=max',
    '--model=openrouter/openai/gpt-6-sol',
  ]);
  assert.equal(ompACPArgs(request, '/hook.mjs', '/config.yml').includes('--model=openrouter/openai/gpt-6-sol'), false);
});

test('gives Dieter OMP turns a thirty-minute first-event and idle watchdog', () => {
  assert.equal(ompStreamTimeoutSeconds, 1800);
  assert.equal(ompRuntimeConfig(), 'providers:\n  streamFirstEventTimeoutSeconds: 1800\n  streamIdleTimeoutSeconds: 1800\n');
});

test('builds a pinned DSH ACP launch without overriding DSH configuration', () => {
  assert.equal(dshPackageVersion, '0.1.2-rc.1');
  assert.deepEqual(dshACPArgs(), ['--profile', 'acp']);
  assert.deepEqual(dshACPArgs('--patch', '/runtime/discovery.patch.yml'), [
    '--profile', 'acp', '--patch', '/runtime/discovery.patch.yml',
  ]);
});
