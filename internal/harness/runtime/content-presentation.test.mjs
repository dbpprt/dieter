import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createContentPresentationTool } from './content-presentation.mjs';

test('presentation host tool binds owning conversation and emits explicit typed output', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dieter-present-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const workspace = join(root, 'workspace');
  await mkdir(workspace);
  await writeFile(join(workspace, 'report.md'), '# Report');
  const events = [];
  const tool = createContentPresentationTool({ sessionId: 'card-owner', projectPath: workspace }, event => events.push(event));
  const input = tool.inputSchema.parse({ path: 'report.md', line: 3, title: 'Result' });
  const result = await tool.execute(input);
  assert.equal(result.conversationId, 'card-owner');
  assert.equal(result.requested, true);
  assert.equal(result.opened, undefined);
  assert.deepEqual(events, [{ type: 'present-content', presentation: { path: 'report.md', line: 3, title: 'Result' } }]);
  assert.equal(tool.inputSchema.safeParse({ path: 'report.md', cardId: 'other' }).success, false);
  assert.equal(tool.inputSchema.safeParse({ url: 'https://example.test', machine: 'other' }).success, false);
  await symlink(workspace, join(root, 'workspace-alias'));
  const aliased = await tool.execute(tool.inputSchema.parse({ path: join(root, 'workspace-alias', 'report.md') }));
  assert.equal(aliased.path, 'report.md');
  const url = await tool.execute(tool.inputSchema.parse({ url: 'https://example.test/results' }));
  assert.equal(url.url, 'https://example.test/results');
});

test('presentation host tool rejects unsafe, missing, oversized, and non-file targets', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dieter-present-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const workspace = join(root, 'workspace');
  await mkdir(join(workspace, '.git'), { recursive: true });
  await writeFile(join(root, 'outside.md'), 'outside');
  await writeFile(join(workspace, '.git', 'config'), 'protected');
  await symlink(join(root, 'outside.md'), join(workspace, 'escape'));
  await symlink(join(workspace, '.git', 'config'), join(workspace, 'git-alias'));
  await writeFile(join(workspace, 'big.bin'), Buffer.alloc(5 * 1024 * 1024 + 1));
  const events = [];
  const tool = createContentPresentationTool({ sessionId: 'card-owner', projectPath: workspace }, event => events.push(event));
  for (const path of ['../outside.md', 'escape', '.git/config', 'git-alias', '.', 'missing', 'big.bin']) {
    await assert.rejects(tool.execute({ path }), undefined, path);
  }
  for (const input of [{ url: 'javascript:alert(1)' }, { url: 'https://user:pass@example.test' }, { url: 'https://example.test', line: 2 }]) {
    await assert.rejects(tool.execute(input));
  }
  for (const input of [{}, { path: 'a', url: 'https://example.test' }, { path: 'a', line: -1 }, { path: 'a', title: 'bad\nheader' }]) {
    assert.equal(tool.inputSchema.safeParse(input).success, false);
  }
  assert.deepEqual(events, []);
});

test('presentation host tool bounds UTF-8 input and normalized URLs before emitting', async () => {
  const events = [];
  const tool = createContentPresentationTool({ sessionId: 'card-owner' }, event => events.push(event));
  assert.equal(tool.inputSchema.safeParse({ path: 'é'.repeat(2049) }).success, false);
  assert.equal(tool.inputSchema.safeParse({ url: 'https://example.test/' + 'é'.repeat(4096) }).success, false);

  // This fits both raw limits, but percent encoding expands each emoji to
  // twelve ASCII bytes. Reject it locally instead of failing the daemon turn.
  const input = tool.inputSchema.parse({ url: 'https://example.test/' + '🧪'.repeat(1000) });
  await assert.rejects(tool.execute(input), /Normalized URL exceeds/);
  assert.deepEqual(events, []);

  const shown = await tool.execute(tool.inputSchema.parse({ url: 'https://example.test/é' }));
  assert.equal(shown.url, 'https://example.test/%C3%A9');
  assert.equal(events.length, 1);
});
