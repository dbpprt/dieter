import assert from 'node:assert/strict';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const runnerURL = new URL('./runner.mjs', import.meta.url).href;
const payload = 'checkpoint-'.repeat(100_000);
const dataURL = source => `data:text/javascript,${encodeURIComponent(source)}`;

// Exercise the real worker, signals and stdout pipe with a deterministic
// provider boundary. No provider process, credentials or live daemon is used.
const agentFixture = `
export const getHarnessErrorMessage = error => error.message;
export class HarnessAgent {
  async createSession(options) {
    this.options = options;
    const state = () => ({type: 'resume-session', data: {payload: 'checkpoint-'.repeat(100_000)}});
    return {
      detach: async () => {
        if (process.env.FIXTURE_DETACH_ERROR) throw new Error('fixture checkpoint failed');
        const result = {...state(), continueFrom: {type: 'continue-turn', data: {cursor: 42}}};
        // Also exercise runner's catch path while its signal handler suspends.
        this.controller.error(new Error('fixture stream detached'));
        return result;
      },
      stop: async () => state(),
    };
  }
  async stream({abortSignal}) {
    return {stream: new ReadableStream({start: controller => {
      this.controller = controller;
      controller.enqueue({type: 'start', messageId: 'response'});
      controller.enqueue({type: 'tool-input-available', toolCallId: 'child', toolName: 'Agent', input: {description: 'Research'}});
      this.keepAlive = setInterval(() => {}, 1000);
      abortSignal.addEventListener('abort', () => {
        clearInterval(this.keepAlive);
        controller.close();
      }, {once: true});
      process.stderr.write('fixture-ready\\n');
    }})};
  }
  async continueStream() {
    if (this.options.continueFrom?.data?.cursor !== 42) throw new Error('lost continuation');
    return {stream: new ReadableStream({start: controller => {
      controller.enqueue({type: 'text-delta', id: 'text', delta: 'continued without replay'});
      controller.enqueue({type: 'finish', finishReason: 'stop'});
      controller.close();
    }})};
  }
}
`;
const preload = dataURL(`
import { registerHooks } from 'node:module';
const replacements = ${JSON.stringify({
  '@ai-sdk/harness/agent': dataURL(agentFixture),
  ai: dataURL('export const tool = value => value; export const toUIMessageStream = ({stream}) => stream;'),
})};
registerHooks({resolve(specifier, context, next) {
  if (context.parentURL === ${JSON.stringify(runnerURL)} && replacements[specifier]) {
    return {url: replacements[specifier], shortCircuit: true};
  }
  return next(specifier, context);
}});
`);

async function fixture(t) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'dieter-worker-shutdown-')));
  await mkdir(join(root, 'project'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return {
    request: {
      harness: 'claude-code', adapter: 'claude-code', sessionId: 'shutdown-test',
      projectPath: join(root, 'project'), runtimeRoot: join(root, 'runtime'),
      prompt: 'Research', responseMessageId: 'response', backgroundProcessesEnabled: true,
    },
    environment: { PATH: process.env.PATH, HOME: root, TMPDIR: root },
  };
}

async function runWorker(t, fixture, { signal, detachError = false } = {}) {
  const child = spawn(process.execPath, ['--import', preload, fileURLToPath(runnerURL)], {
    env: { ...fixture.environment, ...(detachError ? { FIXTURE_DETACH_ERROR: '1' } : {}) },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const closed = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  const timeout = setTimeout(() => child.kill('SIGKILL'), 30_000);
  t.after(async () => {
    clearTimeout(timeout);
    if (child.exitCode == null && child.signalCode == null) child.kill('SIGKILL');
    await closed;
  });
  let stdout = '', stderr = '', signaled = false;
  child.stdout.on('data', data => { stdout += data; });
  // Force backpressure while the worker writes its large checkpoint, as a
  // daemon persisting preceding capability events can do in production.
  if (signal) child.stdout.pause();
  child.stderr.on('data', data => {
    stderr += data;
    if (signal && !signaled && stderr.includes('fixture-ready')) {
      signaled = true;
      child.kill(signal);
      setTimeout(() => child.stdout.resume(), 100);
    }
  });
  child.stdin.write(`${JSON.stringify(fixture.request)}\n`);
  const result = await closed;
  clearTimeout(timeout);
  assert.equal(result.signal, null, stderr);
  assert(stdout.endsWith('\n'), 'worker left an unterminated protocol frame');
  const frames = stdout.trim().split('\n').map(line => JSON.parse(line));
  return { ...result, frames, stderr };
}

test('SIGUSR1 flushes a large checkpoint and the next worker continues the same turn', { timeout: 70_000 }, async t => {
  const setup = await fixture(t);
  const parked = await runWorker(t, setup, { signal: 'SIGUSR1' });
  assert.equal(parked.code, 0, parked.stderr);
  const sessions = parked.frames.filter(frame => frame.type === 'session');
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].state.data.payload, payload);
  assert.equal(sessions[0].state.continueFrom.data.cursor, 42);
  assert(!parked.frames.some(frame => frame.type === 'error' || frame.chunk?.type === 'abort'));
  const childStates = parked.frames.filter(frame => frame.capability?.subagent).map(frame => frame.capability.subagent.status);
  assert(childStates.includes('running'));
  assert(childStates.every(status => status === 'running' || status === 'pending'));
  const resumed = await runWorker(t, {
    ...setup, request: { ...setup.request, continue: true, session: sessions[0].state, prompt: '' },
  });
  assert.equal(resumed.code, 0, resumed.stderr);
  assert(resumed.frames.some(frame => frame.chunk?.delta === 'continued without replay'));
  assert(!resumed.frames.some(frame => frame.chunk?.type === 'tool-input-available'));
  assert.equal(resumed.frames.find(frame => frame.type === 'session').state.data.payload, payload);
});

for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  test(`${signal} flushes session and terminal subagent events`, { timeout: 40_000 }, async t => {
    const result = await runWorker(t, await fixture(t), { signal });
    assert.equal(result.code, code, result.stderr);
    assert.equal(result.frames.find(frame => frame.type === 'session').state.data.payload, payload);
    assert(result.frames.some(frame => frame.capability?.subagent?.status === 'aborted'));
  });
}

test('failed suspension exits unsuccessfully without inventing a continuation', { timeout: 40_000 }, async t => {
  const result = await runWorker(t, await fixture(t), { signal: 'SIGUSR1', detachError: true });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /fixture checkpoint failed/);
  assert(!result.frames.some(frame => frame.type === 'session'));
});
