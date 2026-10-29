import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { mkdir, readdir, rename, rm, symlink } from "node:fs/promises";
import { dirname, join, posix, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

// Dieter's harness runtime ships every agent CLI, and every package an
// adapter's bridge imports, in its own node_modules: a release daemon extracts
// them from its prebuilt archive and a source build installs them with
// `npm ci`. Bridge bootstraps link those packages instead of installing
// anything, so package-lock.json is the only place an agent version lives and
// a daemon host needs Node.js but never npm for Claude, Codex or OMP.
export const runtimeDirectory = dirname(fileURLToPath(import.meta.url));

const moduleSource = readFileSync(fileURLToPath(import.meta.url));
const moduleDigest = createHash("sha256").update(moduleSource).digest("hex");

export const agentPackages = Object.freeze({
  claude: "@anthropic-ai/claude-agent-sdk",
  codex: "@openai/codex",
  omp: "@oh-my-pi/pi-coding-agent",
});

const agentLabels = Object.freeze({ claude: "Claude Code", codex: "Codex", omp: "OMP" });

function inside(path, root) {
  const offset = relative(root, path);
  return (
    offset === "" || (!offset.startsWith(`..${sep}`) && offset !== ".." && !offset.startsWith(sep))
  );
}

/**
 * Resolve an installed package the way Node does from `from` (default: the
 * runtime itself), ignoring package "exports" and never leaving the runtime.
 * Returns null when the runtime does not include it.
 */
export function findRuntimePackage(name, { from, runtime = runtimeDirectory } = {}) {
  const top = realpathSync(runtime);
  let directory = realpathSync(from ?? top);
  if (!inside(directory, top))
    throw new Error(`${directory} is outside the harness runtime ${top}`);
  for (;;) {
    const candidate = join(directory, "node_modules", ...name.split("/"));
    const manifestPath = join(candidate, "package.json");
    if (existsSync(manifestPath)) {
      return {
        name,
        directory: realpathSync(candidate),
        manifest: JSON.parse(readFileSync(manifestPath, "utf8")),
      };
    }
    if (directory === top) return null;
    directory = dirname(directory);
  }
}

export function requireRuntimePackage(name, options) {
  const found = findRuntimePackage(name, options);
  if (!found) throw new Error(`Dieter's harness runtime does not include ${name}`);
  return found;
}

/** The installed version of a package the runtime ships (package-lock.json). */
export function runtimePackageVersion(name, options) {
  return requireRuntimePackage(name, options).manifest.version;
}

export function hostPlatform() {
  const libc =
    process.platform === "linux"
      ? process.report?.getReport()?.header?.glibcVersionRuntime
        ? "glibc"
        : "musl"
      : undefined;
  return { platform: process.platform, arch: process.arch, libc };
}

function hostName({ platform, arch, libc }) {
  return `${platform}-${arch}${libc ? ` (${libc})` : ""}`;
}

/**
 * The platform package holding an agent's native executable or addon. npm
 * installs only the host's own as an optional dependency, so a runtime built
 * on another platform (or libc) lacks it; report that instead of letting the
 * agent fail or fall back silently.
 */
export function agentNativePackage(agent, host = hostPlatform()) {
  const { platform, arch, libc } = host;
  switch (agent) {
    case "claude":
      return `@anthropic-ai/claude-agent-sdk-${platform}-${arch}${libc === "musl" ? "-musl" : ""}`;
    case "codex":
      // Codex's Linux executables are static musl builds serving both libcs.
      return `@openai/codex-${platform}-${arch}`;
    case "omp":
      if (libc === "musl") {
        throw new Error(
          "OMP publishes no native addon (@oh-my-pi/pi-natives) for musl Linux; run OMP on glibc Linux or macOS",
        );
      }
      return `@oh-my-pi/pi-natives-${platform}-${arch}`;
    default:
      throw new Error(`unknown agent ${JSON.stringify(agent)}`);
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function commandOutput(file, args, env) {
  return new Promise((resolveOutput, reject) => {
    execFile(file, args, { env, timeout: 120_000, maxBuffer: 1 << 20 }, (error, stdout, stderr) => {
      if (error) {
        const detail = `${stderr}`.trim() || error.message;
        reject(new Error(`${[file, ...args].join(" ")} failed: ${detail}`));
      } else {
        resolveOutput(`${stdout}`.trim());
      }
    });
  });
}

/**
 * Check that an agent's CLI and this host's native package are installed and
 * that the CLI reports the version the runtime pins. `entry` is the directory
 * whose node_modules serves the CLI (the runtime, or a linked bridge).
 */
export async function verifyAgent(
  agent,
  { runtime = runtimeDirectory, entry = runtime, host = hostPlatform(), env = process.env } = {},
) {
  const label = agentLabels[agent];
  const packageName = agentPackages[agent];
  if (!packageName) throw new Error(`unknown agent ${JSON.stringify(agent)}`);
  const agentPackage = requireRuntimePackage(packageName, { runtime });
  const nativeName = agentNativePackage(agent, host);
  const nativeFrom =
    agent === "omp"
      ? requireRuntimePackage("@oh-my-pi/pi-natives", { from: agentPackage.directory, runtime })
          .directory
      : agentPackage.directory;
  const native = findRuntimePackage(nativeName, { from: nativeFrom, runtime });
  if (!native) {
    throw new Error(
      `${label} needs ${nativeName} on ${hostName(host)}, but this harness runtime does not include it` +
        (host.libc === "musl"
          ? "; Dieter's release runtimes are built on glibc Linux"
          : "; reinstall the runtime on this platform"),
    );
  }
  let version;
  let file;
  let args;
  let expected;
  switch (agent) {
    case "claude":
      // The SDK runs the Claude Code executable from its platform package and
      // declares which Claude Code release that executable is.
      version = agentPackage.manifest.claudeCodeVersion;
      if (typeof version !== "string" || !version) {
        throw new Error(`${packageName} no longer declares claudeCodeVersion`);
      }
      file = join(native.directory, "claude");
      args = ["--version"];
      expected = new RegExp(`^${escapeRegExp(version)}(?:\\s|$)`);
      break;
    case "codex":
      version = agentPackage.manifest.version;
      file = process.execPath;
      args = [join(entry, "node_modules", "@openai", "codex", "bin", "codex.js"), "--version"];
      expected = new RegExp(`^codex-cli ${escapeRegExp(version)}$`);
      break;
    case "omp":
      // OMP's executable is a Bun script; the caller puts the managed Bun on PATH.
      version = agentPackage.manifest.version;
      file = join(entry, "node_modules", ".bin", "omp");
      args = ["--version"];
      expected = new RegExp(`^omp/${escapeRegExp(version)}$`);
      break;
  }
  const output = await commandOutput(file, args, env);
  if (!expected.test(output)) {
    throw new Error(`${label} reported ${JSON.stringify(output)}; the runtime pins ${version}`);
  }
  return {
    package: packageName,
    packageVersion: agentPackage.manifest.version,
    version,
    native: nativeName,
  };
}

function packageBins({ name, manifest }) {
  const declared =
    typeof manifest.bin === "string" ? { [name.split("/").pop()]: manifest.bin } : manifest.bin;
  return Object.entries(declared ?? {}).flatMap(([command, target]) => {
    const normalized = posix.normalize(String(target));
    if (
      !/^[A-Za-z0-9._-]+$/.test(command) ||
      normalized.startsWith("..") ||
      posix.isAbsolute(normalized)
    ) {
      return [];
    }
    return [[command, posix.join("..", name, normalized)]];
  });
}

const swapEntry = /^\.node_modules-[0-9a-f-]{36}\.(?:tmp|stale)$/;

/**
 * Make directory/node_modules hold exactly a link to each named runtime
 * package (and its executables in .bin), then verify every link resolves to
 * the current runtime. The new tree is staged beside node_modules and swapped
 * in, so a stale tree from an older bootstrap (npm-installed or linked to a
 * removed runtime) is replaced as a whole. The caller serializes bootstraps.
 */
export async function linkRuntimePackages(directory, names, { runtime = runtimeDirectory } = {}) {
  const packages = names.map((name) => requireRuntimePackage(name, { runtime }));
  await mkdir(directory, { recursive: true });
  for (const entry of await readdir(directory)) {
    if (swapEntry.test(entry)) await rm(join(directory, entry), { recursive: true, force: true });
  }
  const modules = join(directory, "node_modules");
  const staged = join(directory, `.node_modules-${randomUUID()}.tmp`);
  try {
    await mkdir(staged);
    for (const runtimePackage of packages) {
      const link = join(staged, ...runtimePackage.name.split("/"));
      await mkdir(dirname(link), { recursive: true });
      await symlink(runtimePackage.directory, link, "dir");
      for (const [command, target] of packageBins(runtimePackage)) {
        await mkdir(join(staged, ".bin"), { recursive: true });
        await symlink(target, join(staged, ".bin", command));
      }
    }
    const stale = join(directory, `.node_modules-${randomUUID()}.stale`);
    let replaced = true;
    try {
      await rename(modules, stale);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      replaced = false;
    }
    await rename(staged, modules);
    if (replaced) await rm(stale, { recursive: true, force: true });
  } finally {
    await rm(staged, { recursive: true, force: true });
  }
  for (const runtimePackage of packages) {
    const link = join(modules, ...runtimePackage.name.split("/"));
    let actual = null;
    try {
      actual = realpathSync(link);
    } catch {}
    if (actual !== runtimePackage.directory) {
      throw new Error(`${link} does not resolve to ${runtimePackage.directory}`);
    }
  }
}

/** The bootstrap command: link every bridge directory, then verify the agent. */
export async function bootstrapFromRuntime({ runtime, links, agent, entry = "." }) {
  for (const { directory, packages } of links) {
    await linkRuntimePackages(resolve(directory), packages, { runtime });
  }
  return verifyAgent(agent, { runtime, entry: resolve(entry) });
}

const linkScriptName = "dieter-runtime-link.mjs";

/**
 * Replace an adapter's bootstrap recipe, which installs its bridge's pinned
 * dependencies with a package manager, by one that links them from this
 * runtime. The adapter's bridge sources stay unchanged. Every dependency a
 * bridge manifest declares must be one the runtime ships (except `omit`);
 * `implementation` manifests (an ACP agent package) must name exactly the
 * runtime's version. The recipe identity covers the runtime path, the linked
 * versions and this module, so an update relinks once.
 */
export function runtimeLinkedBootstrap(
  recipe,
  { agent, requires = [], omit = [], implementation = false, runtime = runtimeDirectory },
) {
  const label = agentLabels[agent];
  if (!label) throw new Error(`unknown agent ${JSON.stringify(agent)}`);
  const { bootstrapDir } = recipe;
  const manifests = [{ directory: ".", path: `${bootstrapDir}/package.json`, exact: false }];
  if (implementation) {
    manifests.push({
      directory: "implementation",
      path: `${bootstrapDir}/implementation/package.json`,
      exact: true,
    });
  }
  const links = [];
  const rewritten = new Map();
  for (const { directory, path, exact } of manifests) {
    const file = recipe.files.find((candidate) => candidate.path === path);
    if (!file)
      throw new Error(
        `${label} bridge bootstrap is missing ${path}; review the runtime integration`,
      );
    const manifest = JSON.parse(file.content);
    const declared = manifest.dependencies ?? {};
    for (const name of directory === "." ? requires : []) {
      if (!(name in declared)) {
        throw new Error(
          `${label} bridge no longer declares ${name}; review the runtime integration`,
        );
      }
    }
    const dependencies = {};
    for (const [name, version] of Object.entries(declared)) {
      if (omit.includes(name)) continue;
      const runtimePackage = findRuntimePackage(name, { runtime });
      if (!runtimePackage) {
        throw new Error(
          `${label} bridge needs ${name}, which Dieter's harness runtime does not include; add it to the runtime's package.json`,
        );
      }
      if (exact && version !== runtimePackage.manifest.version) {
        throw new Error(
          `${label} ${name}@${version} was requested, but the harness runtime ships ${runtimePackage.manifest.version}`,
        );
      }
      dependencies[name] = runtimePackage.manifest.version;
    }
    links.push({ directory, packages: Object.keys(dependencies) });
    rewritten.set(path, `${JSON.stringify({ ...manifest, dependencies }, null, 2)}\n`);
  }
  const config = {
    runtime: realpathSync(runtime),
    links,
    agent,
    entry: implementation ? "implementation" : ".",
  };
  const script = `// Generated by Dieter: link this bridge's packages from the harness runtime.
// runtime-packages.mjs sha256 ${moduleDigest}
import { bootstrapFromRuntime } from ${JSON.stringify(import.meta.url)};
try {
  await bootstrapFromRuntime(${JSON.stringify(config)});
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
`;
  return {
    ...recipe,
    files: [
      ...recipe.files
        .filter((file) => !/(?:^|\/)pnpm-(?:lock|workspace)\.yaml$/.test(file.path))
        .map((file) =>
          rewritten.has(file.path) ? { ...file, content: rewritten.get(file.path) } : file,
        ),
      { path: `${bootstrapDir}/${linkScriptName}`, content: script },
    ],
    commands: [{ command: `node ${linkScriptName}` }],
  };
}
