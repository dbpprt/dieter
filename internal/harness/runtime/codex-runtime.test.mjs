import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createCodex } from '@ai-sdk/harness-codex';
import { createLocalCodex } from './codex-runtime.mjs';

const runtimeRoot = dirname(fileURLToPath(import.meta.url));

test('Codex bootstrap links the locked runtime SDK offline without changing the adapter bridge', async () => {
  const original = await createCodex().getBootstrap();
  const recipe = await createLocalCodex({ model: 'gpt-6-astra', reasoningEffort: 'ultra' }).getBootstrap();
  const manifest = JSON.parse(recipe.files.find(file => file.path.endsWith('/package.json')).content);
  const sdkPath = manifest.dependencies['@openai/codex-sdk'].replace(/^file:/, '');
  const sdk = JSON.parse(await readFile(join(sdkPath, 'package.json'), 'utf8'));
  const runtime = JSON.parse(await readFile(join(runtimeRoot, 'package.json'), 'utf8'));
  assert.equal(sdk.version, runtime.dependencies['@openai/codex-sdk']);
  assert.equal(sdk.dependencies['@openai/codex'], '0.154.0');
  assert.match(manifest.dependencies.ws, /^file:/);
  assert.match(recipe.commands[0].command, /--offline/);
  assert.match(recipe.commands[0].command, /--ignore-scripts/);
  assert(!recipe.files.some(file => file.path.endsWith('pnpm-lock.yaml')));
  assert.equal(recipe.files.find(file => file.path.endsWith('/bridge.mjs')).content,
    original.files.find(file => file.path.endsWith('/bridge.mjs')).content);
  assert.equal(JSON.parse(original.files.find(file => file.path.endsWith('/package.json')).content)
    .dependencies['@openai/codex-sdk'], '0.149.1');
});

test('bundled Codex streams Astra Ultra and resumes the same session with the next selection', { timeout: 90000 }, async t => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'dieter-codex-runtime-')));
  const projectPath = join(root, 'project');
  const codexHome = join(root, 'codex');
  await Promise.all([mkdir(projectPath), mkdir(codexHome)]);
  t.after(() => rm(root, { recursive: true, force: true }));
  const requests = [];
  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    if (request.url !== '/v1/responses') {
      response.writeHead(404).end('{}');
      return;
    }
    requests.push(JSON.parse(body));
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const event of responseEvents(requests.length)) {
      response.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
    }
    response.end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  // Only disposable credentials and temporary provider state reach this child.
  // npm bootstrap is offline; inference can only reach the loopback fixture.
  const environment = {
    PATH: process.env.PATH, HOME: root, TMPDIR: root, CODEX_HOME: codexHome,
    OPENAI_BASE_URL: `http://127.0.0.1:${server.address().port}/v1`,
    CODEX_API_KEY: 'dieter-loopback-fixture',
  };
  const base = {
    harness: 'codex', adapter: 'codex', sessionId: 'astra-session', projectPath,
    runtimeRoot: join(root, 'runtime'), model: 'gpt-6-astra', effort: 'ultra',
    options: { fast_mode: 'true' }, prompt: 'First isolated fixture turn.', responseMessageId: 'first',
  };
  const first = await runWorker(base, environment);
  assert.equal(first.code, 0, first.stderr);
  assert(first.frames.some(frame => frame.type === 'chunk' && frame.chunk.type === 'text-delta'
    && frame.chunk.delta === 'Fixture response 1.'));
  assert(!first.frames.some(frame => frame.type === 'error'), JSON.stringify(first.frames));
  const state = first.frames.find(frame => frame.type === 'session').state;
  assert.equal(typeof state.data.threadId, 'string');
  const second = await runWorker({
    ...base, session: state, model: 'gpt-5.6-sol', effort: 'medium',
    options: { fast_mode: 'false' }, prompt: 'Second isolated fixture turn.', responseMessageId: 'second',
  }, environment);
  assert.equal(second.code, 0, second.stderr);
  assert.equal(second.frames.find(frame => frame.type === 'session').state.data.threadId, state.data.threadId);
  assert(second.frames.some(frame => frame.type === 'chunk' && frame.chunk.type === 'text-delta'
    && frame.chunk.delta === 'Fixture response 2.'));
  assert.equal(requests.length, 2);
  assert.equal(requests[0].model, 'gpt-6-astra');
  assert.equal(requests[0].service_tier, 'priority');
  assert.equal(requests[1].model, 'gpt-5.6-sol');
  assert.equal(requests[1].reasoning.effort, 'medium');
  assert.notEqual(requests[1].service_tier, 'priority');
  assert.match(JSON.stringify(requests[1].input), /First isolated fixture turn/);
  assert.match(JSON.stringify(requests[1].input), /Fixture response 1/);
  assert.doesNotMatch(first.stderr + second.stderr, /model metadata.*not found|requires a newer version/i);

  const records = [];
  for (const file of await readdir(join(codexHome, 'sessions'), { recursive: true })) {
    if (!file.endsWith('.jsonl')) continue;
    const text = await readFile(join(codexHome, 'sessions', file), 'utf8');
    records.push(...text.trim().split('\n').map(line => JSON.parse(line)));
  }
  assert(records.some(record => record.type === 'session_meta' && record.payload.cli_version === '0.154.0'));
  const turns = records.filter(record => record.type === 'turn_context').map(record => record.payload);
  // Ultra is recorded by Codex itself. Its wire effort is an implementation
  // detail of that orchestration mode, not an API enum Dieter should translate.
  assert(turns.some(turn => turn.model === 'gpt-6-astra' && turn.effort === 'ultra'));
  assert(turns.some(turn => turn.model === 'gpt-5.6-sol' && turn.effort === 'medium'));
});

async function runWorker(request, env) {
  const child = spawn(process.execPath, [join(runtimeRoot, 'runner.mjs')], {
    env, stdio: ['pipe', 'pipe', 'pipe'], timeout: 40000, killSignal: 'SIGTERM',
  });
  let stdout = '', stderr = '';
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  child.stdin.end(`${JSON.stringify(request)}\n`);
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', resolve);
  });
  const frames = stdout.split('\n').filter(Boolean).map(line => JSON.parse(line));
  return { code, stderr, frames };
}

function responseEvents(index) {
  const item = {
    id: `message_${index}`, type: 'message', role: 'assistant', phase: 'final_answer', status: 'completed',
    content: [{ type: 'output_text', text: `Fixture response ${index}.`, annotations: [] }],
  };
  return [
    { type: 'response.created', response: { id: `response_${index}`, status: 'in_progress', output: [] } },
    { type: 'response.output_item.added', output_index: 0, item: { ...item, status: 'in_progress', content: [] } },
    { type: 'response.output_text.delta', item_id: item.id, output_index: 0, content_index: 0, delta: item.content[0].text },
    { type: 'response.output_item.done', output_index: 0, item },
    { type: 'response.completed', response: {
      id: `response_${index}`, status: 'completed', output: [item],
      usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15,
        input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } },
    } },
  ];
}
