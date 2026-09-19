import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import process from 'node:process';

const require = createRequire(import.meta.url);
const codexPackage = require.resolve('@openai/codex/package.json');
const codexCLI = join(dirname(codexPackage), 'bin', 'codex.js');
const child = spawn(process.execPath, [codexCLI, 'app-server', '--stdio'], {
  env: process.env,
  stdio: ['pipe', 'pipe', 'ignore'],
});

let nextID = 1;
const pending = new Map();
function rejectPending() {
  for (const entry of pending.values()) entry.reject(new Error('app-server stopped'));
  pending.clear();
}
child.once('error', rejectPending);
child.once('close', rejectPending);
const lines = createInterface({ input: child.stdout });
lines.on('line', line => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message?.id == null) return;
  const entry = pending.get(String(message.id));
  if (!entry) return;
  pending.delete(String(message.id));
  if (message.error) entry.reject(new Error('app-server request failed'));
  else entry.resolve(message.result);
});

function request(method, params = {}) {
  const id = nextID++;
  return new Promise((resolve, reject) => {
    pending.set(String(id), { resolve, reject });
    child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
  });
}

function notify(method) {
  child.stdin.write(`${JSON.stringify({ method })}\n`);
}

function isoFromUnix(value) {
  if (!Number.isFinite(value) || value <= 0) return undefined;
  return new Date(value * 1000).toISOString();
}

function windowKind(duration) {
  if (duration === 300) return 'five_hour';
  if (duration === 10_080) return 'weekly';
  if (duration != null && duration >= 40_000 && duration <= 45_000) return 'monthly';
  return 'other';
}

function windowLabel(duration, fallback) {
  if (duration === 300) return '5h';
  if (duration === 10_080) return 'Week';
  if (duration != null && duration >= 40_000 && duration <= 45_000) return 'Month';
  return fallback;
}

function normalizeWindow(bucketID, position, value) {
  if (!value || !Number.isInteger(value.usedPercent)) return undefined;
  const usedPercent = Math.max(0, Math.min(100, value.usedPercent));
  const durationMinutes = Number.isInteger(value.windowDurationMins)
    ? value.windowDurationMins
    : undefined;
  return {
    id: `${bucketID}:${position}`,
    label: windowLabel(durationMinutes, position === 'primary' ? 'Primary' : 'Secondary'),
    kind: windowKind(durationMinutes),
    usedPercent,
    remainingPercent: 100 - usedPercent,
    durationMinutes,
    resetsAt: isoFromUnix(value.resetsAt),
  };
}

function normalizeRateLimits(account, response) {
  const bucketEntries = response?.rateLimitsByLimitId && Object.keys(response.rateLimitsByLimitId).length > 0
    ? Object.entries(response.rateLimitsByLimitId)
    : [[response?.rateLimits?.limitId || 'default', response?.rateLimits]];
  const windows = [];
  let plan = account?.planType;
  let credits;
  let spendAllowance;
  for (const [mapID, bucket] of bucketEntries) {
    if (!bucket) continue;
    const bucketID = String(bucket.limitId || mapID || 'default').slice(0, 128);
    plan ||= bucket.planType;
    const primary = normalizeWindow(bucketID, 'primary', bucket.primary);
    const secondary = normalizeWindow(bucketID, 'secondary', bucket.secondary);
    if (primary) windows.push(primary);
    if (secondary) windows.push(secondary);
    if (!credits && bucket.credits) {
      credits = {
        balance: bucket.credits.balance ?? undefined,
        hasCredits: Boolean(bucket.credits.hasCredits),
        unlimited: Boolean(bucket.credits.unlimited),
      };
    }
    if (!spendAllowance && bucket.individualLimit) {
      spendAllowance = {
        used: bucket.individualLimit.used,
        limit: bucket.individualLimit.limit,
        remainingPercent: bucket.individualLimit.remainingPercent,
        resetsAt: isoFromUnix(bucket.individualLimit.resetsAt),
      };
    }
  }
  const resetCredits = response?.rateLimitResetCredits
    ? {
        availableCount: response.rateLimitResetCredits.availableCount,
        details: (response.rateLimitResetCredits.credits || []).slice(0, 32).map(credit => ({
          title: credit.title || credit.description || 'Rate-limit reset',
          kind: credit.resetType,
          status: credit.status,
          grantedAt: isoFromUnix(credit.grantedAt),
          expiresAt: isoFromUnix(credit.expiresAt),
        })),
      }
    : undefined;
  return {
    stableAccountID: response?.accountId,
    displayEmail: account?.type === 'chatgpt' ? account.email || undefined : undefined,
    accountKind: account?.type === 'apiKey' ? 'api' : 'subscription',
    plan,
    availability: 'available',
    windows: windows.slice(0, 16),
    credits,
    spendAllowance,
    resetCredits,
    ordinaryUsageAllowed: response?.ordinaryUsageAllowed ?? undefined,
  };
}

const deadline = setTimeout(() => child.kill('SIGKILL'), 12_000);
try {
  await request('initialize', {
    clientInfo: { name: 'dieter-quota', title: 'Dieter quota collector', version: '1' },
    capabilities: { experimentalApi: true },
  });
  notify('initialized');
  const accountResponse = await request('account/read', { refreshToken: false });
  if (!accountResponse?.account) {
    process.stdout.write(`${JSON.stringify({ availability: 'signed_out' })}\n`);
  } else {
    let resetOutcome;
    let limits;
    if (process.env.DIETER_QUOTA_ACTION === 'consume_reset') {
      const idempotencyKey = process.env.DIETER_QUOTA_IDEMPOTENCY_KEY;
      if (!idempotencyKey) throw new Error('reset idempotency key is required');
      const expectedAccountID = process.env.DIETER_QUOTA_EXPECTED_ACCOUNT_ID;
      const before = await request('account/rateLimits/read', {
        excludeResetCreditDetails: true,
        supportsLunaReserve: false,
      });
      if (!expectedAccountID || before?.accountId !== expectedAccountID) {
        throw new Error('account identity changed before reset');
      }
      const reset = await request('account/rateLimitResetCredit/consume', { idempotencyKey });
      resetOutcome = reset?.outcome;
      limits = await request('account/rateLimits/read', {
        excludeResetCreditDetails: false,
        supportsLunaReserve: false,
      });
    } else {
      limits = await request('account/rateLimits/read', {
        excludeResetCreditDetails: false,
        supportsLunaReserve: false,
      });
    }
    process.stdout.write(`${JSON.stringify({
      ...normalizeRateLimits(accountResponse.account, limits),
      resetOutcome,
    })}\n`);
  }
} catch {
  process.stderr.write('OpenAI quota probe failed\n');
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  child.stdin.end();
  child.kill('SIGTERM');
}
