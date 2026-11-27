import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { VERSION as acpPackageVersion } from "@ai-sdk/harness-acp";
import { createACP } from "./acp-runtime.mjs";
import {
  acpImplementationIdentity,
  isACPImplementationMismatch,
  prepareOMPLaunch,
} from "./omp-launch.mjs";
import { ompACPArgs, ompConversationConfig, ompTurnFile } from "./provider-options.mjs";

async function launchFor(runtimeRoot, hookSource, request) {
  return prepareOMPLaunch({
    runtimeRoot,
    sessionId: "c_conversation",
    hookSource,
    config: ompConversationConfig(request),
    turn: ompTurnFile(request),
  });
}

const settingsFor = (launch) => ({
  harnessId: "omp",
  source: {
    type: "npm-simple",
    packageName: "@oh-my-pi/pi-coding-agent",
    packageVersion: "19.2.1",
  },
  executable: "omp",
  args: ompACPArgs(launch),
  modelMapping: { type: "session-config-option", path: "model" },
  forwardEnv: ["HOME", "PI_CODING_AGENT_DIR", "DIETER_OMP_TURN_FILE", "DIETER_TURN_TOKEN"],
});

test("stages the OMP hook, overlay and turn file privately at fixed paths", async (t) => {
  const runtimeRoot = await mkdtemp(join(tmpdir(), "dieter-omp-launch-"));
  t.after(() => rm(runtimeRoot, { recursive: true, force: true }));
  const hookSource = join(runtimeRoot, "hook.mjs");
  await writeFile(hookSource, "export default () => {};\n");
  const launch = await launchFor(runtimeRoot, hookSource, {
    model: "anthropic/claude-sonnet-5-5",
    effort: "high",
    options: { advisor_model: "openai-codex/gpt-6-sol", advisor_effort: "medium" },
  });
  const root = join(runtimeRoot, "harness-config");
  assert.deepEqual(launch, {
    hookPath: join(root, "omp-capabilities.mjs"),
    configPath: join(root, "omp-c_conversation.yml"),
    turnPath: join(root, "omp-c_conversation.json"),
  });
  for (const path of Object.values(launch)) assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.equal((await stat(root)).mode & 0o777, 0o700);
  assert.equal(await readFile(launch.hookPath, "utf8"), "export default () => {};\n");
  assert.deepEqual(JSON.parse(await readFile(launch.turnPath, "utf8")), { thinking: "high" });
  assert.match(
    await readFile(launch.configPath, "utf8"),
    /advisor: "openai-codex\/gpt-6-sol:medium"/,
  );
});

test("keeps the ACP implementation identity when model, effort, advisor or hook change", async (t) => {
  const runtimeRoot = await mkdtemp(join(tmpdir(), "dieter-omp-identity-"));
  t.after(() => rm(runtimeRoot, { recursive: true, force: true }));
  const hookSource = join(runtimeRoot, "hook.mjs");
  await writeFile(hookSource, "export default () => {};\n");
  const first = await launchFor(runtimeRoot, hookSource, {
    model: "anthropic/claude-opus-5-5",
    effort: "low",
  });
  await writeFile(hookSource, "export default (pi) => pi;\n");
  const second = await launchFor(runtimeRoot, hookSource, {
    model: "openai-codex/gpt-6-sol",
    effort: "max",
    options: { advisor_model: "anthropic/claude-opus-5-5" },
  });
  const identity = (launch) =>
    acpImplementationIdentity({ settings: settingsFor(launch), acpPackageVersion });
  assert.equal(identity(first), identity(second));
  assert.match(await readFile(second.hookPath, "utf8"), /pi => pi|\(pi\) => pi/);
  assert.deepEqual(JSON.parse(await readFile(second.turnPath, "utf8")), { thinking: "max" });
});

test("refuses session IDs that are not plain names", async () => {
  await assert.rejects(
    () =>
      prepareOMPLaunch({
        runtimeRoot: "/tmp",
        sessionId: "../escape",
        hookSource: "/x",
        config: "",
        turn: {},
      }),
    /plain session ID/,
  );
});

test("recognizes only ACP implementation mismatches", () => {
  assert.equal(
    isACPImplementationMismatch(
      new Error("ACP lifecycle state is incompatible with the configured agent."),
    ),
    true,
  );
  assert.equal(isACPImplementationMismatch(new Error("authentication failed")), false);
});

test("the pinned ACP runtime resumes a lifecycle across model and effort changes", async (t) => {
  const runtimeRoot = await mkdtemp(join(tmpdir(), "dieter-omp-contract-"));
  t.after(() => rm(runtimeRoot, { recursive: true, force: true }));
  const hookSource = join(runtimeRoot, "hook.mjs");
  await writeFile(hookSource, "export default () => {};\n");
  const before = await launchFor(runtimeRoot, hookSource, {
    model: "anthropic/claude-opus-5-5",
    effort: "low",
  });
  const lifecycleState = {
    type: "resume-session",
    harnessId: "omp",
    specificationVersion: "harness-v1",
    data: {
      agentIdentity: acpImplementationIdentity({
        settings: settingsFor(before),
        acpPackageVersion,
      }),
      authenticationProfile: { digest: "deliberately-wrong" },
    },
  };
  const sandboxSession = {
    id: "identity-contract-test",
    description: "identity contract test sandbox",
    defaultWorkingDirectory: "/tmp",
    ports: [43210],
    getPortEndpoint: async () => ({ url: "ws://127.0.0.1:43210" }),
    restricted() {
      return this;
    },
  };
  const after = await launchFor(runtimeRoot, hookSource, {
    model: "openai-codex/gpt-6-sol",
    effort: "max",
    options: { advisor_model: "anthropic/claude-opus-5-5" },
  });
  const start = (settings) =>
    createACP(settings).doStart({
      sessionId: "identity-contract-test",
      resumeFrom: lifecycleState,
      sandboxSession,
      sessionWorkDir: "/tmp",
    });
  // The agent identity matches, so only the deliberately wrong profile fails.
  await assert.rejects(() => start(settingsFor(after)), /configured authentication profile/);
  await assert.rejects(
    () => start({ ...settingsFor(after), args: [...settingsFor(after).args, "--model=x"] }),
    /configured agent/,
  );
});
