import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  chmod,
  mkdtemp,
  mkdir,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { HarnessAgent } from "@ai-sdk/harness/agent";
import {
  CLAUDE_DESIGN_TOOLS,
  claudeDesignEnvironment,
  claudeDesignInactiveTools,
  claudeDesignInstructions,
} from "./claude-design.mjs";
import { createLocalClaudeCode } from "./claude-runtime.mjs";
import { createLocalSandboxProvider } from "./local-sandbox.mjs";

const runtimeDirectory = dirname(fileURLToPath(import.meta.url));

test("Claude Design stays off unless the daemon enables it for a Claude Code turn", () => {
  assert.deepEqual(claudeDesignInactiveTools({}, 'claude-code'), ['DesignSync', 'ClaudeDesign', 'Artifact', 'ArtifactComments', 'ArtifactData', 'ArtifactCheck']);
  assert.deepEqual(claudeDesignEnvironment({}, 'claude-code'), {});
  assert.deepEqual(claudeDesignEnvironment({ claudeDesignEnabled: true }, 'claude-code'), { CLAUDE_CODE_ARTIFACT: '1' });
  assert.deepEqual(claudeDesignEnvironment({ claudeDesignEnabled: true }, 'codex'), {});
  assert.equal(claudeDesignInactiveTools({ claudeDesignEnabled: true }, "claude-code"), undefined);
  assert.equal(claudeDesignInactiveTools({}, "codex"), undefined);
  assert.equal(claudeDesignInstructions({}, "claude-code"), "");
  assert.equal(claudeDesignInstructions({ claudeDesignEnabled: true }, "codex"), "");
  const enabled = claudeDesignInstructions(
    { claudeDesignEnabled: true, contentPresentationEnabled: true },
    "claude-code",
  );
  assert.match(enabled, /Artifact tool/);
  assert.match(enabled, /present_content with its https:\/\/claude\.ai\/code\/artifact\/<id>/);
  assert.doesNotMatch(
    claudeDesignInstructions({ claudeDesignEnabled: true }, "claude-code"),
    /present_content/,
  );
});

test("the Claude runtime declares both Claude Design tools so turns can deny them", () => {
  const harness = createLocalClaudeCode();
  for (const name of CLAUDE_DESIGN_TOOLS)
    assert.ok(harness.builtinTools[name], `${name} is not a declared builtin`);
  assert.equal(harness.builtinTools.ClaudeDesign.toolUseKind, "edit");
});

test(
  "denied Claude Design tools reach the Claude SDK as disallowed tools",
  { timeout: 30_000 },
  async (t) => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "dieter-claude-design-")));
    const previousHome = process.env.HOME;
    process.env.HOME = root;
    const sessions = [];
    let sandbox;
    t.after(async () => {
      try {
        for (const session of sessions) await session.stop();
      } finally {
        if (previousHome === undefined) delete process.env.HOME;
        else process.env.HOME = previousHome;
        await sandbox?.stopAll();
        await rm(root, { recursive: true, force: true });
      }
    });
    const projectPath = join(root, "project");
    await mkdir(projectPath);
    sandbox = await createLocalSandboxProvider({ root, projectPath });
    const harness = createLocalClaudeCode({
      auth: { ANTHROPIC_API_KEY: "dieter-disposable-fixture" },
    });
    const recipe = await harness.getBootstrap();
    const bootstrap = join(root, ".ai-sdk-harness", recipe.bootstrapDir);
    await mkdir(bootstrap, { recursive: true });
    await symlink(join(runtimeDirectory, "node_modules"), join(bootstrap, "node_modules"), "dir");
    const bridge = recipe.files.find((file) => file.path.endsWith("/bridge.mjs"));
    // Offline SDK fixture: no provider install, credentials or inference.
    const fixtureHarness = {
      ...harness,
      getBootstrap: async () => ({
        ...recipe,
        files: [
          {
            ...bridge,
            content: bridge.content.replace(
              'from "@anthropic-ai/claude-agent-sdk"',
              'from "./fixture-sdk.mjs"',
            ),
          },
          { path: `${recipe.bootstrapDir}/fixture-sdk.mjs`, content: fixtureSDK },
        ],
        commands: [],
      }),
    };
    async function disallowed(request, sessionId) {
      const inactiveTools = claudeDesignInactiveTools(request, "claude-code");
      const agent = new HarnessAgent({
        harness: fixtureHarness,
        sandbox,
        permissionMode: "allow-all",
        sandboxConfig: { workDir: "repo" },
        ...(inactiveTools ? { inactiveTools } : {}),
      });
      // The local sandbox owns one bridge port; finish each session first.
      const session = await agent.createSession({ sessionId });
      sessions.push(session);
      const result = await agent.stream({ session, prompt: "Report the SDK options." });
      let text = "";
      for await (const part of result.stream) {
        if (part.type === "error") throw part.error;
        if (part.type === "text-delta") text += part.text;
      }
      await sessions.pop().stop();
      return JSON.parse(text).disallowedTools;
    }
    assert.deepEqual([...(await disallowed({}, "design-off"))].sort(), [
      "Artifact",
      "ArtifactCheck",
      "ArtifactComments",
      "ArtifactData",
      "ClaudeDesign",
      "DesignSync",
    ]);
    assert.deepEqual(await disallowed({ claudeDesignEnabled: true }, "design-on"), []);
  },
);

