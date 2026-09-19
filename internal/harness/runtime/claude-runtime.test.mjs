import assert from 'node:assert/strict';
import test from 'node:test';
import { createClaudeCode } from '@ai-sdk/harness-claude-code';
import { createLocalClaudeCode } from './claude-runtime.mjs';

test('Claude bootstrap installs its pinned native CLI with only the required lifecycle script', async () => {
  const original = await createClaudeCode().getBootstrap();
  const recipe = await createLocalClaudeCode({ model: 'sonnet', effort: 'high' }).getBootstrap();
  const manifest = JSON.parse(recipe.files.find(file => file.path.endsWith('/package.json')).content);

  assert.match(manifest.dependencies['@anthropic-ai/claude-code'], /^\d+\.\d+\.\d+$/);
  assert.match(recipe.commands[0].command, /^npm install /);
  assert.match(recipe.commands[0].command, /--ignore-scripts/);
  assert.match(recipe.commands[0].command, /node_modules\/@anthropic-ai\/claude-code\/install\.cjs/);
  assert.equal(recipe.commands[1].command, './node_modules/.bin/claude --version');
  assert.equal(recipe.files.find(file => file.path.endsWith('/bridge.mjs')).content,
    original.files.find(file => file.path.endsWith('/bridge.mjs')).content);
});
