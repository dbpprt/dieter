import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { VERSION as acpPackageVersion, createACP } from '@ai-sdk/harness-acp';
import {
  acpImplementationIdentity,
  createOMPSessionWithCompatibility,
  isACPImplementationMismatch,
  prepareOMPHookPaths,
  prioritizeOMPHookPaths,
} from './omp-resilience.mjs';

const ompSettings = hookPath => ({
  harnessId: 'omp',
  source: {
    type: 'npm-simple',
    packageName: '@oh-my-pi/pi-coding-agent',
    packageVersion: '18.1.10',
  },
  executable: 'omp',
  args: ['acp', '--hook', hookPath, '--thinking=max'],
  modelMapping: { type: 'session-config-option', path: 'model' },
  forwardEnv: ['HOME', 'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'DIETER_OMP_CAPABILITY_FILE'],
});

test('stages OMP hooks under a content-derived path and discovers legacy runtime paths', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dieter-omp-resilience-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const harnessRoot = join(root, 'harness');
  const currentRoot = join(harnessRoot, '1111111111111111');
  const legacyRoot = join(harnessRoot, '2222222222222222');
  const ignoredRoot = join(harnessRoot, 'not-a-runtime');
  const runtimeRoot = join(root, 'project-runtime');
  await Promise.all([currentRoot, legacyRoot, ignoredRoot].map(path => mkdir(path, { recursive: true })));
  const currentHookPath = join(currentRoot, 'omp-capabilities-hook.mjs');
  const legacyHookPath = join(legacyRoot, 'omp-capabilities-hook.mjs');
  await writeFile(currentHookPath, 'export default () => {}\n');
  await writeFile(legacyHookPath, 'export default () => {}\n');
  await writeFile(join(ignoredRoot, 'omp-capabilities-hook.mjs'), 'ignored\n');
  await symlink(legacyHookPath, join(harnessRoot, '3333333333333333'));
  const stableRoot = join(runtimeRoot, 'harness-hooks');
  await mkdir(stableRoot, { recursive: true });
  const tamperedStableHook = join(stableRoot, `omp-capabilities-${'0'.repeat(64)}.mjs`);
  await writeFile(tamperedStableHook, 'content does not match its name\n');

  const paths = await prepareOMPHookPaths({ runtimeRoot, currentHookPath });
  assert.match(paths[0], /project-runtime\/harness-hooks\/omp-capabilities-[a-f0-9]{64}\.mjs$/);
  assert.equal(await readFile(paths[0], 'utf8'), 'export default () => {}\n');
  assert.deepEqual(paths.slice(1).sort(), [currentHookPath, legacyHookPath].sort());
  assert.equal(paths.includes(tamperedStableHook), false);

  const repeated = await prepareOMPHookPaths({ runtimeRoot, currentHookPath });
  assert.equal(repeated[0], paths[0]);

  const nextRuntimeRoot = join(harnessRoot, '4444444444444444');
  const nextHookPath = join(nextRuntimeRoot, 'omp-capabilities-hook.mjs');
  await mkdir(nextRuntimeRoot, { recursive: true });
  await writeFile(nextHookPath, 'export default () => {}\n');
  const moved = await prepareOMPHookPaths({ runtimeRoot, currentHookPath: nextHookPath });
  assert.equal(moved[0], paths[0]);
});

test('changes the stable OMP hook identity only when hook content changes', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dieter-omp-hook-content-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const currentRoot = join(root, 'harness', '1111111111111111');
  const runtimeRoot = join(root, 'project-runtime');
  const currentHookPath = join(currentRoot, 'omp-capabilities-hook.mjs');
  await mkdir(currentRoot, { recursive: true });
  await writeFile(currentHookPath, 'first\n');
  const first = await prepareOMPHookPaths({ runtimeRoot, currentHookPath });
  await writeFile(currentHookPath, 'second\n');
  const second = await prepareOMPHookPaths({ runtimeRoot, currentHookPath });
  assert.notEqual(first[0], second[0]);
  assert.equal(second.includes(first[0]), true);
});

