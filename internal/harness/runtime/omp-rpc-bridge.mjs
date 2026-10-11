// An owned, private Unix-socket bridge keeps native OMP alive across worker
// detach. Output is fsynced before delivery; reconnect replays, never re-prompts.
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { chmod, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { jsonLines, RPCDecoder, rpcPayloadLimit, writeJSON } from "./omp-rpc-protocol.mjs";

const stateDir = process.argv[process.argv.indexOf("--bridge-state-dir") + 1];
const config = JSON.parse(await readFile(join(stateDir, "start.json"), "utf8"));
const socketPath = config.socketPath;
const journal = await open(join(stateDir, "events.ndjson"), "w+", 0o600);
const offsets = [];
let journalBytes = 0,
  owner,
  shuttingDown = false,
  terminalError;
const dialogs = new Set();
const child = spawn(config.executable, config.args, {
  cwd: config.cwd,
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});
let stderr = "";
child.stderr.on("data", (data) => {
  stderr = (stderr + data).slice(-64 * 1024);
});
const exited = new Promise((resolve) => child.once("close", resolve));
child.on("error", (error) => {
  terminalError = error.message;
});
child.stdin.on("error", (error) => {
  terminalError = error.message;
});

async function pump(client) {
  if (client.pumping || owner !== client) return;
  client.pumping = true;
  try {
    while (owner === client && !client.socket.destroyed && client.after < offsets.length) {
      const position = offsets[client.after];
      const end = offsets[client.after + 1] ?? journalBytes;
      const buffer = Buffer.alloc(end - position);
      const { bytesRead } = await journal.read(buffer, 0, buffer.length, position);
      if (bytesRead !== buffer.length) throw new Error("Incomplete OMP RPC replay journal");
      await new Promise((resolve, reject) =>
        client.socket.write(buffer, (error) => (error ? reject(error) : resolve())),
      );
      client.after++;
    }
    if (terminalError && owner === client && !client.socket.destroyed) {
      await writeJSON(client.socket, { error: terminalError });
      client.socket.end();
    }
  } catch {
    client.socket.destroy();
  } finally {
    client.pumping = false;
  }
}

async function record(frame) {
  if (frame.type === "extension_ui_request") {
    if (["select", "confirm", "input", "editor"].includes(frame.method)) dialogs.add(frame.id);
    if (frame.method === "cancel") dialogs.delete(frame.targetId);
  }
  if (frame.type === "prompt_result") dialogs.clear();
  const line = Buffer.from(JSON.stringify({ seq: offsets.length + 1, frame }) + "\n");
  // Finite retention while a worker is detached. Overflow fails the turn rather
  // than dropping events or issuing the prompt again during recovery.
  if (offsets.length >= 100_000 || journalBytes + line.length > 128 * 1024 * 1024) {
    throw new Error("OMP RPC replay journal exceeded its retention limit");
  }
  const position = journalBytes;
  await journal.writeFile(line);
  await journal.datasync();
  journalBytes += line.length;
  offsets.push(position);
  if (owner) void pump(owner);
}

const server = createServer((socket) => {
  let client;
  socket.on("error", () => {});
  void (async () => {
    for await (const message of jsonLines(socket, rpcPayloadLimit + 1024)) {
      if (!client) {
        if (
          message.type !== "attach" ||
          message.token !== config.token ||
          !Number.isSafeInteger(message.after) ||
          message.after < 0 ||
          message.after > offsets.length
        )
          throw new Error("Invalid OMP bridge attachment");
        owner?.socket.destroy();
        client = { socket, after: message.after, pumping: false };
        owner = client;
        await writeJSON(socket, { attached: true, dialogs: [...dialogs] });
        void pump(client);
      } else {
        if (owner !== client) throw new Error("OMP bridge attachment replaced");
        if (message.type === "stop") {
          await shutdown();
          return;
        }
        if (message.type !== "send" || !message.frame || typeof message.frame.type !== "string")
          throw new Error("Invalid OMP bridge command");
        if (message.frame.type === "extension_ui_response") dialogs.delete(message.frame.id);
        await writeJSON(child.stdin, message.frame, rpcPayloadLimit);
      }
    }
  })()
    .catch(() => socket.destroy())
    .finally(() => {
      if (owner === client) owner = undefined;
    });
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(socketPath, resolve);
});
await chmod(socketPath, 0o600);
const meta = { pid: process.pid, socketPath, token: config.token };
await writeFile(join(stateDir, "bridge-meta.json.tmp"), JSON.stringify(meta), { mode: 0o600 });
await rename(join(stateDir, "bridge-meta.json.tmp"), join(stateDir, "bridge-meta.json"));

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  // This bridge is the leader of its own group. Signal only our tree, including
  // MCP stdio children and native tool subprocesses. Keep our handler installed
  // while the group receives TERM so we can remove the private socket/metadata.
  process.kill(-process.pid, "SIGTERM");
  const timer = setTimeout(() => process.kill(-process.pid, "SIGKILL"), 2000);
  await exited;
  clearTimeout(timer);
  server.close();
  await journal.close();
  await rm(socketPath, { force: true });
  await rm(join(stateDir, "bridge-meta.json"), { force: true });
  if (owner && !owner.socket.destroyed)
    await writeJSON(owner.socket, { stopped: true }).catch(() => {});
  owner?.socket.destroy();
  process.exit(0);
}
process.on("SIGTERM", () => void shutdown());
process.on("SIGINT", () => void shutdown());

void (async () => {
  try {
    const decoder = new RPCDecoder();
    for await (const frame of jsonLines(child.stdout)) {
      const decoded = decoder.push(frame);
      if (decoded) await record(decoded);
    }
    decoder.end();
    if (!shuttingDown)
      throw new Error(
        terminalError || `OMP RPC process exited: ${stderr.trim() || "no diagnostics"}`,
      );
  } catch (error) {
    if (shuttingDown) return;
    terminalError = error.message;
    child.kill("SIGTERM");
    if (owner) void pump(owner);
    // Keep the terminal error available to a detached worker for bounded time.
    setTimeout(() => void shutdown(), 60_000).unref();
  }
})();
