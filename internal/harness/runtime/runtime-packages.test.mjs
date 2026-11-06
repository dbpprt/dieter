import assert from "node:assert/strict";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  readlink,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { createACP } from "@ai-sdk/harness-acp";
import { createClaudeCode } from "@ai-sdk/harness-claude-code";
import { createCodex } from "@ai-sdk/harness-codex";
import { createLocalClaudeCode } from "./claude-runtime.mjs";
import { createLocalCodex } from "./codex-runtime.mjs";
import { createLocalOMP, ompPackageName, ompPackageVersion, ompSource } from "./omp-runtime.mjs";
import {
  agentNativePackage,
  linkRuntimePackages,
  runtimeDirectory,
  runtimeLinkedBootstrap,
  verifyAgent,
} from "./runtime-packages.mjs";

const lock = JSON.parse(await readFile(join(runtimeDirectory, "package-lock.json"), "utf8"));
const manifest = JSON.parse(await readFile(join(runtimeDirectory, "package.json"), "utf8"));
const lockedVersion = (name) => lock.packages[`node_modules/${name}`]?.version;

const ompSettings = (source = ompSource()) => ({
  harnessId: "omp",
  source,
  executable: "omp",
  args: ["acp"],
  forwardEnv: ["HOME"],
});

const agentRecipes = async () => ({
  claude: await createLocalClaudeCode().getBootstrap(),
  codex: await createLocalCodex().getBootstrap(),
  omp: await createLocalOMP(ompSettings()).getBootstrap(),
});

const recipeManifest = (recipe, path = "package.json") =>
  JSON.parse(recipe.files.find((file) => file.path === `${recipe.bootstrapDir}/${path}`).content);

test("Claude, Codex and OMP bootstraps link the runtime instead of running a package manager", async () => {
  for (const [agent, recipe] of Object.entries(await agentRecipes())) {
    assert.deepEqual(recipe.commands, [{ command: "node dieter-runtime-link.mjs" }], agent);
    assert(!recipe.files.some((file) => /pnpm-(?:lock|workspace)\.yaml$/.test(file.path)), agent);
    const script = recipe.files.find((file) =>
      file.path.endsWith("/dieter-runtime-link.mjs"),
    ).content;
    for (const text of [script, ...recipe.commands.map((command) => command.command)]) {
      assert.doesNotMatch(text, /\b(?:npm|npx|pnpm|yarn)\b|\bbun (?:install|add)\b/, agent);
    }
    assert.match(script, /runtime-packages\.mjs/);
    const config = JSON.parse(script.match(/bootstrapFromRuntime\((\{.*\})\);/)[1]);
    assert.equal(config.agent, agent);
    assert.equal(config.runtime, await realpath(runtimeDirectory));
  }
});

test("agent versions come from the runtime's package-lock.json", async () => {
  const { claude, codex, omp } = await agentRecipes();
  for (const name of ["@anthropic-ai/claude-agent-sdk", "@openai/codex", ompPackageName]) {
    assert.equal(manifest.dependencies[name], lockedVersion(name), name);
  }
  assert.equal(
    recipeManifest(claude).dependencies["@anthropic-ai/claude-agent-sdk"],
    lockedVersion("@anthropic-ai/claude-agent-sdk"),
  );
  // The SDK bundles the Claude Code executable; the CLI package is not installed.
  assert.equal(recipeManifest(claude).dependencies["@anthropic-ai/claude-code"], undefined);
  assert.equal(manifest.dependencies["@anthropic-ai/claude-code"], undefined);
  assert.equal(recipeManifest(codex).dependencies["@openai/codex"], lockedVersion("@openai/codex"));
  assert.equal(ompPackageVersion(), lockedVersion(ompPackageName));
  assert.deepEqual(recipeManifest(omp, "implementation/package.json").dependencies, {
    [ompPackageName]: lockedVersion(ompPackageName),
  });
  // Each build host installs its own platform packages as optional dependencies.
  for (const name of Object.keys(manifest.dependencies)) {
    assert.doesNotMatch(name, /-(?:darwin|linux|win32)-/, name);
  }
});

function semver(version) {
  const [major, minor, patch] = version.split(/[.+-]/).map(Number);
  return [major, minor, patch];
}

