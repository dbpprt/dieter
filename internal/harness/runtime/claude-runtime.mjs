import { createClaudeCode } from '@ai-sdk/harness-claude-code';

function nativeClaudePackage() {
  const platform = process.platform;
  const arch = process.arch;
  const libc = platform === 'linux' && !process.report?.getReport()?.header.glibcVersionRuntime ? '-musl' : '';
  return `@anthropic-ai/claude-code-${platform}-${arch}${libc}`;
}

export const CLAUDE_AGENT_SDK_VERSION = '0.3.280';
export const CLAUDE_CODE_VERSION = '2.1.280';

// The adapter ships a version-locked bridge recipe independently of Dieter's
// lockfile. Keep the adapter transport and bridge, but move its Anthropic
// runtime pins forward explicitly so a harness package release cannot leave
// Dieter on a stale Claude CLI.
export function createLocalClaudeCode(settings = {}) {
  const harness = createClaudeCode({
    ...settings,
    // The bridge closes its query at the final result; native background
    // task notifications cannot resume a completed Dieter turn. Keep Bash
    // and Agent calls foreground and use Dieter's tools for durable processes.
    env: { ...settings.env, CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1' },
  });
  return {
    ...harness,
    async getBootstrap(options) {
      const recipe = await harness.getBootstrap(options);
      const manifestPath = `${recipe.bootstrapDir}/package.json`;
      const manifest = recipe.files.find(file => file.path === manifestPath);
      if (!manifest) throw new Error('Claude bridge bootstrap is missing its package manifest');
      const pkg = JSON.parse(manifest.content);
      if (!pkg.dependencies?.['@anthropic-ai/claude-agent-sdk'] || !pkg.dependencies?.['@anthropic-ai/claude-code']) {
        throw new Error('Claude bridge no longer declares its SDK and CLI; review the runtime integration');
      }
      pkg.dependencies['@anthropic-ai/claude-agent-sdk'] = CLAUDE_AGENT_SDK_VERSION;
      pkg.dependencies['@anthropic-ai/claude-code'] = CLAUDE_CODE_VERSION;
      // The wrapper's postinstall exits successfully when an optional native
      // package was omitted. Make this host's binary required so npm cannot
      // accept a stub CLI as a successful bootstrap.
      pkg.dependencies[nativeClaudePackage()] = CLAUDE_CODE_VERSION;
      return {
        ...recipe,
        files: recipe.files
          .filter(file => !file.path.endsWith('/pnpm-lock.yaml') && !file.path.endsWith('/pnpm-workspace.yaml'))
          .map(file => file.path === manifestPath ? { ...file, content: `${JSON.stringify(pkg, null, 2)}\n` } : file),
        commands: [
          { command: 'npm install --ignore-scripts --include=optional --no-audit --no-fund --package-lock=false' },
          // Dieter skips arbitrary dependency lifecycle scripts. Claude's
          // audited installer is required to materialize its optional native
          // binary, so invoke that one known script explicitly.
          { command: 'node node_modules/@anthropic-ai/claude-code/install.cjs' },
          { command: './node_modules/.bin/claude --version' },
        ],
      };
    },
  };
}
