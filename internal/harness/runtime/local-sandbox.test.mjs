import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createLocalSandboxProvider } from './local-sandbox.mjs';

test('observes a process that exits before wait is called', async () => {
  const base = await mkdtemp(join(tmpdir(), 'board-local-sandbox-'));
  try {
    const projectPath = join(base, 'project');
    await mkdir(projectPath);
    const provider = await createLocalSandboxProvider({ root: join(base, 'runtime'), projectPath });
    const session = await provider.createSession();
    const processHandle = await session.spawn({ command: 'exit 7' });
    await new Promise(resolve => setTimeout(resolve, 50));
    const result = await Promise.race([
      processHandle.wait(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('wait did not observe the early exit')), 500)),
    ]);
    assert.equal(result.exitCode, 7);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test('only trusts the bootstrap marker for the currently materialized recipe', async () => {
  const base = await mkdtemp(join(tmpdir(), 'board-local-sandbox-'));
  try {
    const projectPath = join(base, 'project');
    await mkdir(projectPath);
    const provider = await createLocalSandboxProvider({ root: join(base, 'runtime'), projectPath });
    const session = await provider.createSession();
    const first = join(base, 'runtime', '.harness-bootstrap', 'omp', '.bootstrap-aaaa.ok');
    const second = join(base, 'runtime', '.harness-bootstrap', 'omp', '.bootstrap-bbbb.ok');

    await session.writeTextFile({ path: first, content: '' });
    assert.equal(await session.readTextFile({ path: first }), '');
    assert.equal(await session.readTextFile({ path: second }), null);

    await session.writeTextFile({ path: second, content: '' });
    assert.equal(await session.readTextFile({ path: first }), null);
    assert.equal(await session.readTextFile({ path: second }), '');
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test('stopping a local session terminates the entire spawned process group', { skip: process.platform === 'win32' }, async () => {
  const base = await mkdtemp(join(tmpdir(), 'board-local-sandbox-'));
  try {
    const projectPath = join(base, 'project');
    const childPIDFile = join(base, 'child.pid');
    await mkdir(projectPath);
    const provider = await createLocalSandboxProvider({ root: join(base, 'runtime'), projectPath });
    const session = await provider.createSession();
    const processHandle = await session.spawn({
      command: `node -e "const{spawn}=require('child_process');const{writeFileSync}=require('fs');const c=spawn(process.execPath,['-e','process.on(\\\"SIGTERM\\\",()=>{});setInterval(()=>{},1000)'],{stdio:'ignore'});writeFileSync('${childPIDFile}',String(c.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"`,
    });
    for (let attempt = 0; attempt < 50; attempt++) {
      try {
        if ((await readFile(childPIDFile, 'utf8')).trim()) break;
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    const descendantPID = Number((await readFile(childPIDFile, 'utf8')).trim());

    await session.stop();
    await processHandle.wait();

    assert.throws(() => process.kill(processHandle.pid, 0), error => error?.code === 'ESRCH');
    assert.throws(() => process.kill(descendantPID, 0), error => error?.code === 'ESRCH');
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