test("the runtime ships every package the adapters' bridges import, no older than they pin", async () => {
  const bridges = {
    "claude-code": await createClaudeCode().getBootstrap(),
    codex: await createCodex().getBootstrap(),
    acp: await createACP(ompSettings()).getBootstrap(),
  };
  for (const [bridge, recipe] of Object.entries(bridges)) {
    for (const [name, pinned] of Object.entries(recipeManifest(recipe).dependencies)) {
      // Dieter runs Claude Code from the SDK's own platform package.
      if (name === "@anthropic-ai/claude-code") continue;
      const installed = lockedVersion(name);
      assert(installed, `${bridge} bridge needs ${name}, which the runtime does not ship`);
      const [have, want] = [semver(installed), semver(pinned)];
      assert.equal(
        have[0],
        want[0],
        `${bridge} bridge pins ${name}@${pinned}; runtime ships ${installed}`,
      );
      assert(
        have[1] > want[1] || (have[1] === want[1] && have[2] >= want[2]),
        `${bridge} bridge pins ${name}@${pinned}; runtime ships older ${installed}`,
      );
    }
  }
});

test("OMP bootstrap refuses an agent version the runtime does not ship", async () => {
  const harness = createLocalOMP(ompSettings({ ...ompSource(), packageVersion: "1.0.0" }));
  await assert.rejects(
    () => harness.getBootstrap(),
    new RegExp(
      `@oh-my-pi/pi-coding-agent@1\\.0\\.0 was requested, but the harness runtime ships ${ompPackageVersion().replaceAll(".", "\\.")}`,
    ),
  );
});

async function writeFixturePackage(runtime, name, packageManifest, files = {}) {
  const directory = join(runtime, "node_modules", ...name.split("/"));
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "package.json"), JSON.stringify({ name, ...packageManifest }));
  for (const [path, { content, mode = 0o644 }] of Object.entries(files)) {
    await mkdir(dirname(join(directory, path)), { recursive: true });
    await writeFile(join(directory, path), content, { mode });
  }
  return directory;
}

async function fixtureRuntime(t) {
  const runtime = await realpath(await mkdtemp(join(tmpdir(), "dieter-runtime-packages-")));
  t.after(() => rm(runtime, { recursive: true, force: true }));
  return runtime;
}

test("linking replaces a stale bootstrap tree with links to exactly the runtime's packages", async (t) => {
  const runtime = await fixtureRuntime(t);
  const tool = await writeFixturePackage(
    runtime,
    "@scope/tool",
    { version: "1.2.3", bin: { tool: "./bin/tool.js" } },
    {
      "bin/tool.js": { content: "#!/usr/bin/env node\n", mode: 0o755 },
    },
  );
  const library = await writeFixturePackage(runtime, "library", { version: "4.5.6" });
  const bootstrap = join(runtime, "..", `${runtime.split("/").pop()}-bootstrap`);
  t.after(() => rm(bootstrap, { recursive: true, force: true }));
  // An npm-installed tree plus a link into a runtime that no longer exists.
  await mkdir(join(bootstrap, "node_modules", "stale-transitive"), { recursive: true });
  await writeFile(join(bootstrap, "node_modules", "stale-transitive", "index.js"), "");
  await symlink(
    join(bootstrap, "removed-runtime", "library"),
    join(bootstrap, "node_modules", "library"),
  );
  await mkdir(join(bootstrap, ".node_modules-00000000-0000-4000-8000-000000000000.tmp"));

  await linkRuntimePackages(bootstrap, ["@scope/tool", "library"], { runtime });
  const modules = join(bootstrap, "node_modules");
  assert.deepEqual((await readdir(modules)).sort(), [".bin", "@scope", "library"]);
  assert.equal(await realpath(join(modules, "@scope", "tool")), tool);
  assert.equal(await realpath(join(modules, "library")), library);
  assert.equal(await readlink(join(modules, ".bin", "tool")), "../@scope/tool/bin/tool.js");
  assert.equal(await realpath(join(modules, ".bin", "tool")), join(tool, "bin", "tool.js"));
  assert.deepEqual(await readdir(bootstrap), ["node_modules"]);
  assert((await lstat(join(modules, "library"))).isSymbolicLink());

  await assert.rejects(
    () => linkRuntimePackages(bootstrap, ["missing"], { runtime }),
    /harness runtime does not include missing/,
  );
  assert.equal(
    await realpath(join(modules, "library")),
    library,
    "a failed link keeps the previous tree",
  );
});

test("a bridge needing a package the runtime lacks fails while building its recipe", async (t) => {
  const runtime = await fixtureRuntime(t);
  await writeFixturePackage(runtime, "@openai/codex", { version: "1.0.0" });
  const recipe = await createCodex().getBootstrap();
  assert.throws(
    () => runtimeLinkedBootstrap(recipe, { agent: "codex", requires: ["@openai/codex"], runtime }),
    /Codex bridge needs ws, which Dieter's harness runtime does not include/,
  );
});

