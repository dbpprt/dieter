export { VERSION } from "@ai-sdk/harness-acp";
import { createACP as createAdapterACP } from "@ai-sdk/harness-acp";

// ACP now requires an installation command and explicit tool classification.
// OMP replaces this installation with links to the shipped runtime; DSH keeps
// its on-demand installation under the adapter-owned home directory.
export function acpSettings(settings) {
  const source = settings.source;
  if (source.type !== "npm-simple") return settings;
  if (
    !/^(@[a-z0-9-]+\/)?[a-z0-9-]+$/.test(source.packageName) ||
    !/^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(source.packageVersion)
  ) {
    throw new Error("ACP package source must name an exact package version");
  }
  return {
    isMcpToolCall: () => true,
    resolveHostToolCall: () => undefined,
    ...settings,
    source: {
      type: "install-command",
      command: `npm install --global --prefix "$HOME/.local" --ignore-scripts ${source.packageName}@${source.packageVersion}`,
    },
  };
}

export function createACP(settings) {
  return createAdapterACP(acpSettings(settings));
}
