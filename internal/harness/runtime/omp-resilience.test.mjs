import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { VERSION as acpPackageVersion, createACP } from '@ai-sdk/harness-acp';
import {
  acpImplementationIdentity,
  createOMPLaunchCandidates,
  createOMPSessionWithBootstrapRetry,
  createOMPSessionWithCompatibility,
  isACPImplementationMismatch,
  isOMPBootstrapVersionUnavailable,
  prepareOMPConfig,
  prepareOMPHookPaths,
  prioritizeOMPLaunchCandidates,
} from './omp-resilience.mjs';

const ompBootstrapError = (packageName = 'pi-coding-agent', version = '18.2.11') => new Error(
  `Bootstrap command failed for harness 'omp' (exit 1): npm install\nnpm error code ETARGET\nnpm error notarget No matching version found for @oh-my-pi/${packageName}@${version}.`,
);

const ompSettings = (
  hookPath,
  configPath,
  packageVersion = '18.1.10',
  modelStrategy = 'session-config-option',
) => ({
  harnessId: 'omp',
  source: {
    type: 'npm-simple',
    packageName: '@oh-my-pi/pi-coding-agent',
    packageVersion,
  },
  executable: 'omp',
  args: [
    'acp', ...(configPath ? ['--config', configPath] : []), '--hook', hookPath, '--thinking=max',
    ...(modelStrategy === 'launch-argument' ? ['--model=openrouter/openai/gpt-6-sol'] : []),
  ],
  ...(modelStrategy === 'session-config-option'
    ? { modelMapping: { type: 'session-config-option', path: 'model' } }
    : {}),
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
  const candidates = [
    { packageVersion: '18.2.9', modelStrategy: 'launch-argument', hookPath: '/stable/hook.mjs', configPath: '/runtime/omp.yml' },
    { packageVersion: '18.1.10', modelStrategy: 'session-config-option', hookPath: '/legacy/hook.mjs', configPath: undefined },
  ];
  const result = await createOMPSessionWithCompatibility({
    candidates,
    createAgent: candidate => ({
      async createSession(options) {
        attempts.push({ candidate, options });
        if (candidate.hookPath.startsWith('/stable')) {
          throw new Error('ACP lifecycle state is incompatible with the configured implementation.');
        }
        return expectedSession;
      },
    }),
    sessionOptions: { sessionId: 'card' },
    onFallback: candidate => fallbacks.push(candidate),
  });
  assert.equal(result.session, expectedSession);
  assert.deepEqual(result.candidate, candidates[1]);
  assert.deepEqual(attempts.map(attempt => attempt.candidate), candidates);
  assert.deepEqual(fallbacks, [candidates[1]]);
});

test('retries transient OMP root-package and dependency publication gaps', async () => {
  for (const packageName of ['pi-coding-agent', 'omp-stats']) {
    let attempts = 0;
    const waits = [];
    const retries = [];
    const expectedSession = { id: packageName };
    const session = await createOMPSessionWithBootstrapRetry({
      createSession: async options => {
        attempts += 1;
        assert.equal(options.sessionId, 'card');
        if (attempts < 3) throw ompBootstrapError(packageName);
        return expectedSession;
      },
      packageVersion: '18.2.11',
      sessionOptions: { sessionId: 'card' },
      retryDelays: [5, 15, 30],
      waitForRetry: async delayMs => waits.push(delayMs),
      onRetry: retry => retries.push(retry),
    });
    assert.equal(session, expectedSession);
    assert.equal(attempts, 3);
    assert.deepEqual(waits, [5, 15]);
    assert.deepEqual(retries.map(({ attempt, maxAttempts, delayMs, packageVersion }) => ({
      attempt, maxAttempts, delayMs, packageVersion,
    })), [
      { attempt: 1, maxAttempts: 4, delayMs: 5, packageVersion: '18.2.11' },
      { attempt: 2, maxAttempts: 4, delayMs: 15, packageVersion: '18.2.11' },
    ]);
  }
});

test('returns the final OMP bootstrap error after exhausting the bounded retry schedule', async () => {
  const expectedError = ompBootstrapError();
  let attempts = 0;
  await assert.rejects(() => createOMPSessionWithBootstrapRetry({
    createSession: async () => {
      attempts += 1;
      throw expectedError;
    },
    packageVersion: '18.2.11',
    sessionOptions: {},
    retryDelays: [1, 2],
    waitForRetry: async () => {},
  }), error => error === expectedError);
  assert.equal(attempts, 3);
});

test('default OMP retry schedule spans the observed staggered publication window', async () => {
  let attempts = 0;
  const waits = [];
  const session = await createOMPSessionWithBootstrapRetry({
    createSession: async () => {
      attempts += 1;
      if (attempts <= 6) throw ompBootstrapError(attempts < 6 ? 'pi-coding-agent' : 'omp-stats');
      return { id: 'ready' };
    },
    packageVersion: '18.2.11',
    sessionOptions: {},
    waitForRetry: async delayMs => waits.push(delayMs),
  });
  assert.equal(session.id, 'ready');
  assert.equal(attempts, 7);
  assert.deepEqual(waits, [5_000, 15_000, 30_000, 60_000, 120_000, 240_000]);
});