const fixtureSDK = `
export async function* query({ options }) {
  const session_id = 'fixture-claude-design';
  yield { type: 'system', subtype: 'init', session_id, model: 'fixture' };
  const text = JSON.stringify({ disallowedTools: options.disallowedTools ?? [] });
  yield { type: 'stream_event', session_id, event: { type: 'content_block_start', index: 0, content_block: { type: 'text' } } };
  yield { type: 'stream_event', session_id, event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } } };
  yield { type: 'stream_event', session_id, event: { type: 'content_block_stop', index: 0 } };
  yield { type: 'assistant', session_id, message: { content: [{ type: 'text', text }] } };
  yield { type: 'result', subtype: 'success', session_id, result: 'done', usage: { input_tokens: 1, output_tokens: 1 } };
}
`;

// A fake pinned CLI under a disposable HOME. It records its argv so the test
// can prove the access commands run without tools and with one turn at most.
async function fakeClaudeHome(t, { version = "2.1.285", revoke = "granted" } = {}) {
  const home = await realpath(await mkdtemp(join(tmpdir(), "dieter-claude-design-host-")));
  t.after(() => rm(home, { recursive: true, force: true }));
  const recipe = await createLocalClaudeCode().getBootstrap({});
  const bin = join(home, ".ai-sdk-harness", recipe.bootstrapDir, "node_modules", ".bin");
  await mkdir(bin, { recursive: true });
  const revokeResult =
    revoke === "granted"
      ? "Design agent access revoked for your Claude Design projects."
      : "Could not revoke Design agent access for your Claude Design projects.";
  await writeFile(
    join(bin, "claude"),
    `#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/argv.log"
case "$1" in
--version) echo "${version} (Claude Code)" ;;
design-login) echo '{"available":true,"signed_in":true,"can_sign_in_here":true}' ;;
-p)
  case "$2" in
  /design-consent) echo '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Design agent access granted for your Claude Design projects. Use /design revoke to undo."}' ;;
  /design-revoke) echo '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"${revokeResult}"}' ;;
  esac ;;
esac
`,
  );
  await chmod(join(bin, "claude"), 0o700);
  return home;
}

function host(home, command) {
  return new Promise((resolveHost) => {
    execFile(
      process.execPath,
      [join(runtimeDirectory, "claude-design-host.mjs"), command, join(home, "state")],
      {
        cwd: runtimeDirectory,
        env: { PATH: process.env.PATH, HOME: home },
      },
      (error, stdout) =>
        resolveHost({
          code: error ? error.code : 0,
          value: JSON.parse(stdout.trim().split("\n").pop()),
        }),
    );
  });
}

test(
  "the host helper reports Claude Design status from the pinned CLI",
  { timeout: 30_000 },
  async (t) => {
    const home = await fakeClaudeHome(t);
    const { code, value } = await host(home, "status");
    assert.equal(code, 0);
    assert.deepEqual(value, {
      runtimeReady: true,
      version: "2.1.285",
      available: true,
      signedIn: true,
      canSignIn: true,
      reason: "",
    });

    const stale = await fakeClaudeHome(t, { version: "2.1.200" });
    const missing = await host(stale, "status");
    assert.equal(missing.value.runtimeReady, false);
    assert.equal(missing.value.available, false);
    assert.match(missing.value.reason, /2\.1\.285/);
  },
);

test(
  "the host helper grants and revokes agent access without tools or model turns",
  { timeout: 30_000 },
  async (t) => {
    const home = await fakeClaudeHome(t, { revoke: "failed" });
    const granted = await host(home, "consent");
    assert.equal(granted.code, 0);
    assert.equal(granted.value.ok, true);
    assert.match(granted.value.message, /^Design agent access granted/);
    const revoked = await host(home, "revoke");
    assert.equal(revoked.code, 1);
    assert.equal(revoked.value.ok, false);
    assert.match(revoked.value.message, /Could not revoke/);
    const argv = (await readFile(join(home, "argv.log"), "utf8")).split("\n");
    const consent = argv.find((line) => line.startsWith("-p /design-consent"));
    assert.ok(consent, argv.join("\n"));
    assert.match(consent, /--tools {2}--max-turns 1/);
    assert.match(consent, /--no-session-persistence --strict-mcp-config/);
  },
);
