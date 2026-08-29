import readline from 'node:readline';
import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { HarnessAgent, getHarnessErrorMessage } from '@ai-sdk/harness/agent';
import { createCodex } from '@ai-sdk/harness-codex';
import { createClaudeCode } from '@ai-sdk/harness-claude-code';
import { createPi } from '@ai-sdk/harness-pi';
import { createACP } from '@ai-sdk/harness-acp';
import { tool, toUIMessageStream } from 'ai';
import { z } from 'zod';
import { createLocalSandboxProvider } from './local-sandbox.mjs';
import { createNDJSONTailer, createSubagentCapabilityCollector, observeHarnessCapabilities } from './capabilities.mjs';
import { ompACPArgs } from './provider-options.mjs';
import { promptWithLocalAttachments } from './local-attachments.mjs';
import {
  createClaudeDiagnosticTracker,
  createClaudeTurnSummary,
  observeClaudeTurnChunk,
  retryEmptyClaudeResume,
} from './claude-resilience.mjs';

// Stdout is the worker protocol. Some harness bootstraps log package-manager
// progress with console.log; keep those diagnostics on stderr so a first-run
// install cannot corrupt the NDJSON stream consumed by Go.
const protocolWrite = process.stdout.write.bind(process.stdout);
const rawStderrWrite = process.stderr.write.bind(process.stderr);
const claudeDiagnostics = createClaudeDiagnosticTracker();
process.stderr.write = (chunk, encoding, callback) => {
  claudeDiagnostics.observeStderr(chunk, encoding);
  return rawStderrWrite(chunk, encoding, callback);
};
const consoleToStderr = (...values) => process.stderr.write(`${values.map(value => typeof value === 'string' ? value : JSON.stringify(value)).join(' ')}\n`);
console.log = consoleToStderr;
console.info = consoleToStderr;
console.debug = consoleToStderr;
const send = value => protocolWrite(`${JSON.stringify(value)}\n`);
const extraHarnessEnv = (process.env.DIETER_HARNESS_ENV || '')
  .split(',')
  .map(name => name.trim())
  .filter(name => /^[A-Za-z_][A-Za-z0-9_]*$/.test(name));

function harnessErrorMessage(error) {
  if (error instanceof Error && error.message?.trim()) return error.message.trim();
  if (typeof error === 'string' && error.trim()) return error.trim();
  return getHarnessErrorMessage(error);
}
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const line = await new Promise(resolve => input.once('line', resolve));
input.close();
const request = JSON.parse(line);
const adapter = request.adapter || request.harness;
if (typeof request.sessionId !== 'string' || !/^[A-Za-z0-9._-]+$/.test(request.sessionId)) {
  throw new Error('invalid harness session ID');
}
const sandboxWorkDir = `workspaces/${request.sessionId}/repo`;
const sandbox = await createLocalSandboxProvider({
  root: request.runtimeRoot,
  projectPath: request.projectPath,
  workDir: sandboxWorkDir,
});
const sandboxSession = await sandbox.createSession();
const workspaceDirectory = join(request.runtimeRoot, sandboxWorkDir);
const expectedWorkspace = await realpath(request.projectPath);
const workspaceProbe = await sandboxSession.run({ command: 'pwd -P', workingDirectory: workspaceDirectory });
const actualWorkspace = workspaceProbe.stdout.trim();
if (workspaceProbe.exitCode !== 0 || actualWorkspace !== expectedWorkspace) {
  throw new Error(`harness workspace mismatch: expected ${expectedWorkspace}, resolved ${actualWorkspace || '<empty>'}`);
}

const runtimePrompt = await promptWithLocalAttachments(request);
const capabilityCollector = createSubagentCapabilityCollector({
  provider: request.harness,
  adapter,
  messageId: request.responseMessageId,
  emit: capability => send({ type: 'capability', capability }),
});
let capabilityTailer;

async function codexContextWindow(model) {
  if (!model) return undefined;
  try {
    const root = process.env.CODEX_HOME || join(homedir(), '.codex');
    const cache = JSON.parse(await readFile(join(root, 'models_cache.json'), 'utf8'));
    const entry = cache.models?.find(item => item.slug === model);
    const tokens = Number(entry?.context_window);
    const effectivePercent = Number(entry?.effective_context_window_percent ?? 100);
    return Number.isFinite(tokens) && tokens > 0 ? Math.floor(tokens * effectivePercent / 100) : undefined;
  } catch {
    return undefined;
  }
}

