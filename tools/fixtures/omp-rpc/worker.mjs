// Real worker/bridge lifecycle with only OMP inference replaced by a strict peer.
import readline from "node:readline";
import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { runNativeOMP } from "../../../internal/harness/runtime/omp-rpc.mjs";
import { createSubagentCapabilityCollector } from "../../../internal/harness/runtime/capabilities.mjs";
const input = readline.createInterface({ input: process.stdin });
const request = JSON.parse(await new Promise((resolve) => input.once("line", resolve)));
const send = (value) => process.stdout.write(JSON.stringify(value) + "\n");
const collector = createSubagentCapabilityCollector({
  provider: "omp",
  adapter: "omp-rpc",
  messageId: request.responseMessageId,
  emit: (capability) => send({ type: "capability", capability }),
});
const start = async ({ stateDir }) => {
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  const config = {
    executable: process.execPath,
    args: [fileURLToPath(new URL("agent.mjs", import.meta.url))],
    cwd: request.projectPath,
    token: randomUUID(),
    socketPath: join(tmpdir(), `dieter-omp-test-${randomUUID()}.sock`),
  };
  await writeFile(join(stateDir, "start.json"), JSON.stringify(config), { mode: 0o600 });
  const child = spawn(
    process.execPath,
    [
      fileURLToPath(
        new URL("../../../internal/harness/runtime/omp-rpc-bridge.mjs", import.meta.url),
      ),
      "--bridge-state-dir",
      stateDir,
    ],
    {
      detached: true,
      stdio: "ignore",
      env: { ...process.env, OMP_RPC_FIXTURE_SESSION: join(stateDir, "session.jsonl") },
    },
  );
  child.unref();
  for (let i = 0; i < 200; i++) {
    try {
      const meta = JSON.parse(await readFile(join(stateDir, "bridge-meta.json"), "utf8"));
      if (meta.pid === child.pid) return meta;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("Fixture bridge startup timed out");
};
const processBridge = request.backgroundProcessesEnabled
  ? {
      call: async () => {
        send({ type: "fixture-host-admission" });
        await new Promise((resolve) => setTimeout(resolve, 200));
        return { processes: [] };
      },
      dispose() {},
    }
  : undefined;
await runNativeOMP({
  processBridge,
  request,
  runtimePrompt: request.prompt,
  send,
  collector,
  start,
  exitWorker: (code) => new Promise(() => process.stdout.write("", () => process.exit(code))),
});
