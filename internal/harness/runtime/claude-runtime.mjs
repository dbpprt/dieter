import { createClaudeCode } from '@ai-sdk/harness-claude-code';

const claudePackage = '@anthropic-ai/claude-code';
const claudeInstaller = `node node_modules/${claudePackage}/install.cjs`;

// Dieter substitutes npm for pnpm because pnpm is not a daemon prerequisite.
// Keep lifecycle scripts disabled for the bridge dependency tree, then run the
// one installation step Claude Code requires to select its downloaded native
// optional dependency. This is equivalent to Claude Code's pinned postinstall
// without enabling arbitrary transitive package scripts.
export function createLocalClaudeCode(settings = {}) {
  const harness = createClaudeCode(settings);
  return {
    ...harness,
    async getBootstrap(options) {
      const recipe = await harness.getBootstrap(options);
      const manifestPath = `${recipe.bootstrapDir}/package.json`;
      const manifest = recipe.files.find(file => file.path === manifestPath);
      if (!manifest) throw new Error('Claude Code bridge bootstrap is missing its package manifest');
      const pkg = JSON.parse(manifest.content);
      if (!pkg.dependencies?.[claudePackage]) {
        throw new Error('Claude Code bridge no longer declares its CLI; review the runtime integration');
      }
      const installIndex = recipe.commands.findIndex(({ command }) => command.startsWith('pnpm install'));
      if (installIndex < 0) {
        throw new Error('Claude Code bridge bootstrap no longer uses the expected install command');
      }
      return {
        ...recipe,
        commands: recipe.commands.map((command, index) => index === installIndex ? {
          ...command,
          command: `npm install --ignore-scripts --no-audit --no-fund --prefer-offline && ${claudeInstaller}`,
        } : command),
      };
    },
  };
}
