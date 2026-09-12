import { createHash, randomUUID } from 'node:crypto';
import { chmod, mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const acpImplementationMismatch = 'ACP lifecycle state is incompatible with the configured implementation.';
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

export function prioritizeOMPHookPaths({ hookPaths, lifecycleState, settingsForHook, acpPackageVersion }) {
  const expected = lifecycleState?.data?.implementationIdentity;
  if (typeof expected !== 'string' || !expected) return hookPaths;
  const match = hookPaths.find(hookPath => acpImplementationIdentity({
    settings: settingsForHook(hookPath),
    acpPackageVersion,
  }) === expected);
  return match ? [match, ...hookPaths.filter(hookPath => hookPath !== match)] : hookPaths;
}

export function isACPImplementationMismatch(error) {
  const message = error instanceof Error ? error.message : String(error || '');
  return message.includes(acpImplementationMismatch);
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

/** Retry only the one compatibility failure caused before an ACP bridge starts. */
export async function createOMPSessionWithCompatibility({ hookPaths, createAgent, sessionOptions, onFallback }) {
  if (!Array.isArray(hookPaths) || hookPaths.length === 0) throw new Error('OMP hook candidates are missing');
  for (let index = 0; index < hookPaths.length; index += 1) {
    const hookPath = hookPaths[index];
    const agent = createAgent(hookPath);
    try {
      const session = await agent.createSession(sessionOptions);
      if (index > 0) onFallback?.(hookPath);
      return { agent, session, hookPath };
    } catch (error) {
      if (!isACPImplementationMismatch(error) || index === hookPaths.length - 1) throw error;
    }
  }
  throw new Error('OMP hook compatibility search exhausted unexpectedly');
}
