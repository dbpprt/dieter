import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Readable } from "node:stream";
import { RPCDecoder, jsonLines, rpcPayloadLimit } from "./omp-rpc-protocol.mjs";
import { createOMPStream, dialogAnswer } from "./omp-rpc-stream.mjs";

const worker = fileURLToPath(
  new URL("../../../tools/fixtures/omp-rpc/worker.mjs", import.meta.url),
);
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "dieter-omp-rpc-"));
  const repo = join(root, "repo");
  await mkdir(repo);
  await writeFile(join(repo, "report.txt"), "report");
  t.after(async () => {
    try {
      const meta = JSON.parse(
        await readFile(
          join(root, "runtime/.agent-runs/rpc-test/omp-rpc/bridge/bridge-meta.json"),
          "utf8",
        ),
      );
      try {
        process.kill(-meta.pid, "SIGTERM");
      } catch (e) {
        if (e.code !== "ESRCH") throw e;
      }
      for (let n = 0; n < 200; n++) {
        try {
          await readFile(
            join(root, "runtime/.agent-runs/rpc-test/omp-rpc/bridge/bridge-meta.json"),
          );
        } catch (e) {
          if (e.code === "ENOENT") break;
          throw e;
        }
        await new Promise((resolve) => setTimeout(resolve, 10));
        if (n === 199) throw new Error("Fixture bridge did not clean up");
      }
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
    await rm(root, { recursive: true, force: true });
  });
  const request = {
    harness: "omp",
    adapter: "omp-rpc",
    sessionId: "rpc-test",
    responseMessageId: "first",
    runtimeRoot: join(root, "runtime"),
    projectPath: repo,
    contentPresentationEnabled: true,
  };
  const log = join(root, "commands.ndjson");
  await writeFile(log, "");
  return {
    request,
    async commands() {
      return (await readFile(log, "utf8")).trim().split("\n").filter(Boolean).map(JSON.parse);
    },
    run(overrides = {}, onOutput) {
      return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [worker], {
          stdio: ["pipe", "pipe", "pipe"],
          env: { ...process.env, OMP_RPC_FIXTURE_LOG: log },
        });
        const outputs = [];
        let stderr = "",
          parsing;
        const timer = setTimeout(() => {
          child.kill("SIGINT");
          reject(new Error("Native RPC fixture timed out"));
        }, 15_000);
        child.stderr.on("data", (d) => {
          stderr += d;
        });
        void (async () => {
          try {
            for await (const output of jsonLines(child.stdout, 8 * 1024 * 1024)) {
              outputs.push(output);
              onOutput?.(output, child);
            }
          } catch (e) {
            parsing = e;
          }
        })();
        child.once("error", reject);
        child.once("close", (code) => {
          clearTimeout(timer);
          if (parsing) reject(parsing);
          else
            resolve({
              code,
              stderr,
              outputs,
              state: outputs.findLast((x) => x.type === "session")?.state,
            });
        });
        child.stdin.end(JSON.stringify({ ...request, ...overrides }) + "\n");
      });
    },
  };
}
const text = (result) =>
  result.outputs
    .filter((x) => x.chunk?.type === "text-delta")
    .map((x) => x.chunk.delta)
    .join("");