if (request.harness === 'mock') {
  const responseId = request.responseMessageId || `msg_${Date.now().toString(36)}`;
  const createdAt = new Date().toISOString();
  console.log('mock bootstrap diagnostic');
  protocolWrite('\nmock package installer diagnostic\n');
  if (runtimePrompt === 'mock-concurrent-workspace-write') {
    await new Promise(resolveDelay => setTimeout(resolveDelay, 200));
    await sandboxSession.writeTextFile({
      path: join(workspaceDirectory, `.dieter-mock-${request.sessionId}`),
      content: `${actualWorkspace}\n`,
    });
  }
  capabilityCollector.consumeBoardTaskPlan({ tasks: [
    { content: 'Inspect the request', status: 'completed' },
    { content: 'Produce a verified response', status: 'in_progress', activeForm: 'Producing a verified response' },
  ] });
  for (const chunk of [
    { type: 'start', messageId: responseId, messageMetadata: { createdAt } },
    { type: 'start-step' },
    { type: 'reasoning-start', id: 'reasoning-1' },
    { type: 'reasoning-delta', id: 'reasoning-1', delta: 'Inspecting the local workspace' },
    { type: 'reasoning-end', id: 'reasoning-1' },
    { type: 'tool-input-available', toolCallId: 'tool-1', toolName: 'bash', input: { command: 'pwd' } },
    { type: 'tool-output-available', toolCallId: 'tool-1', output: { exitCode: 0, output: actualWorkspace } },
    { type: 'tool-input-available', toolCallId: 'tool-2', toolName: 'bash', input: { command: 'git status --short' } },
    { type: 'tool-output-available', toolCallId: 'tool-2', output: { exitCode: 0, output: '' } },
    { type: 'text-start', id: 'text-1' },
    { type: 'text-delta', id: 'text-1', delta: `Mock harness received: ${runtimePrompt}` },
    { type: 'text-end', id: 'text-1' },
    { type: 'finish-step' },
    { type: 'finish', finishReason: 'stop', messageMetadata: { createdAt, usage: { inputTokens: 120, outputTokens: 30, totalTokens: 150 }, contextWindowTokens: 1000 } },
  ]) send({ type: 'chunk', chunk });
  capabilityCollector.consumeBoardTaskPlan({ tasks: [
    { content: 'Inspect the request', status: 'completed' },
    { content: 'Produce a verified response', status: 'completed' },
  ] });
  capabilityCollector.finishTaskPlan('completed');
  send({ type: 'session', state: { type: 'resume-session', data: { mock: true } } });
  process.exit(0);
}

