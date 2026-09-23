import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { prepareSandboxForHarness } from '@ai-sdk/harness/agent';
import { createACP } from '@ai-sdk/harness-acp';
import { createLocalSandboxProvider } from './local-sandbox.mjs';
import { normalizeOMPDiscovery } from './omp-models.mjs';
import { ompACPModelMapping, ompPackageVersion } from './provider-options.mjs';

const runtimeRoot = process.argv[2];
if (!runtimeRoot) throw new Error('OMP discovery requires a runtime root');

const projectPath = join(runtimeRoot, 'catalog-project');
await mkdir(projectPath, { recursive: true, mode: 0o700 });

const harness = createACP({
  harnessId: 'omp',
  source: {
    type: 'npm-simple',
    packageName: '@oh-my-pi/pi-coding-agent',
    packageVersion: ompPackageVersion,
  },
  executable: 'omp',
  args: ['acp'],
  modelMapping: ompACPModelMapping,
  forwardEnv: ['HOME', 'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'PI_NATIVE_VARIANT'],
});
const sandboxProvider = await createLocalSandboxProvider({
  root: runtimeRoot,
  projectPath,
  workDir: 'workspaces/catalog/repo',
});
const sandboxSession = await sandboxProvider.createSession();
let child;
let shuttingDown = false;

function boundedAppend(current, chunk, limit) {
  const next = `${current}${chunk}`;
  return next.length <= limit ? next : next.slice(-limit);
}

function runOMP(executable, args, { optional = false } = {}) {
  return new Promise((resolve, reject) => {
    child = spawn(executable, args, {
      cwd: projectPath,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stdoutBytes = 0;
    let stderr = '';
    let failed;
    child.stdout.on('data', chunk => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > 8 * 1024 * 1024) {
        failed = new Error('OMP discovery output exceeded 8 MiB');
        child.kill('SIGKILL');
        return;
      }
      stdout += chunk;
    });
    child.stderr.on('data', chunk => {
      stderr = boundedAppend(stderr, chunk, 64 * 1024);
    });
    child.once('error', error => {
      failed = error;
    });
    child.once('close', (code, signal) => {
      child = undefined;
      if (failed) return reject(failed);
      if (code !== 0) {
        if (optional) return resolve(undefined);
        return reject(new Error(`OMP discovery exited ${signal || code}: ${stderr.trim()}`));
      }
      try {
        resolve(JSON.parse(stdout));
      } catch (error) {
        if (optional) resolve(undefined);
        else reject(new Error(`OMP discovery returned invalid JSON: ${error.message}`));
      }
    });
  });
}

async function stopChild() {
  const current = child;
  if (!current || current.exitCode != null || current.signalCode != null) return;
  current.kill('SIGTERM');
  await Promise.race([
    new Promise(resolve => current.once('exit', resolve)),
    new Promise(resolve => setTimeout(resolve, 5_000)),
  ]);
  if (current.exitCode == null && current.signalCode == null) current.kill('SIGKILL');
}

async function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stderr.write(`OMP model discovery interrupted by signal (exit ${code})\n`);
  await Promise.allSettled([stopChild(), sandboxProvider.stopAll()]);
  process.exit(code);
}
process.once('SIGINT', () => void shutdown(130));
process.once('SIGTERM', () => void shutdown(143));

try {
  await prepareSandboxForHarness({ session: sandboxSession, harnesses: [harness] });
  const executable = join(
    runtimeRoot, '.harness-bootstrap', 'omp', 'implementation', 'node_modules', '.bin', 'omp',
  );
  const models = await runOMP(executable, ['models', '--json', '--no-extensions']);
  const roles = await runOMP(executable, ['config', 'get', 'modelRoles'], { optional: true });
  process.stdout.write(`${JSON.stringify(normalizeOMPDiscovery(models, roles))}\n`);
} finally {
  await Promise.allSettled([stopChild(), sandboxProvider.stopAll()]);
}
