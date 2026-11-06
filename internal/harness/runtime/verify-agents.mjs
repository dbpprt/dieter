// Run by release builders on a freshly installed runtime archive, with the
// managed Bun on PATH: every agent CLI and this platform's native package must
// be present and report the version package-lock.json pins. Prints the
// verified versions as one JSON line.
import { agentPackages, verifyAgent } from "./runtime-packages.mjs";

try {
  const verified = {};
  for (const agent of Object.keys(agentPackages)) verified[agent] = await verifyAgent(agent);
  process.stdout.write(`${JSON.stringify(verified)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