let harness;
switch (adapter) {
  case 'codex':
    harness = createCodex({ model: request.model || undefined, reasoningEffort: request.effort || undefined, webSearch: request.webSearch === true });
    break;
  case 'claude-code':
    harness = createClaudeCode({ model: request.model || undefined, effort: request.effort || undefined });
    break;
  case 'pi':
    harness = createPi({
      model: request.model || undefined,
      thinkingLevel: request.effort || undefined,
      agentDir: process.env.PI_AGENT_DIR || join(homedir(), '.pi', 'agent'),
    });
    break;
  case 'omp-acp':
  {
    const capabilityRoot = join(request.runtimeRoot, 'capabilities');
    const capabilityFile = join(capabilityRoot, `${request.sessionId}.ndjson`);
    await mkdir(capabilityRoot, { recursive: true, mode: 0o700 });
    await writeFile(capabilityFile, '', { mode: 0o600 });
    capabilityTailer = createNDJSONTailer(capabilityFile, event => capabilityCollector.consumeOMPEnvelope(event));
    process.env.DIETER_OMP_CAPABILITY_FILE = capabilityFile;
    harness = createACP({
      harnessId: 'omp',
      source: {
        type: 'npm-simple',
        packageName: '@oh-my-pi/pi-coding-agent',
        packageVersion: '17.3.4',
      },
      executable: 'omp',
      args: ompACPArgs(request, fileURLToPath(new URL('./omp-capabilities-hook.mjs', import.meta.url))),
      modelId: request.model || undefined,
      forwardEnv: ['HOME', 'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'DIETER_OMP_CAPABILITY_FILE', ...extraHarnessEnv],
    });
    break;
  }
  default:
    throw new Error(`unsupported harness adapter: ${adapter}`);
}
harness = observeHarnessCapabilities(harness, capabilityCollector);

const controller = new AbortController();
let session;
let suspending = false;
let suspendPromise;
let interruptExitCode;
let settleWorker;
const workerSettled = new Promise(resolve => { settleWorker = resolve; });
let forcedExitTimer;
const closeSession = async () => {
  if (!session) return;
  const current = session;
  session = undefined;
  const state = await current.stop();
  send({ type: 'session', state });
};
const interrupt = exitCode => {
  if (interruptExitCode != null || suspending) return;
  interruptExitCode = exitCode;
  controller.abort(new Error('agent turn interrupted'));
  // Let the stream unwind before stop(). Calling stop() while the Harness
  // session still owns an active turn deliberately creates a continuation and
  // leaves bridge-backed providers alive. The timer is only a final guard for
  // an adapter that never settles after abort.
  forcedExitTimer = setTimeout(() => {
    void sandbox.stopAll().finally(() => process.exit(exitCode));
  }, 8_000);
  forcedExitTimer.unref?.();
  void workerSettled.finally(() => process.exit(exitCode));
};
const suspend = async () => {
  if (session) {
    try {
      const state = await session.detach();
      send({ type: 'session', state });
    } catch (error) {
      console.error(`failed to suspend harness session: ${harnessErrorMessage(error)}`);
      process.exitCode = 1;
    }
  }
  await capabilityTailer?.drain();
};
process.once('SIGTERM', () => interrupt(143));
process.once('SIGINT', () => interrupt(130));
process.once('SIGUSR1', () => {
  suspending = true;
  suspendPromise = suspend();
  void suspendPromise.finally(() => process.exit(process.exitCode || 0));
});

try {
  const piTaskPlanTool = tool({
    description: 'Replace Dieter\'s visible progress checklist for the current response. Call this before multi-step work and after each task status changes.',
    inputSchema: z.object({
      explanation: z.string().optional(),
      tasks: z.array(z.object({
        content: z.string().min(1),
        activeForm: z.string().optional(),
        status: z.enum(['pending', 'in_progress', 'completed', 'blocked', 'abandoned']),
        blocker: z.string().optional(),
      })).min(1),
    }),
    execute: async input => capabilityCollector.consumeBoardTaskPlan(input),
  });
  const taskPlanInstructions = adapter === 'pi'
    ? 'For any task with two or more meaningful steps, use board_task_plan before starting and after every status change. Keep exactly one task in_progress at a time and mark all finished tasks completed before answering.'
    : '';
  const instructions = [request.instructions, taskPlanInstructions].filter(Boolean).join('\n\n');
  const agent = new HarnessAgent({
    harness,
    sandbox,
    instructions: instructions || undefined,
    ...(adapter === 'pi' ? { tools: { board_task_plan: piTaskPlanTool } } : {}),
    permissionMode: 'allow-all',
    sandboxConfig: { workDir: sandboxWorkDir },
  });
  const sessionOptions = { sessionId: request.sessionId, abortSignal: controller.signal };
  const incompleteOMPSession = adapter === 'omp-acp' && request.session && !request.session.data?.acpSessionId;
  if (request.continue && request.session?.continueFrom) {
    sessionOptions.continueFrom = request.session.continueFrom;
  } else if (request.session && !incompleteOMPSession) {
    // stop() during an interrupted turn returns a resumable session with a
    // nested continueFrom state. Dieter's queued message replaces that turn;
    // retain the ACP session but deliberately discard the unfinished turn.
    const { continueFrom: _discardedTurn, ...resumeFrom } = request.session;
    sessionOptions.resumeFrom = resumeFrom;
  }
  session = await agent.createSession(sessionOptions);
  const createdAt = new Date().toISOString();
  const contextWindowTokens = request.contextWindow || (adapter === 'codex' ? await codexContextWindow(request.model) : undefined);
  let claudeDelegationSeen = false;
  let claudeFinalTextSeen = false;
  async function streamResult(result, summary, diagnosticTurn) {
    const stream = toUIMessageStream({
      stream: result.stream,
      onError: harnessErrorMessage,
      generateMessageId: () => request.responseMessageId,
      messageMetadata: ({ part }) => {
        if (part.type === 'start') return { createdAt };
        if (part.type === 'finish') return { createdAt, usage: part.totalUsage, contextWindowTokens };
        return undefined;
      },
    });
    for await (const chunk of stream) {
      // The Go host owns the semantic distinction between a user interrupt
      // and a process-restart suspension. Suppress the SDK's local abort frame
      // here; Dieter appends one for a real cancel, while a restart preserves
      // the in-flight message, task plan, and subagents for continuation.
      if (controller.signal.aborted && chunk.type === 'abort') continue;
      if (adapter === 'claude-code') {
        if (observeClaudeTurnChunk(summary, chunk)) claudeDiagnostics.observeActivity(diagnosticTurn);
        if (chunk.type === 'tool-input-available' && ['agent', 'task'].includes(String(chunk.toolName || '').toLowerCase())) claudeDelegationSeen = true;
        if (claudeDelegationSeen && chunk.type === 'text-delta' && String(chunk.delta || '').trim()) claudeFinalTextSeen = true;
      }
      capabilityCollector.consumeUIChunk(chunk);
      send({ type: 'chunk', chunk });
    }
  }
  async function runStream(start) {
    const summary = createClaudeTurnSummary();
    const diagnosticTurn = adapter === 'claude-code' ? claudeDiagnostics.beginTurn() : undefined;
    let streamError;
    try {
      await streamResult(await start(), summary, diagnosticTurn);
    } catch (error) {
      streamError = error;
    }
    const providerFailure = diagnosticTurn ? claudeDiagnostics.endTurn(diagnosticTurn) : undefined;
    if (providerFailure) throw new Error(providerFailure, streamError ? { cause: streamError } : undefined);
    if (streamError) throw streamError;
    return summary;
  }
  async function streamPrompt(prompt) {
    return runStream(() => agent.stream({ session, prompt, abortSignal: controller.signal }));
  }
  let primarySummary;
  if (request.continue) {
    if (!sessionOptions.continueFrom) throw new Error('Dieter restart recovery is missing the suspended turn continuation');
    primarySummary = await runStream(() => agent.continueStream({ session, abortSignal: controller.signal }));
  } else {
    primarySummary = await streamPrompt(runtimePrompt);
  }
  await retryEmptyClaudeResume({
    adapter,
    hasResumeSession: Boolean(request.session),
    continuing: request.continue === true,
    firstSummary: primarySummary,
    retry: streamPrompt,
  });
  // Claude Agent SDK 0.3.213 can end a provider-executed Agent step after
  // returning the child result without streaming the parent's final prose.
  // Continue the same durable session once and keep one logical UI response.
  if (adapter === 'claude-code' && claudeDelegationSeen && !claudeFinalTextSeen && !controller.signal.aborted) {
    await streamPrompt('Continue the current task. Use the completed subagent results and provide the final answer requested by the user. Do not launch replacement subagents unless one failed.');
  }
  if (suspending) {
    await suspendPromise;
  } else {
    await closeSession();
    await capabilityTailer?.drain();
    if (controller.signal.aborted) {
      capabilityCollector.finalize('aborted');
      capabilityCollector.finishTaskPlan('aborted');
    } else {
      capabilityCollector.finishTaskPlan('completed');
    }
  }
} catch (error) {
  if (suspending) {
    await suspendPromise;
    process.exit(0);
  }
  if (!controller.signal.aborted) {
    console.error(String(error?.message || error));
    send({ type: 'error', error: harnessErrorMessage(error) });
  }
  try {
    await closeSession();
  } catch (stopError) {
    if (!controller.signal.aborted) console.error(`failed to stop harness session: ${harnessErrorMessage(stopError)}`);
  }
  await capabilityTailer?.drain();
  capabilityCollector.finalize(controller.signal.aborted ? 'aborted' : 'failed');
  capabilityCollector.finishTaskPlan(controller.signal.aborted ? 'aborted' : 'failed');
  process.exitCode = controller.signal.aborted ? interruptExitCode ?? 130 : 1;
} finally {
  if (forcedExitTimer != null) clearTimeout(forcedExitTimer);
  settleWorker();
}
