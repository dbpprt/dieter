import { acpSettings } from "./acp-runtime.mjs";
import { createHash, randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

const acpImplementationMismatch = "ACP lifecycle state is incompatible with the configured agent.";

function sortIdentityValue(value) {
  if (Array.isArray(value)) return value.map(sortIdentityValue);
  if (value != null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, sortIdentityValue(item)]),
    );
  }
  return value;
}

/** Mirror the pinned ACP package's identity contract for preflight selection. */
export function acpImplementationIdentity({ settings, acpPackageVersion }) {
  settings = acpSettings(settings);
  if (settings.providerAuthentication != null) {
    throw new Error("static ACP identity selection does not support provider authentication");
  }
  const source =
    settings.source.type === "npm-simple"
      ? {
          type: settings.source.type,
          packageName: settings.source.packageName,
          ...(settings.source.packageVersion == null
            ? {}
            : { packageVersion: settings.source.packageVersion }),
        }
      : settings.source;
  const forwarded = [...new Set(settings.forwardEnv ?? [])].sort();
  const credential = [...new Set(settings.credentialEnv ?? [])].sort();
  const literal = Object.fromEntries(
    Object.entries(settings.env ?? {})
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => [key, value]),
  );
  const payload = {
    harnessId: settings.harnessId,
    acpVersion: settings.version ?? "v1",
    source,
    executable: settings.executable,
    args: settings.args ?? [],
    clientApp: settings.clientApp ?? { name: "ai-sdk-harness-acp", version: acpPackageVersion },
    clientCapabilities: settings.clientCapabilities ?? null,
    modelMapping: settings.modelMapping,
    environment: { forwarded, credential, literal },
    providerAuthentication: null,
    permissionModeMapping: settings.permissionModeMapping ?? null,
    nonTextContentTypes: [...new Set(settings.nonTextContentTypes ?? [])].sort(),
  };
  return createHash("sha256")
    .update(JSON.stringify(sortIdentityValue(payload)))
    .digest("hex");
}

/**
 * Launch settings that may match a persisted OMP lifecycle: the current hook
 * and config first, then hooks staged by earlier runtimes and launches from
 * before Dieter passed its config overlay.
 */
export function createOMPLaunchCandidates({ hookPaths, configPath }) {
  if (!Array.isArray(hookPaths) || hookPaths.length === 0) {
    throw new Error("OMP hook paths are missing");
  }
  return [
    ...hookPaths.map((hookPath) => ({ hookPath, configPath })),
    ...hookPaths.map((hookPath) => ({ hookPath, configPath: undefined })),
  ];
}

export function prioritizeOMPLaunchCandidates({
  candidates,
  lifecycleState,
  settingsForCandidate,
  acpPackageVersion,
}) {
  const expected = lifecycleState?.data?.agentIdentity;
  if (typeof expected !== "string" || !expected) return candidates;
  const match = candidates.find(
    (candidate) =>
      acpImplementationIdentity({
        settings: settingsForCandidate(candidate),
        acpPackageVersion,
      }) === expected,
  );
  return match ? [match, ...candidates.filter((candidate) => candidate !== match)] : candidates;
}

export function isACPImplementationMismatch(error) {
  const message = error instanceof Error ? error.message : String(error || "");
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

async function stagePrivate(path, content) {
  let current;
  try {
    current = await readFile(path);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  if (!current?.equals(Buffer.from(content))) await atomicWrite(path, content);
  await chmod(path, 0o600);
}

/**
 * Stage everything an OMP launch reads at fixed per-conversation paths: the
 * capabilities hook, the settings overlay (runtime settings, pinned roles,
 * advisor) and the turn file the hook reads the thinking level from. The
 * launch arguments, and with them the ACP implementation identity, therefore
 * never change between turns or runtime updates, so a conversation can change
 * model, effort, advisor or account and still resume its OMP session.
 */
export async function prepareOMPLaunch({ runtimeRoot, sessionId, hookSource, config, turn }) {
  if (typeof sessionId !== "string" || !/^[A-Za-z0-9_-]+$/.test(sessionId)) {
    throw new Error("OMP launch needs a plain session ID");
  }
  const root = join(runtimeRoot, "harness-config");
  await mkdir(root, { recursive: true, mode: 0o700 });
  await chmod(root, 0o700);
  const hookPath = join(root, "omp-capabilities.mjs");
  const configPath = join(root, `omp-${sessionId}.yml`);
  const turnPath = join(root, `omp-${sessionId}.json`);
  await stagePrivate(hookPath, await readFile(hookSource));
  await stagePrivate(configPath, config);
  await stagePrivate(turnPath, `${JSON.stringify(turn)}\n`);
  return { hookPath, configPath, turnPath };
}
