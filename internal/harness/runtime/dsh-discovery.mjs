import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { prepareSandboxForHarness } from '@ai-sdk/harness/agent';
import { createACP } from '@ai-sdk/harness-acp';
import { createLocalSandboxProvider } from './local-sandbox.mjs';
import { parseDSHModelOptions } from './dsh-models.mjs';
import { dshACPArgs, dshPackageVersion } from './provider-options.mjs';

const runtimeRoot = process.argv[2];
if (!runtimeRoot) throw new Error('DSH discovery requires a runtime root');

const projectPath = join(runtimeRoot, 'catalog-project');
const discoveryState = join(runtimeRoot, 'catalog-state');
const patchPath = join(runtimeRoot, 'catalog.patch.yml');
await mkdir(projectPath, { recursive: true, mode: 0o700 });
await mkdir(discoveryState, { recursive: true, mode: 0o700 });
await writeFile(patchPath, [
  '- id: session-persistence-jsonl',
  '  config:',
  `    root: ${JSON.stringify(join(discoveryState, 'sessions'))}`,
  '',
  '- id: storage-json',
  '  config:',
  `    root: ${JSON.stringify(join(discoveryState, 'storage'))}`,
  '',
].join('\n'), { mode: 0o600 });

const harness = createACP({
  harnessId: 'dsh',
  source: {
    type: 'npm-simple',
    packageName: '@deepseek-ai/dsh',
    packageVersion: dshPackageVersion,
  },
  executable: 'dsh',
  args: dshACPArgs(),
  modelMapping: { type: 'session-config-option', path: 'model' },
});
const sandboxProvider = await createLocalSandboxProvider({
  root: runtimeRoot,
  projectPath,
  workDir: 'workspaces/catalog/repo',
});
const sandboxSession = await sandboxProvider.createSession();
let child;
let rpc;
let shuttingDown = false;

async function stopChild() {
  if (!child || child.exitCode != null || child.signalCode != null) return;
  child.kill('SIGTERM');
  await Promise.race([
    new Promise(resolve => child.once('exit', resolve)),
    new Promise(resolve => setTimeout(resolve, 5_000)),
  ]);
  if (child.exitCode == null && child.signalCode == null) child.kill('SIGKILL');
}

async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stderr.write(`DSH model discovery interrupted by signal (exit ${code})\n`);
  await Promise.allSettled([stopChild(), sandboxProvider.stopAll()]);
  process.exit(code);
}
process.once('SIGINT', () => void shutdown(130));
process.once('SIGTERM', () => void shutdown(143));

function createRPC(processHandle) {
  let sequence = 0;
  let failure;
  const pending = new Map();
  let stderr = '';
  processHandle.stderr.setEncoding('utf8');
  processHandle.stderr.on('data', chunk => {
    stderr = `${stderr}${chunk}`.slice(-64 * 1024);
  });
  const lines = readline.createInterface({ input: processHandle.stdout, crlfDelay: Infinity });
  const rejectAll = error => {
    if (failure) return;
    failure = error;
    for (const entry of pending.values()) entry.reject(error);
    pending.clear();
  };
  lines.on('line', line => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      rejectAll(new Error('DSH wrote non-ACP data to stdout'));
      return;
    }
    if (message && Object.hasOwn(message, 'id') && (Object.hasOwn(message, 'result') || Object.hasOwn(message, 'error'))) {
      const entry = pending.get(message.id);
      if (!entry) return;
      pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) entry.reject(new Error(message.error.message || 'DSH ACP request failed'));
      else entry.resolve(message.result);
      return;
    }
    if (message && Object.hasOwn(message, 'id') && typeof message.method === 'string') {
      processHandle.stdin.write(`${JSON.stringify({
        jsonrpc: '2.0', id: message.id,
        error: { code: -32601, message: `unsupported discovery client method: ${message.method}` },
      })}\n`);
    }
  });
  processHandle.once('error', rejectAll);
  processHandle.once('exit', (code, signal) => {
    rejectAll(new Error(`DSH ACP exited before discovery completed (${signal || code}); ${stderr.trim()}`));
  });
  return {
    request(method, params) {
      if (failure) return Promise.reject(failure);
      const id = ++sequence;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`DSH ACP ${method} timed out`));
        }, 30_000);
        pending.set(id, { resolve, reject, timer });
        processHandle.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
      });
    },
  };
}

try {
  await prepareSandboxForHarness({ session: sandboxSession, harnesses: [harness] });
  const executable = join(
    runtimeRoot, '.harness-bootstrap', 'dsh', 'implementation', 'node_modules', '.bin', 'dsh',
  );
  child = spawn(executable, dshACPArgs('--patch', patchPath), {
    cwd: projectPath,
    env: { ...process.env, DSH_TELEMETRY_DISABLED: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  rpc = createRPC(child);
  await rpc.request('initialize', {
    protocolVersion: 1,
    clientInfo: { name: 'dieter-model-discovery', version: '1' },
    clientCapabilities: {},
  });
  const created = await rpc.request('session/new', { cwd: projectPath, mcpServers: [] });
  const models = parseDSHModelOptions(created?.configOptions);
  await rpc.request('session/close', { sessionId: created.sessionId });
  await stopChild();
  process.stdout.write(`${JSON.stringify({ models })}\n`);
} finally {
  await Promise.allSettled([stopChild(), sandboxProvider.stopAll()]);
}
