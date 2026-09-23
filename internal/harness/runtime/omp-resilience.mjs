import { createHash, randomUUID } from 'node:crypto';
import { chmod, mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';

const acpImplementationMismatch = 'ACP lifecycle state is incompatible with the configured implementation.';
const ompBootstrapRetryDelays = Object.freeze([5_000, 15_000, 30_000, 60_000, 120_000, 240_000]);
const stagedRuntimeDirectory = /^[a-f0-9]{16}$/;
const stableHookFile = /^omp-capabilities-[a-f0-9]{64}\.mjs$/;

function sortIdentityValue(value) {
  if (Array.isArray(value)) return value.map(sortIdentityValue);
  if (value != null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, sortIdentityValue(item)]));
  }
  return value;
}

/** Mirror the pinned ACP package's identity contract for preflight selection. */
export function acpImplementationIdentity({ settings, acpPackageVersion }) {
  if (settings.providerAuthentication != null) {
    throw new Error('static ACP identity selection does not support provider authentication');
  }
  const source = settings.source.type === 'npm-simple'
    ? {
      type: settings.source.type,
      packageName: settings.source.packageName,
      ...(settings.source.packageVersion == null ? {} : { packageVersion: settings.source.packageVersion }),
    }
    : settings.source;
  const forwarded = [...new Set(settings.forwardEnv ?? [])].sort();
  const credential = [...new Set(settings.credentialEnv ?? [])].sort();
  const literal = Object.fromEntries(Object.entries(settings.env ?? {})
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => [key, { value }]));
  const payload = {
    harnessId: settings.harnessId,
    acpVersion: settings.version ?? 'v1',
    source,
    executable: settings.executable,
    args: settings.args ?? [],
    clientApp: settings.clientApp ?? { name: 'ai-sdk/harness-acp', version: acpPackageVersion },
    clientCapabilities: settings.clientCapabilities ?? null,
    modelMapping: settings.modelMapping,
    environment: { forwarded, credential, literal },
    providerAuthentication: null,
    permissionModeMapping: settings.permissionModeMapping ?? null,
  };
  return createHash('sha256').update(JSON.stringify(sortIdentityValue(payload))).digest('hex');
}

export function createOMPLaunchCandidates({ hookPaths, configPath, implementations }) {
  if (!Array.isArray(implementations) || implementations.length === 0) {
    throw new Error('OMP implementations are missing');
  }
  return implementations.flatMap(implementation => [
    ...hookPaths.map(hookPath => ({ ...implementation, hookPath, configPath })),
    ...hookPaths.map(hookPath => ({ ...implementation, hookPath, configPath: undefined })),
  ]);
}

export function prioritizeOMPLaunchCandidates({ candidates, lifecycleState, settingsForCandidate, acpPackageVersion }) {
  const expected = lifecycleState?.data?.implementationIdentity;
  if (typeof expected !== 'string' || !expected) return candidates;
  const match = candidates.find(candidate => acpImplementationIdentity({
    settings: settingsForCandidate(candidate),
    acpPackageVersion,
  }) === expected);
  return match ? [match, ...candidates.filter(candidate => candidate !== match)] : candidates;
}

export function isACPImplementationMismatch(error) {
  const message = error instanceof Error ? error.message : String(error || '');
  return message.includes(acpImplementationMismatch);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function errorMessages(error) {
  const messages = [];
  const visited = new Set();
  let current = error;
  while (current != null && !visited.has(current) && messages.length < 8) {
    if ((typeof current === 'object' || typeof current === 'function') && current !== null) {
      visited.add(current);
      if (typeof current.message === 'string') messages.push(current.message);
      current = current.cause;
    } else {
      messages.push(String(current));
      break;
    }
  }
  return messages.join('\n');
}

/** Match only npm propagation failures for Dieter's exact OMP package-family version. */
export function isOMPBootstrapVersionUnavailable(error, packageVersion) {
  if (typeof packageVersion !== 'string' || !packageVersion) return false;
  const message = errorMessages(error);
  if (!message.includes("Bootstrap command failed for harness 'omp'")) return false;
  if (!/(?:^|\s)ETARGET(?:\s|$)/m.test(message)) return false;
  const unavailablePackage = new RegExp(
    `@oh-my-pi\/[A-Za-z0-9._-]+@${escapeRegExp(packageVersion)}(?=$|\\s|[.,;:'"\\)\\]])`,
    'm',
  );
  return unavailablePackage.test(message);
}

async function waitForOMPBootstrapRetry(delayMs, abortSignal) {
  await wait(delayMs, undefined, abortSignal ? { signal: abortSignal } : undefined);
}

/**
 * npm can expose OMP's root package before its same-version dependencies have
 * reached every registry edge. Retry that one bootstrap failure on the same
 * agent. The default schedule is bounded to 470 seconds of total delay, long
 * enough to span the observed stagger between a release's root package and
 * same-version dependencies without approaching the turn's 30-minute guard.
 */
export async function createOMPSessionWithBootstrapRetry({
  createSession,
  packageVersion,
  sessionOptions,
  retryDelays = ompBootstrapRetryDelays,
  waitForRetry = waitForOMPBootstrapRetry,
  onRetry,
}) {
  if (typeof createSession !== 'function') throw new Error('OMP session creator is missing');
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await createSession(sessionOptions);
    } catch (error) {
      if (
        attempt >= retryDelays.length
        || !isOMPBootstrapVersionUnavailable(error, packageVersion)
      ) throw error;
      const delayMs = retryDelays[attempt];
      onRetry?.({
        attempt: attempt + 1,
        maxAttempts: retryDelays.length + 1,
        delayMs,
        packageVersion,
        error,
      });
      await waitForRetry(delayMs, sessionOptions?.abortSignal);
    }
  }
}

