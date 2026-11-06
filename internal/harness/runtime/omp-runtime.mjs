import { createACP } from "@ai-sdk/harness-acp";
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
      return runtimeLinkedBootstrap(await harness.getBootstrap(options), {
        agent: "omp",
        implementation: true,
      });
    },
  };
}