async function fixtureAgents(
  t,
  { claude = "9.9.9 (Claude Code)", codex = "codex-cli 1.2.3", omp = "omp/7.8.9" } = {},
) {
  const runtime = await fixtureRuntime(t);
  const host = { platform: "linux", arch: "x64", libc: "glibc" };
  await writeFixturePackage(runtime, "@anthropic-ai/claude-agent-sdk", {
    version: "0.9.9",
    claudeCodeVersion: "9.9.9",
  });
  await writeFixturePackage(
    runtime,
    agentNativePackage("claude", host),
    { version: "0.9.9" },
    {
      claude: { content: `#!/bin/sh\nprintf '%s\\n' '${claude}'\n`, mode: 0o755 },
    },
  );
  await writeFixturePackage(
    runtime,
    "@openai/codex",
    { version: "1.2.3" },
    {
      "bin/codex.js": { content: `console.log(${JSON.stringify(codex)});\n` },
    },
  );
  await writeFixturePackage(runtime, agentNativePackage("codex", host), {
    version: "1.2.3-linux-x64",
  });
  await writeFixturePackage(
    runtime,
    ompPackageName,
    { version: "7.8.9" },
    {
      "dist/cli.js": { content: `#!/bin/sh\nprintf '%s\\n' '${omp}'\n`, mode: 0o755 },
    },
  );
  await writeFixturePackage(runtime, "@oh-my-pi/pi-natives", { version: "7.8.9" });
  await writeFixturePackage(runtime, agentNativePackage("omp", host), { version: "7.8.9" });
  await mkdir(join(runtime, "node_modules", ".bin"));
  await symlink(
    "../@oh-my-pi/pi-coding-agent/dist/cli.js",
    join(runtime, "node_modules", ".bin", "omp"),
  );
  return { runtime, host };
}

test("agent verification reports each CLI's pinned version and this host's native package", async (t) => {
  const { runtime, host } = await fixtureAgents(t);
  assert.deepEqual(await verifyAgent("claude", { runtime, host }), {
    package: "@anthropic-ai/claude-agent-sdk",
    packageVersion: "0.9.9",
    version: "9.9.9",
    native: "@anthropic-ai/claude-agent-sdk-linux-x64",
  });
  assert.equal((await verifyAgent("codex", { runtime, host })).version, "1.2.3");
  assert.equal(
    (await verifyAgent("omp", { runtime, host })).native,
    "@oh-my-pi/pi-natives-linux-x64",
  );
});

test("agent verification fails clearly on a missing native package or a version mismatch", async (t) => {
  const { runtime } = await fixtureAgents(t, { codex: "codex-cli 1.2.2" });
  const musl = { platform: "linux", arch: "x64", libc: "musl" };
  await assert.rejects(
    () => verifyAgent("claude", { runtime, host: musl }),
    /Claude Code needs @anthropic-ai\/claude-agent-sdk-linux-x64-musl on linux-x64 \(musl\), but this harness runtime does not include it; Dieter's release runtimes are built on glibc Linux/,
  );
  await assert.rejects(
    () => verifyAgent("omp", { runtime, host: musl }),
    /no native addon .* for musl Linux/,
  );
  await assert.rejects(
    () => verifyAgent("claude", { runtime, host: { platform: "darwin", arch: "arm64" } }),
    /needs @anthropic-ai\/claude-agent-sdk-darwin-arm64 on darwin-arm64/,
  );
  await assert.rejects(
    () =>
      verifyAgent("codex", { runtime, host: { platform: "linux", arch: "x64", libc: "glibc" } }),
    /Codex reported "codex-cli 1\.2\.2"; the runtime pins 1\.2\.3/,
  );
});

test("this host's Claude Code and Codex executables run at the locked versions", async () => {
  const claude = await verifyAgent("claude");
  assert.equal(claude.packageVersion, lockedVersion("@anthropic-ai/claude-agent-sdk"));
  assert.equal(
    claude.version,
    JSON.parse(
      await readFile(
        join(runtimeDirectory, "node_modules/@anthropic-ai/claude-agent-sdk/package.json"),
        "utf8",
      ),
    ).claudeCodeVersion,
  );
  assert.equal((await verifyAgent("codex")).version, lockedVersion("@openai/codex"));
});
