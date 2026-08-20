import { createReadStream } from 'node:fs';
import { access, mkdir, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';

function localPath(candidate) {
  // This provider intentionally represents the unrestricted local host, not a
  // filesystem sandbox. Harness adapters keep resumable state in their own
  // user directories (for example ~/.ai-sdk), while work happens in the repo.
  return resolve(candidate);
}

function commandValue(command) {
  if (command.startsWith('pnpm install')) {
    return 'npm install --ignore-scripts --no-audit --no-fund';
  }
  const scopedInstall = command.match(/^pnpm --dir ([^ ]+) install(?: |$)/);
  if (scopedInstall) {
    return `npm install --prefix ${scopedInstall[1]} --ignore-scripts --no-audit --no-fund`;
  }
  return command;
}

const bootstrapMarkerPattern = /^\.bootstrap-[a-f0-9]+\.ok$/;

async function readLocalTextFile(path, encoding, startLine, endLine) {
  const absolute = localPath(path);
  const name = basename(absolute);
  if (bootstrapMarkerPattern.test(name)) {
    try {
      const current = (await readFile(join(dirname(absolute), '.bootstrap-current'), 'utf8')).trim();
      if (current !== name) return null;
    } catch (error) {
      if (error?.code === 'ENOENT') return null;
      throw error;
    }
  }
  try {
    const text = await readFile(absolute, { encoding });
    if (!startLine && !endLine) return text;
    return text.split('\n').slice((startLine ?? 1) - 1, endLine).join('\n');
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

async function writeLocalTextFile(path, content, encoding) {
  const absolute = localPath(path);
  await mkdir(dirname(absolute), { recursive: true });
  await writeFile(absolute, content, { encoding, mode: 0o600 });
  const name = basename(absolute);
  if (bootstrapMarkerPattern.test(name)) {
    await writeFile(join(dirname(absolute), '.bootstrap-current'), `${name}\n`, { encoding: 'utf8', mode: 0o600 });
  }
}

export async function createLocalSandboxProvider({ root, projectPath }) {
  root = resolve(root);
  projectPath = await realpath(projectPath);
  await mkdir(root, { recursive: true, mode: 0o700 });
  const repo = join(root, 'repo');
  const activeProcesses = new Set();

  const bridgePort = await new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(error => error ? reject(error) : resolvePort(address.port));
    });
  });
  try {
    const current = await realpath(repo);
    if (current !== projectPath) {
      await rm(repo, { recursive: true, force: true });
      await symlink(projectPath, repo, 'dir');
    }
  } catch {
    await rm(repo, { recursive: true, force: true });
    await symlink(projectPath, repo, 'dir');
  }

  const spawnProcess = ({ command, workingDirectory = root, env = {}, abortSignal }) => {
    const child = spawn('/bin/sh', ['-lc', commandValue(command)], {
      cwd: workingDirectory,
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
      // On Unix this makes the bridge the leader of a process group. Harness
      // providers commonly launch another CLI process, so stopping only the
      // shell/bridge PID can otherwise leave the actual model process alive.
      detached: process.platform !== 'win32',
    });
    // Subscribe immediately. A short-lived bridge can exit before the adapter
    // calls wait(); attaching the listener lazily would leave that wait pending
    // forever and make Node terminate with an unsettled top-level await.
    let processHandle;
    const waitPromise = new Promise((resolveWait, reject) => {
      child.once('error', error => {
        activeProcesses.delete(processHandle);
        reject(error);
      });
      child.once('exit', (code, signal) => {
        activeProcesses.delete(processHandle);
        resolveWait({ exitCode: code ?? (signal ? 128 : 1) });
      });
    });
    const signalTree = signal => {
      if (child.pid == null) return;
      try {
        if (process.platform === 'win32') child.kill(signal);
        else process.kill(-child.pid, signal);
      } catch (error) {
        if (error?.code !== 'ESRCH') throw error;
      }
    };
    const kill = async () => {
      if (child.exitCode != null) return;
      signalTree('SIGTERM');
      await Promise.race([waitPromise, new Promise(resolveWait => setTimeout(resolveWait, 1000))]);
      if (child.exitCode == null) {
        signalTree('SIGKILL');
        await waitPromise;
      }
    };
    if (abortSignal) {
      if (abortSignal.aborted) void kill();
      else abortSignal.addEventListener('abort', () => void kill(), { once: true });
    }
    processHandle = {
      pid: child.pid,
      stdout: Readable.toWeb(child.stdout),
      stderr: Readable.toWeb(child.stderr),
      wait: () => waitPromise,
      kill,
    };
    activeProcesses.add(processHandle);
    return processHandle;
  };

  const stopProcesses = async () => {
    await Promise.allSettled([...activeProcesses].map(processHandle => processHandle.kill()));
  };

  const session = {
    id: `board-local-${Buffer.from(root).toString('base64url').slice(-24)}`,
    description: `Unrestricted local host runtime rooted at ${root}; repo is ${projectPath}`,
    defaultWorkingDirectory: root,
    ports: [bridgePort],
    getPortEndpoint: async ({ port, protocol = 'http' }) => ({ url: `${protocol}://127.0.0.1:${port}` }),
    getPortUrl: async ({ port, protocol = 'http' }) => `${protocol}://127.0.0.1:${port}`,
    readFile: async ({ path }) => {
      const absolute = localPath(path);
      try { await access(absolute); return Readable.toWeb(createReadStream(absolute)); } catch { return null; }
    },
    readBinaryFile: async ({ path }) => {
      try { return new Uint8Array(await readFile(localPath(path))); } catch (error) {
        if (error?.code === 'ENOENT') return null;
        throw error;
      }
    },
    readTextFile: async ({ path, encoding = 'utf8', startLine, endLine }) => readLocalTextFile(path, encoding, startLine, endLine),
    writeFile: async ({ path, content }) => {
      const absolute = localPath(path);
      await mkdir(dirname(absolute), { recursive: true });
      const chunks = [];
      for await (const chunk of content) chunks.push(chunk);
      await writeFile(absolute, Buffer.concat(chunks.map(chunk => Buffer.from(chunk))), { mode: 0o600 });
    },
    writeBinaryFile: async ({ path, content }) => {
      const absolute = localPath(path);
      await mkdir(dirname(absolute), { recursive: true });
      await writeFile(absolute, content, { mode: 0o600 });
    },
    writeTextFile: async ({ path, content, encoding = 'utf8' }) => writeLocalTextFile(path, content, encoding),
    spawn: async options => spawnProcess(options),
    run: async options => {
      const processHandle = spawnProcess(options);
      const stdoutPromise = new Response(processHandle.stdout).text();
      const stderrPromise = new Response(processHandle.stderr).text();
      const [{ exitCode }, stdout, stderr] = await Promise.all([processHandle.wait(), stdoutPromise, stderrPromise]);
      return { exitCode, stdout, stderr };
    },
    stop: stopProcesses,
    destroy: stopProcesses,
    restricted() {
      const { description, readFile, readBinaryFile, readTextFile, writeFile, writeBinaryFile, writeTextFile, spawn, run } = this;
      return { description, readFile, readBinaryFile, readTextFile, writeFile, writeBinaryFile, writeTextFile, spawn, run };
    },
  };
  return {
    specificationVersion: 'harness-sandbox-v1',
    providerId: 'board-local-host',
    createSession: async () => session,
    resumeSession: async () => session,
    // Nauclio's worker uses this only as a last-resort shutdown guard if an SDK
    // adapter fails to settle its stream. It is intentionally outside the
    // portable sandbox contract.
    stopAll: stopProcesses,
  };
}
