import { createCodex } from '@ai-sdk/harness-codex';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// The adapter's bridge pins its own older CLI independently of Dieter's npm
// lockfile. Point its local bootstrap at our locked CLI package and keep the
// adapter's transport, session resume, tools, and bridge unchanged.
const codexRoot = dirname(fileURLToPath(import.meta.resolve('@openai/codex/package.json')));
const websocketRoot = dirname(fileURLToPath(import.meta.resolve('ws/package.json')));

export function createLocalCodex(settings = {}) {
  // Ultra is a CLI orchestration mode, not a Responses API effort. Codex 0.159
  // advertises it, but this adapter's protocol enum stops at max. Its supported
  // arbitrary config channel reaches the same CLI setting without narrowing it.
  const harness = createCodex(settings.reasoningEffort === 'ultra' ? {
    ...settings,
    reasoningEffort: undefined,
    codexConfig: { ...settings.codexConfig, model_reasoning_effort: 'ultra' },
  } : settings);
  return {
    ...harness,
    async getBootstrap(options) {
      const recipe = await harness.getBootstrap(options);
      const manifestPath = `${recipe.bootstrapDir}/package.json`;
      const manifest = recipe.files.find(file => file.path === manifestPath);
      if (!manifest) throw new Error('Codex bridge bootstrap is missing its package manifest');
      const pkg = JSON.parse(manifest.content);
      if (!pkg.dependencies?.['@openai/codex']) {
        throw new Error('Codex bridge no longer declares its CLI; review the runtime integration');
      }
      pkg.dependencies['@openai/codex'] = `file:${codexRoot}`;
      pkg.dependencies.ws = `file:${websocketRoot}`;
      return {
        ...recipe,
        files: recipe.files
          .filter(file => file.path !== `${recipe.bootstrapDir}/pnpm-lock.yaml`)
          .map(file => file.path === manifestPath ? { ...file, content: `${JSON.stringify(pkg, null, 2)}\n` } : file),
        // Both are already pinned/installed in Dieter's runtime; bootstrap is
        // local linking only and cannot silently fetch a different CLI.
        commands: [{ command: 'npm install --offline --ignore-scripts --no-audit --no-fund --package-lock=false' }],
      };
    },
  };
}
