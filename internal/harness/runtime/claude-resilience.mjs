const claudeRetryExhaustedPattern = /Claude Code API retry:\s*attempt\s+(\d+)\/(\d+);\s*HTTP\s+(\d+)/i;

export const emptyClaudeResumePrompt = 'The previous continuation ended without producing any output. Continue from the current session state and respond to the user\'s latest message now. Inspect the current state before repeating any action that may already have completed.';

function totalTokens(chunk) {
  const direct = chunk?.messageMetadata?.usage?.totalTokens ?? chunk?.usage?.totalTokens;
  if (Number.isFinite(direct)) return Number(direct);
  return undefined;
}

export function createClaudeTurnSummary() {
  return { meaningful: false, totalTokens: undefined };
}

export function observeClaudeTurnChunk(summary, chunk) {
  if (!summary || !chunk || typeof chunk !== 'object') return false;
  const tokens = totalTokens(chunk);
  if (tokens !== undefined) summary.totalTokens = tokens;

  let meaningful = false;
  switch (chunk.type) {
    case 'text-delta':
    case 'reasoning-delta':
      meaningful = Boolean(String(chunk.delta || '').trim());
      break;
    case 'tool-input-available':
    case 'tool-output-available':
    case 'tool-output-error':
    case 'tool-approval-request':
      meaningful = true;
      break;
  }
  if (meaningful) summary.meaningful = true;
  return meaningful;
}

export function isCompletelyEmptyClaudeTurn(summary) {
  return Boolean(summary) && !summary.meaningful && summary.totalTokens === 0;
}

export async function retryEmptyClaudeResume({ adapter, hasResumeSession, continuing, firstSummary, retry }) {
  if (adapter !== 'claude-code' || !hasResumeSession || continuing || !isCompletelyEmptyClaudeTurn(firstSummary)) {
    return firstSummary;
  }
  const retriedSummary = await retry(emptyClaudeResumePrompt);
  if (isCompletelyEmptyClaudeTurn(retriedSummary)) {
    throw new Error('Claude Code resumed the session twice without producing output; the durable session is preserved and can be resumed with another message.');
  }
  return retriedSummary;
}

function chunkText(chunk, encoding) {
  if (typeof chunk === 'string') return chunk;
  try {
    return Buffer.from(chunk).toString(typeof encoding === 'string' ? encoding : 'utf8');
  } catch {
    return '';
  }
}

export function createClaudeDiagnosticTracker() {
  let buffered = '';
  let activeTurn;

  function inspectLine(line) {
    if (!activeTurn) return;
    const match = claudeRetryExhaustedPattern.exec(line);
    if (!match) return;
    const attempt = Number(match[1]);
    const maximum = Number(match[2]);
    if (!Number.isFinite(attempt) || !Number.isFinite(maximum) || attempt < maximum) return;
    activeTurn.providerFailure = `Claude Code API request failed after ${maximum} retries: HTTP ${match[3]}`;
  }

  return {
    beginTurn() {
      const turn = { providerFailure: undefined };
      activeTurn = turn;
      return turn;
    },
    observeStderr(chunk, encoding) {
      const text = chunkText(chunk, encoding);
      if (!text) return;
      const lines = `${buffered}${text}`.replace(/\r\n/g, '\n').split('\n');
      buffered = lines.pop() || '';
      for (const line of lines) inspectLine(line);
    },
    observeActivity(turn) {
      if (activeTurn === turn) turn.providerFailure = undefined;
    },
    endTurn(turn) {
      if (activeTurn !== turn) return undefined;
      if (buffered) {
        inspectLine(buffered);
        buffered = '';
      }
      activeTurn = undefined;
      return turn.providerFailure;
    },
  };
}
