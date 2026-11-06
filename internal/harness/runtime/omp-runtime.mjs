import { createACP } from "./acp-runtime.mjs";
import { runtimeLinkedBootstrap, runtimePackageVersion } from "./runtime-packages.mjs";

export const ompPackageName = "@oh-my-pi/pi-coding-agent";

// OMP runs at the version Dieter's runtime ships (package-lock.json). The ACP
// lifecycle identity names it, as it always has.
export function ompPackageVersion() {
  return runtimePackageVersion(ompPackageName);
}

export function ompSource() {
  return { type: "npm-simple", packageName: ompPackageName, packageVersion: ompPackageVersion() };
}

// The ACP adapter installs its bridge and the agent package with a package
// manager. Link both from Dieter's runtime instead; the managed Bun on PATH
// executes OMP.
export function createLocalOMP(settings) {
  const harness = createACP(settings);
  return {
    ...harness,
    async getBootstrap(options) {
      const recipe = await harness.getBootstrap(options);
      const linked = runtimeLinkedBootstrap(
        {
          ...recipe,
          files: [
            ...recipe.files,
            {
              path: `${recipe.bootstrapDir}/implementation/package.json`,
              content: JSON.stringify({
                dependencies: { [settings.source.packageName]: settings.source.packageVersion },
              }),
            },
          ],
        },
        {
          agent: "omp",
          implementation: true,
        },
      );
      // install-command agents launch from their private home. Link that entry
      // to the same verified implementation without invoking a package manager.
      return {
        ...linked,
        files: linked.files.map((file) =>
          file.path.endsWith("/dieter-runtime-link.mjs")
            ? {
                ...file,
                content:
                  file.content +
                  `
import { mkdir, rm, symlink } from "node:fs/promises";
import { resolve } from "node:path";
await mkdir("home/.local/bin", { recursive: true });
await rm("home/.local/bin/omp", { force: true });
await symlink(resolve("implementation/node_modules/.bin/omp"), "home/.local/bin/omp");
`,
              }
            : file,
        ),
      };
    },
  };
}
