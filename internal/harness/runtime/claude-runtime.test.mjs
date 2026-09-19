import assert from 'node:assert/strict';
import test from 'node:test';
import {
  CLAUDE_AGENT_SDK_VERSION,
  CLAUDE_CODE_VERSION,
  createLocalClaudeCode,
} from './claude-runtime.mjs';

test('Claude bootstrap pins the current SDK and CLI and installs its native binary safely', async () => {
  const recipe = await createLocalClaudeCode().getBootstrap();
  const manifestPath = `${recipe.bootstrapDir}/package.json`;
  const manifest = recipe.files.find(file => file.path === manifestPath);
  assert(manifest);
  const pkg = JSON.parse(manifest.content);

  assert.equal(pkg.dependencies['@anthropic-ai/claude-agent-sdk'], CLAUDE_AGENT_SDK_VERSION);
  assert.equal(pkg.dependencies['@anthropic-ai/claude-code'], CLAUDE_CODE_VERSION);
  assert.equal(recipe.files.some(file => file.path.endsWith('/pnpm-lock.yaml')), false);
  assert.equal(recipe.files.some(file => file.path.endsWith('/pnpm-workspace.yaml')), false);
  assert.deepEqual(recipe.commands.map(command => command.command), [
    'npm install --ignore-scripts --no-audit --no-fund --prefer-offline --package-lock=false',
    'node node_modules/@anthropic-ai/claude-code/install.cjs',
    './node_modules/.bin/claude --version',
  ]);
});