test("v2 reassembles large Unicode frames and fails closed on corrupt or unbounded chunks", async () => {
  const payload = Buffer.from(
    JSON.stringify({ type: "message_end", message: "é".repeat(700_000) }),
  );
  const decoder = new RPCDecoder();
  let decoded;
  const count = Math.ceil(payload.length / (256 * 1024));
  for (let index = 0; index < count; index++)
    decoded = decoder.push({
      type: "rpc_chunk",
      chunkId: "test",
      index,
      count,
      byteLength: payload.length,
      data: payload.subarray(index * 256 * 1024, (index + 1) * 256 * 1024).toString("base64"),
    });
  assert.equal(decoded.message.length, 700_000);
  assert.throws(
    () =>
      new RPCDecoder().push({
        type: "rpc_chunk",
        chunkId: "x",
        index: 0,
        count: 2,
        byteLength: rpcPayloadLimit + 1,
        data: "YQ==",
      }),
    /metadata/,
  );
  assert.throws(
    () =>
      new RPCDecoder().push({
        type: "rpc_chunk",
        chunkId: "x",
        index: 1,
        count: 5,
        byteLength: payload.length,
        data: "YQ==",
      }),
    /zero/,
  );
  const broken = new RPCDecoder();
  broken.push({
    type: "rpc_chunk",
    chunkId: "x",
    index: 0,
    count: 5,
    byteLength: payload.length,
    data: "YQ==",
  });
  assert.throws(() => broken.push({ type: "ready" }), /interrupted/);
  await assert.rejects(async () => {
    for await (const _ of jsonLines(Readable.from(['{"unterminated":true}']))) {
    }
  }, /inside a frame/);
});

test("native host tools, validation, subagent progress and todo phases use existing outputs", async (t) => {
  const f = await fixture(t);
  const result = await f.run({ prompt: "host-tools" });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(text(result), "host tools completed");
  assert.equal(
    result.outputs.find((x) => x.type === "present-content").presentation.path,
    "report.txt",
  );
  assert.ok(result.outputs.some((x) => x.capability?.subagent?.status === "completed"));
  assert.ok(result.outputs.some((x) => x.capability?.id === "task-plan"));
  const metadata = result.outputs.findLast((x) => x.chunk?.type === "finish").chunk.messageMetadata;
  assert.equal(metadata.usage.totalTokens, 15);
  assert.equal(metadata.contextWindowTokens, 1000);
  const error = await f.run({
    prompt: "invalid-host-tool",
    session: result.state,
    responseMessageId: "second",
  });
  assert.equal(error.code, 0, error.stderr);
  assert.equal(text(error), "host error recovered");
  assert.ok(error.outputs.some((x) => x.chunk?.type === "tool-output-error"));
});

test("normal chat answers the same pending native question without another prompt", async (t) => {
  const f = await fixture(t);
  const asked = await f.run({ prompt: "question" });
  assert.equal(asked.code, 0, asked.stderr);
  assert.match(text(asked), /Choose color/);
  assert.equal(asked.state.data.ompRPC.pendingDialog.id, "dialog-1");
  const invalid = await f.run({
    prompt: "unknown",
    session: asked.state,
    responseMessageId: "invalid",
  });
  assert.equal(invalid.code, 0, invalid.stderr);
  assert.match(text(invalid), /option number/);
  const answered = await f.run({
    prompt: "2",
    session: invalid.state,
    responseMessageId: "answer",
  });
  assert.equal(answered.code, 0, answered.stderr);
  assert.equal(text(answered), "Selected Blue");
  assert.equal(answered.state.data.ompRPC.pendingDialog, undefined);
  assert.equal((await f.commands()).filter((x) => x.type === "prompt").length, 1);
  assert.ok(
    answered.outputs.some(
      (x) => x.chunk?.toolCallId === "ask-1" && x.chunk.type === "tool-output-available",
    ),
  );
});

test("detach replays the exact native stream and never resubmits inference", async (t) => {
  const f = await fixture(t);
  let signaled = false;
  const first = await f.run({ prompt: "long" }, (output, child) => {
    if (output.chunk?.type === "text-delta" && !signaled) {
      signaled = true;
      child.kill("SIGUSR1");
    }
  });
  assert.equal(first.code, 0, first.stderr);
  assert.equal(text(first), "before ");
  assert.ok(first.state.continueFrom);
  const continued = await f.run({ continue: true, session: first.state });
  assert.equal(continued.code, 0, continued.stderr);
  assert.equal(text(continued), "after");
  assert.ok(!continued.outputs.some((x) => x.chunk?.type === "start"));
  assert.equal((await f.commands()).filter((x) => x.type === "prompt").length, 1);
});

