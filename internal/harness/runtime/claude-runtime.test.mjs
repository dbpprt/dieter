import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { HarnessAgent } from '@ai-sdk/harness/agent';
import { createLocalClaudeCode } from './claude-runtime.mjs';
import { createLocalSandboxProvider } from './local-sandbox.mjs';

test('Claude disables native background tasks at the SDK boundary on fresh and resumed turns', { timeout: 30_000 }, async t => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'dieter-claude-background-')));
  let session, sandbox;
  t.after(async () => {
    try { await session?.stop(); }
    finally { await sandbox?.stopAll(); await rm(root, { recursive: true, force: true }); }
  });
  const projectPath = join(root, 'project');
  await mkdir(projectPath);
  sandbox = await createLocalSandboxProvider({ root, projectPath });
  const harness = createLocalClaudeCode({
    auth: { ANTHROPIC_API_KEY: 'dieter-disposable-fixture' },
    effort: 'high',
    env: { CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '0', DIETER_FIXTURE_OPTION: 'preserved' },
  });
  const recipe = await harness.getBootstrap();
  const bootstrap = join(root, recipe.bootstrapDir);
  await mkdir(bootstrap, { recursive: true });
  await symlink(join(dirname(fileURLToPath(import.meta.url)), 'node_modules'), join(bootstrap, 'node_modules'), 'dir');
  const bridge = recipe.files.find(file => file.path.endsWith('/bridge.mjs'));
  assert.match(bridge.content, /from "@anthropic-ai\/claude-agent-sdk"/);
  // Exercise the pinned adapter and its real WebSocket bridge, replacing only
  // inference with an offline SDK fixture. No provider install or credentials.
  const fixtureHarness = {
    ...harness,
    getBootstrap: async () => ({
      ...recipe,
      files: [
        { ...bridge, content: bridge.content.replace('from "@anthropic-ai/claude-agent-sdk"', 'from "./fixture-sdk.mjs"') },
        { path: `${recipe.bootstrapDir}/fixture-sdk.mjs`, content: fixtureSDK },
      ],
      commands: [],
    }),
  };
  const agent = new HarnessAgent({ harness: fixtureHarness, sandbox, permissionMode: 'allow-all', sandboxConfig: { workDir: 'repo' } });
  session = await agent.createSession({ sessionId: 'background-fixture' });
  async function run() {
    const result = await agent.stream({ session, prompt: 'Report the SDK options.' });
    let text = '';
    for await (const part of result.stream) {
      if (part.type === 'error') throw part.error;
      if (part.type === 'text-delta') text += part.text;
    }
    return JSON.parse(text);
  }
  const first = await run();
  assert.equal(first.disabled, '1');
  assert.equal(first.custom, 'preserved');
  assert.equal(first.effort, 'high');
  assert.equal(first.resume, undefined);
  const state = await session.stop();
  session = undefined;
  session = await agent.createSession({ sessionId: 'background-fixture', resumeFrom: state });
  const resumed = await run();
  assert.equal(resumed.disabled, '1');
  assert.equal(resumed.custom, 'preserved');
  assert.equal(resumed.resume, 'fixture-claude-session');
});

const fixtureSDK = `
export async function* query({ options }) {
  const session_id = 'fixture-claude-session';
  yield { type: 'system', subtype: 'init', session_id, model: 'fixture' };
  const text = JSON.stringify({
    disabled: options.env?.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS,
    custom: options.env?.DIETER_FIXTURE_OPTION,
    effort: options.effort,
    resume: options.resume,
  });
  yield { type: 'stream_event', session_id, event: { type: 'content_block_start', index: 0, content_block: { type: 'text' } } };
  yield { type: 'stream_event', session_id, event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } } };
  yield { type: 'stream_event', session_id, event: { type: 'content_block_stop', index: 0 } };
  yield { type: 'assistant', session_id, message: { content: [{ type: 'text', text }] } };
  yield { type: 'result', subtype: 'success', session_id, result: 'done', usage: { input_tokens: 1, output_tokens: 1 } };
}
`;
