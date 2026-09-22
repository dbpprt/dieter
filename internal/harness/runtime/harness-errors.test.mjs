import assert from 'node:assert/strict';
import test from 'node:test';
import { harnessDiagnosticErrorMessage } from './harness-errors.mjs';

test('preserves bounded ACP JSON-RPC details in worker diagnostics', () => {
  const error = new Error('Internal error');
  error.data = { details: 'Unknown ACP model: openrouter/openai/gpt-6-sol', secret: 'not serialized' };
  assert.equal(
    harnessDiagnosticErrorMessage(error),
    'Internal error: Unknown ACP model: openrouter/openai/gpt-6-sol',
  );
});

test('finds ACP details through wrapped causes and retains ordinary messages', () => {
  const provider = new Error('Internal error');
  provider.data = { details: 'Provider rejected the request' };
  assert.equal(
    harnessDiagnosticErrorMessage(new Error('bridge turn failed', { cause: provider })),
    'bridge turn failed: Provider rejected the request',
  );
  assert.equal(harnessDiagnosticErrorMessage(new Error('plain failure')), 'plain failure');
});

test('bounds provider-controlled diagnostic text', () => {
  const error = new Error('Internal error');
  error.data = { details: 'x'.repeat(5000) };
  assert.equal(harnessDiagnosticErrorMessage(error).length, 4096 + 'Internal error: '.length);
  assert.match(harnessDiagnosticErrorMessage(error), /\.\.\.$/);
});