test("native completion waits for settlement, and provider errors stay errors", async (t) => {
  const f = await fixture(t);
  const result = await f.run({ prompt: "async" });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(text(result), "firstsettled");
  const local = await f.run({ prompt: "/local" });
  assert.equal(local.code, 0, local.stderr);
  assert.equal(text(local), "Native local command output");
  const compact = await f.run({ prompt: "/compact retain the challenge" });
  assert.equal(compact.code, 0, compact.stderr);
  assert.equal(text(compact), "OMP session compacted.");
  assert.ok(
    (await f.commands()).some(
      (x) => x.type === "compact" && x.customInstructions === "retain the challenge",
    ),
  );
  const error = await f.run({ prompt: "error" });
  assert.equal(error.code, 1);
  assert.match(error.outputs.find((x) => x.type === "error").error, /exhausted retries/);
});

test("interrupt sends native abort and cleans the owned bridge", async (t) => {
  const f = await fixture(t);
  let signaled = false;
  const result = await f.run({ prompt: "long" }, (output, child) => {
    if (output.chunk?.type === "text-delta" && !signaled) {
      signaled = true;
      child.kill("SIGINT");
    }
  });
  assert.equal(result.code, 130, result.stderr);
  assert.ok((await f.commands()).some((x) => x.type === "abort"));
});

test("question responses preserve native value/confirm/cancel types", () => {
  assert.deepEqual(dialogAnswer({ id: "a", method: "confirm" }, "yes"), {
    type: "extension_ui_response",
    id: "a",
    confirmed: true,
  });
  assert.deepEqual(dialogAnswer({ id: "a", method: "input" }, "/cancel"), {
    type: "extension_ui_response",
    id: "a",
    cancelled: true,
  });
  assert.throws(() => dialogAnswer({ id: "a", method: "confirm" }, "maybe"), /yes or no/);
});

test("suspension completes admitted host work before saving its replay cursor", async (t) => {
  const f = await fixture(t);
  let signaled = false;
  const first = await f.run(
    { prompt: "slow-host", backgroundProcessesEnabled: true },
    (output, child) => {
      if (output.type === "fixture-host-admission" && !signaled) {
        signaled = true;
        child.kill("SIGUSR1");
      }
    },
  );
  assert.equal(first.code, 0, first.stderr);
  assert.ok(first.state.continueFrom);
  const continued = await f.run({
    continue: true,
    session: first.state,
    backgroundProcessesEnabled: true,
  });
  assert.equal(continued.code, 0, continued.stderr);
  assert.equal(text(continued), "Host admission completed");
  assert.equal((await f.commands()).filter((x) => x.type === "host_tool_result").length, 1);
  assert.ok(!continued.outputs.some((x) => x.type === "fixture-host-admission"));
});

test("large Unicode text stays intact and large tool results get explicit bounded previews", () => {
  const outputs = [];
  const stream = createOMPStream({
    request: {},
    send: (value) => outputs.push(value),
    collector: { consumeUIChunk() {} },
  });
  const text = "🌏".repeat(700_000);
  stream.text(text);
  const deltas = outputs.filter((x) => x.chunk?.type === "text-delta").map((x) => x.chunk.delta);
  assert.equal(deltas.join(""), text);
  assert.ok(deltas.every((x) => x.length <= 128 * 1024 && !/[\uD800-\uDBFF]$/.test(x)));
  stream.consume({
    type: "tool_execution_end",
    toolCallId: "large",
    toolName: "mcp",
    result: { text },
  });
  const result = outputs.find((x) => x.chunk?.type === "tool-output-available").chunk.output;
  assert.equal(result.truncated, true);
  assert.match(result.note, /OMP session/);
  assert.ok(Buffer.byteLength(JSON.stringify(result)) < 3 * 1024 * 1024);
});