test('retries an ACP implementation mismatch with a legacy OMP hook path', async () => {
  const attempts = [];
  const fallbacks = [];
  const expectedSession = { id: 'resumed' };
  const result = await createOMPSessionWithCompatibility({
    hookPaths: ['/stable/hook.mjs', '/legacy/hook.mjs'],
    createAgent: hookPath => ({
      async createSession(options) {
        attempts.push({ hookPath, options });
        if (hookPath.startsWith('/stable')) {
          throw new Error('ACP lifecycle state is incompatible with the configured implementation.');
        }
        return expectedSession;
      },
    }),
    sessionOptions: { sessionId: 'card' },
    onFallback: hookPath => fallbacks.push(hookPath),
  });
  assert.equal(result.session, expectedSession);
  assert.equal(result.hookPath, '/legacy/hook.mjs');
  assert.deepEqual(attempts.map(attempt => attempt.hookPath), ['/stable/hook.mjs', '/legacy/hook.mjs']);
  assert.deepEqual(fallbacks, ['/legacy/hook.mjs']);
});

test('preselects the legacy path matching the persisted ACP implementation identity', async () => {
  const legacyHookPath = '/runtime/harness/old/omp-capabilities-hook.mjs';
  const lifecycleState = {
    data: {
      implementationIdentity: acpImplementationIdentity({
        settings: ompSettings(legacyHookPath),
        acpPackageVersion,
      }),
    },
  };
  assert.deepEqual(prioritizeOMPHookPaths({
    hookPaths: ['/runtime/stable/omp-capabilities-new.mjs', '/runtime/current/omp-capabilities-hook.mjs', legacyHookPath],
    lifecycleState,
    settingsForHook: ompSettings,
    acpPackageVersion,
  }), [legacyHookPath, '/runtime/stable/omp-capabilities-new.mjs', '/runtime/current/omp-capabilities-hook.mjs']);
});

test('matches the implementation identity contract of the pinned ACP runtime', async () => {
  const hookPath = '/runtime/harness/old/omp-capabilities-hook.mjs';
  const implementationIdentity = acpImplementationIdentity({ settings: ompSettings(hookPath), acpPackageVersion });
  const lifecycleState = {
    type: 'resume-session',
    harnessId: 'omp',
    specificationVersion: 'harness-v1',
    data: {
      implementationIdentity,
      authenticationProfile: { digest: 'deliberately-wrong' },
    },
  };
  const sandboxSession = {
    id: 'identity-contract-test',
    description: 'identity contract test sandbox',
    defaultWorkingDirectory: '/tmp',
    ports: [43210],
    getPortEndpoint: async () => ({ url: 'ws://127.0.0.1:43210' }),
    restricted() { return this; },
  };
  await assert.rejects(() => createACP(ompSettings(hookPath)).doStart({
    sessionId: 'identity-contract-test',
    resumeFrom: lifecycleState,
    sandboxSession,
    sessionWorkDir: '/tmp',
  }), /configured authentication profile/);
  await assert.rejects(() => createACP(ompSettings('/different/hook.mjs')).doStart({
    sessionId: 'identity-contract-test',
    resumeFrom: lifecycleState,
    sandboxSession,
    sessionWorkDir: '/tmp',
  }), /configured implementation/);
});

test('does not mask or retry unrelated session creation failures', async () => {
  let attempts = 0;
  await assert.rejects(() => createOMPSessionWithCompatibility({
    hookPaths: ['/stable/hook.mjs', '/legacy/hook.mjs'],
    createAgent: () => ({
      async createSession() {
        attempts += 1;
        throw new Error('authentication failed');
      },
    }),
    sessionOptions: {},
  }), /authentication failed/);
  assert.equal(attempts, 1);
  assert.equal(isACPImplementationMismatch(new Error('authentication failed')), false);
});