async function atomicWrite(path, content) {
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  try {
    await writeFile(temporary, content, { mode: 0o600 });
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}

async function regularFile(path) {
  try {
    return (await stat(path)).isFile();
  } catch (error) {
    if (error?.code === 'ENOENT') return false;
    throw error;
  }
}

async function validStableHook(path, name) {
  try {
    const content = await readFile(path);
    return createHash('sha256').update(content).digest('hex') === name.slice('omp-capabilities-'.length, -'.mjs'.length);
  } catch (error) {
    if (error?.code === 'ENOENT') return false;
    throw error;
  }
}

/**
 * Give OMP a hook path whose identity depends on the hook itself, not on the
 * shared harness package-lock. Older staged paths remain candidates so
 * lifecycle state written before this scheme can still attach to its bridge.
 */
export async function prepareOMPConfig({ runtimeRoot, content }) {
  const configRoot = join(runtimeRoot, 'harness-config');
  const configPath = join(configRoot, 'omp.yml');
  await mkdir(configRoot, { recursive: true, mode: 0o700 });
  await chmod(configRoot, 0o700);
  let current;
  try {
    current = await readFile(configPath, 'utf8');
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  if (current !== content) await atomicWrite(configPath, content);
  await chmod(configPath, 0o600);
  return configPath;
}

export async function prepareOMPHookPaths({ runtimeRoot, currentHookPath }) {
  const content = await readFile(currentHookPath);
  const digest = createHash('sha256').update(content).digest('hex');
  const stableRoot = join(runtimeRoot, 'harness-hooks');
  const stableHookPath = join(stableRoot, `omp-capabilities-${digest}.mjs`);
  await mkdir(stableRoot, { recursive: true, mode: 0o700 });
  await chmod(stableRoot, 0o700);

  let stagedContent;
  try {
    stagedContent = await readFile(stableHookPath);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  if (!stagedContent?.equals(content)) await atomicWrite(stableHookPath, content);
  await chmod(stableHookPath, 0o600);

  const hookPaths = [stableHookPath];
  for (const entry of await readdir(stableRoot, { withFileTypes: true })) {
    if (!entry.isFile() || !stableHookFile.test(entry.name)) continue;
    const candidate = join(stableRoot, entry.name);
    if (!hookPaths.includes(candidate) && await validStableHook(candidate, entry.name)) hookPaths.push(candidate);
  }
  hookPaths.push(currentHookPath);
  const currentRuntimeRoot = dirname(currentHookPath);
  const sharedHarnessRoot = dirname(currentRuntimeRoot);
  for (const entry of await readdir(sharedHarnessRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || !stagedRuntimeDirectory.test(entry.name)) continue;
    const candidate = join(sharedHarnessRoot, entry.name, 'omp-capabilities-hook.mjs');
    if (!hookPaths.includes(candidate) && await regularFile(candidate)) hookPaths.push(candidate);
  }
  return hookPaths;
}

/** Retry only bounded bootstrap propagation and ACP implementation compatibility failures. */
export async function createOMPSessionWithCompatibility({
  candidates,
  createAgent,
  sessionOptions,
  bootstrapRetryDelays,
  waitForBootstrapRetry,
  onBootstrapRetry,
  onFallback,
}) {
  if (!Array.isArray(candidates) || candidates.length === 0) throw new Error('OMP launch candidates are missing');
  for (let index = 0; index < candidates.length; index += 1) {
    const candidate = candidates[index];
    const agent = createAgent(candidate);
    try {
      const session = await createOMPSessionWithBootstrapRetry({
        createSession: options => agent.createSession(options),
        packageVersion: candidate.packageVersion,
        sessionOptions,
        ...(bootstrapRetryDelays == null ? {} : { retryDelays: bootstrapRetryDelays }),
        ...(waitForBootstrapRetry == null ? {} : { waitForRetry: waitForBootstrapRetry }),
        onRetry: onBootstrapRetry,
      });
      if (index > 0) onFallback?.(candidate);
      return { agent, session, candidate };
    } catch (error) {
      if (!isACPImplementationMismatch(error) || index === candidates.length - 1) throw error;
    }
  }
  throw new Error('OMP hook compatibility search exhausted unexpectedly');
}
