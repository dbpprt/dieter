import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createClaudeDiagnosticTracker,
  createClaudeTurnSummary,
  emptyClaudeResumePrompt,
  isCompletelyEmptyClaudeTurn,
  observeClaudeTurnChunk,
  retryEmptyClaudeResume,
} from './claude-resilience.mjs';

function emptySummary() {
  const summary = createClaudeTurnSummary();
  observeClaudeTurnChunk(summary, {
    type: 'finish',
    messageMetadata: { usage: { totalTokens: 0 } },
  });
  return summary;
}

test('identifies only a zero-token turn without content or tools as empty', () => {
  const empty = emptySummary();
  assert.equal(isCompletelyEmptyClaudeTurn(empty), true);

  const text = emptySummary();
  observeClaudeTurnChunk(text, { type: 'text-delta', delta: 'Recovered.' });
  assert.equal(isCompletelyEmptyClaudeTurn(text), false);

  const tool = emptySummary();
  observeClaudeTurnChunk(tool, { type: 'tool-input-available', toolName: 'read', input: {} });
  assert.equal(isCompletelyEmptyClaudeTurn(tool), false);
});

test('retries one completely empty resumed Claude turn', async () => {
  const prompts = [];
  const recovered = createClaudeTurnSummary();
  observeClaudeTurnChunk(recovered, { type: 'text-delta', delta: 'Continuing.' });
  observeClaudeTurnChunk(recovered, { type: 'finish', messageMetadata: { usage: { totalTokens: 12 } } });

  const result = await retryEmptyClaudeResume({
    adapter: 'claude-code',
    hasResumeSession: true,
    continuing: false,
    firstSummary: emptySummary(),
    retry: async prompt => {
      prompts.push(prompt);
      return recovered;
    },
  });

  assert.equal(result, recovered);
  assert.deepEqual(prompts, [emptyClaudeResumePrompt]);
});

test('does not retry fresh, nonempty, or suspended continuations', async () => {
  let retries = 0;
  const retry = async () => {
    retries += 1;
    return emptySummary();
  };
  await retryEmptyClaudeResume({ adapter: 'claude-code', hasResumeSession: false, continuing: false, firstSummary: emptySummary(), retry });
  await retryEmptyClaudeResume({ adapter: 'claude-code', hasResumeSession: true, continuing: true, firstSummary: emptySummary(), retry });
  const nonempty = emptySummary();
  observeClaudeTurnChunk(nonempty, { type: 'reasoning-delta', delta: 'Working' });
  await retryEmptyClaudeResume({ adapter: 'claude-code', hasResumeSession: true, continuing: false, firstSummary: nonempty, retry });
  assert.equal(retries, 0);
});

test('fails precisely after two empty Claude resume turns', async () => {
  await assert.rejects(
    retryEmptyClaudeResume({
      adapter: 'claude-code',
      hasResumeSession: true,
      continuing: false,
      firstSummary: emptySummary(),
      retry: async () => emptySummary(),
    }),
    /resumed the session twice without producing output/,
  );
});

test('promotes an exhausted Claude API retry to a provider failure', () => {
  const tracker = createClaudeDiagnosticTracker();
  const turn = tracker.beginTurn();
  tracker.observeStderr('[harness:claude-code:stderr] [harness:claude-code:warn] Claude Code API retry: attempt 9/10; HTTP 529; retrying\n');
  assert.equal(turn.providerFailure, undefined);
  tracker.observeStderr('[harness:claude-code:stderr] [harness:claude-code:warn] Claude Code API retry: attempt 10/10; HTTP 529; retrying\n');
  assert.equal(tracker.endTurn(turn), 'Claude Code API request failed after 10 retries: HTTP 529');
});

test('clears an exhausted retry when Claude subsequently produces activity', () => {
  const tracker = createClaudeDiagnosticTracker();
  const turn = tracker.beginTurn();
  tracker.observeStderr('[harness:claude-code:warn] Claude Code API retry: attempt 10/10; HTTP 529\n');
  tracker.observeActivity(turn);
  assert.equal(tracker.endTurn(turn), undefined);
});
