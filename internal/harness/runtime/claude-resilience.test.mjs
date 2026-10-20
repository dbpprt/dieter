import assert from 'node:assert/strict';
import test from 'node:test';
import {
  claudeAuthFailureMessage,
  claudeAuthFailureText,
  claudeAuthResumePrompt,
  createClaudeDiagnosticTracker,
  createClaudeTurnSummary,
  emptyClaudeResumePrompt,
  isCompletelyEmptyClaudeTurn,
  observeClaudeTurnChunk,
  retryClaudeAuthFailure,
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

test('recognizes Claude authentication failures only in error chunks', () => {
  for (const errorText of [
    'HTTP 401: authentication_failed',
    'Agent terminated early due to an API error: Failed to authenticate. API Error: 401 OAuth access token has been revoked.',
    'API Error: 401 OAuth access token has expired. Re-authenticate to continue.',
  ]) {
    assert.equal(claudeAuthFailureText({ type: 'error', errorText }), errorText);
  }
  assert.equal(claudeAuthFailureText({ type: 'error', errorText: 'HTTP 429: rate_limit_error' }), undefined);
  assert.equal(claudeAuthFailureText({ type: 'text-delta', delta: 'HTTP 401: authentication_failed' }), undefined);
});

test('retries an authentication failure once with the resume prompt, for Claude only', async () => {
  const prompts = [];
  const retry = async prompt => {
    prompts.push(prompt);
    return 'recovered';
  };
  assert.equal(await retryClaudeAuthFailure({ adapter: 'claude-code', authFailure: 'HTTP 401', retry, delayMs: 0 }), 'recovered');
  assert.equal(await retryClaudeAuthFailure({ adapter: 'codex', authFailure: 'HTTP 401', retry, delayMs: 0 }), undefined);
  assert.equal(await retryClaudeAuthFailure({ adapter: 'claude-code', authFailure: undefined, retry, delayMs: 0 }), undefined);
  assert.deepEqual(prompts, [claudeAuthResumePrompt]);
});

test('the final authentication message leads with the action and keeps the provider text', () => {
  const [first, second] = claudeAuthFailureMessage('HTTP 401: authentication_failed').split('\n');
  assert.match(first, /claude auth login/);
  assert.equal(second, 'HTTP 401: authentication_failed');
});