test('does not retry unrelated OMP bootstrap or session failures', async () => {
  for (const error of [
    ompBootstrapError('pi-coding-agent', '18.2.10'),
    new Error("Bootstrap command failed for harness 'omp' (exit 1): npm install\nnpm error code E401"),
    new Error("Bootstrap command failed for harness 'codex' (exit 1): npm install\nnpm error code ETARGET\n@oh-my-pi/pi-coding-agent@18.2.11"),
    new Error('authentication failed'),
  ]) {
    let attempts = 0;
    await assert.rejects(() => createOMPSessionWithBootstrapRetry({
      createSession: async () => {
        attempts += 1;
        throw error;
      },
      packageVersion: '18.2.11',
      sessionOptions: {},
      retryDelays: [1],
      waitForRetry: async () => assert.fail('unrelated failure waited for a retry'),
    }), thrown => thrown === error);
    assert.equal(attempts, 1);
  }
});

test('retries an npm publication gap while resuming through OMP compatibility selection', async () => {
  const candidate = {
    packageVersion: '18.2.11', modelStrategy: 'launch-argument',
    hookPath: '/stable/hook.mjs', configPath: '/runtime/omp.yml',
  };
  let attempts = 0;
  const result = await createOMPSessionWithCompatibility({
    candidates: [candidate],
    createAgent: () => ({
      async createSession() {
        attempts += 1;
        if (attempts === 1) throw ompBootstrapError('omp-stats');
        return { id: 'resumed' };
      },
    }),
    sessionOptions: { resumeFrom: { data: { acpSessionId: 'acp-session' } } },
    bootstrapRetryDelays: [1],
    waitForBootstrapRetry: async () => {},
  });
  assert.equal(attempts, 2);
  assert.equal(result.candidate, candidate);
  assert.equal(result.session.id, 'resumed');
});

test('recognizes an OMP dependency ETARGET through an error cause', () => {
  const error = new Error('session creation failed', { cause: ompBootstrapError('omp-stats') });
  assert.equal(isOMPBootstrapVersionUnavailable(error, '18.2.11'), true);
  assert.equal(isOMPBootstrapVersionUnavailable(error, '18.2.10'), false);
});

test('preselects the legacy package and launch matching the persisted ACP implementation identity', async () => {
  const legacyHookPath = '/runtime/harness/old/omp-capabilities-hook.mjs';
  const configPath = '/runtime/config/omp.yml';
  const candidates = createOMPLaunchCandidates({
    hookPaths: ['/runtime/stable/omp-capabilities-new.mjs', legacyHookPath],
    configPath,
    implementations: [
      { packageVersion: '18.2.9', modelStrategy: 'launch-argument' },
      { packageVersion: '18.1.10', modelStrategy: 'session-config-option' },
    ],
  });
  const lifecycleState = {
    data: {
      implementationIdentity: acpImplementationIdentity({
        settings: ompSettings(legacyHookPath, undefined, '18.1.10'),
        acpPackageVersion,
      }),
    },
  };
  const prioritized = prioritizeOMPLaunchCandidates({
    candidates,
    lifecycleState,
    settingsForCandidate: candidate => ompSettings(
      candidate.hookPath, candidate.configPath, candidate.packageVersion, candidate.modelStrategy,
    ),
    acpPackageVersion,
  });
  assert.deepEqual(prioritized[0], {
    packageVersion: '18.1.10', modelStrategy: 'session-config-option',
    hookPath: legacyHookPath, configPath: undefined,
  });
  assert.deepEqual(prioritized.slice(1), candidates.filter(candidate => candidate !== prioritized[0]));
});

test('orders bounded OMP package compatibility candidates newest first', () => {
  assert.deepEqual(createOMPLaunchCandidates({
    hookPaths: ['/stable/hook.mjs'],
    configPath: '/runtime/omp.yml',
    implementations: [
      { packageVersion: '18.2.9', modelStrategy: 'launch-argument' },
      { packageVersion: '18.1.10', modelStrategy: 'session-config-option' },
    ],
  }), [
    { packageVersion: '18.2.9', modelStrategy: 'launch-argument', hookPath: '/stable/hook.mjs', configPath: '/runtime/omp.yml' },
    { packageVersion: '18.2.9', modelStrategy: 'launch-argument', hookPath: '/stable/hook.mjs', configPath: undefined },
    { packageVersion: '18.1.10', modelStrategy: 'session-config-option', hookPath: '/stable/hook.mjs', configPath: '/runtime/omp.yml' },
    { packageVersion: '18.1.10', modelStrategy: 'session-config-option', hookPath: '/stable/hook.mjs', configPath: undefined },
  ]);
});

test('stages the Dieter OMP overlay atomically with private permissions', async t => {
  const runtimeRoot = await mkdtemp(join(tmpdir(), 'dieter-omp-config-'));
  t.after(() => rm(runtimeRoot, { recursive: true, force: true }));
  const content = 'providers:\n  streamIdleTimeoutSeconds: 1800\n';
  const configPath = await prepareOMPConfig({ runtimeRoot, content });
  assert.equal(configPath, join(runtimeRoot, 'harness-config', 'omp.yml'));
  assert.equal(await readFile(configPath, 'utf8'), content);
  assert.equal((await stat(configPath)).mode & 0o777, 0o600);
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
    candidates: [{ hookPath: '/stable/hook.mjs', configPath: '/runtime/omp.yml' }],
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
