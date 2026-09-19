import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import process from 'node:process';

const maxCommandOutput = 64 * 1024;

function run(command, args, timeout = 6_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: process.env, stdio: ['ignore', 'pipe', 'ignore'] });
    const chunks = [];
    let size = 0;
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size <= maxCommandOutput) chunks.push(chunk);
    });
    child.once('error', error => {
      clearTimeout(timer);
      reject(error);
    });
    child.once('close', code => {
      clearTimeout(timer);
      if (code !== 0 || size > maxCommandOutput) reject(new Error('command failed'));
      else resolve(Buffer.concat(chunks).toString('utf8'));
    });
  });
}

async function readCredentials() {
  if (process.env.CLAUDE_CODE_OAUTH_TOKEN) {
    return { accessToken: process.env.CLAUDE_CODE_OAUTH_TOKEN };
  }
  const configDirectory = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
  for (const path of [join(configDirectory, '.credentials.json'), join(configDirectory, 'credentials.json')]) {
    try {
      const parsed = JSON.parse(await readFile(path, 'utf8'));
      if (parsed?.claudeAiOauth || parsed?.accessToken || parsed?.access_token) return parsed;
    } catch {
      // Claude Code stores OAuth credentials in the system keychain on macOS.
    }
  }
  if (process.platform === 'darwin') {
    const parsed = JSON.parse(await run('security', [
      'find-generic-password', '-s', 'Claude Code-credentials', '-w',
    ]));
    if (parsed?.claudeAiOauth) return parsed;
  }
  throw new Error('Claude credentials are unavailable');
}

function percent(value) {
  if (!Number.isFinite(value)) return undefined;
  return Math.max(0, Math.min(100, Math.ceil(value)));
}

function normalizeWindow(id, label, kind, durationMinutes, value) {
  const usedPercent = percent(value?.utilization);
  if (usedPercent === undefined) return undefined;
  return {
    id,
    label,
    kind,
    usedPercent,
    remainingPercent: 100 - usedPercent,
    durationMinutes,
    resetsAt: typeof value?.resets_at === 'string' ? value.resets_at : undefined,
  };
}

function money(value) {
  if (!value || !Number.isInteger(value.amount_minor) || typeof value.currency !== 'string') return undefined;
  const exponent = Number.isInteger(value.exponent) ? value.exponent : 2;
  return `${(value.amount_minor / (10 ** exponent)).toFixed(Math.max(0, exponent))} ${value.currency.toUpperCase()}`;
}

export function normalizeUsage(auth, response) {
  const windows = [
    normalizeWindow('five_hour', '5h', 'five_hour', 300, response?.five_hour),
    normalizeWindow('seven_day', 'Week', 'weekly', 10_080, response?.seven_day),
    normalizeWindow('seven_day_opus', 'Opus week', 'model', 10_080, response?.seven_day_opus),
    normalizeWindow('seven_day_sonnet', 'Sonnet week', 'model', 10_080, response?.seven_day_sonnet),
  ].filter(Boolean);
  const spend = response?.spend;
  const spendAllowance = spend?.enabled
    ? {
        used: money(spend.used),
        limit: money(spend.limit),
        currency: String(spend.used?.currency || spend.limit?.currency || '').toUpperCase() || undefined,
        remainingPercent: percent(Number.isFinite(spend.percent) ? 100 - spend.percent : undefined),
      }
    : undefined;
  const stableAccountID = `${auth.orgId || ''}\u0000${String(auth.email || '').trim().toLowerCase()}`;
  const ordinaryUsageAllowed = windows.length > 0
    ? windows.every(window => window.remainingPercent > 0)
    : undefined;
  return {
    stableAccountID,
    displayEmail: auth.email || undefined,
    accountKind: 'subscription',
    plan: auth.subscriptionType || undefined,
    availability: 'available',
    windows,
    spendAllowance,
    ordinaryUsageAllowed,
  };
}

async function main() {
  const auth = JSON.parse(await run('claude', ['auth', 'status', '--json']));
  if (!auth?.loggedIn) {
    process.stdout.write(`${JSON.stringify({ availability: 'signed_out' })}\n`);
  } else {
    const stableAccountID = `${auth.orgId || ''}\u0000${String(auth.email || '').trim().toLowerCase()}`;
    if (!auth.orgId || !auth.email || auth.authMethod !== 'claude.ai' || auth.apiProvider !== 'firstParty') {
      process.stdout.write(`${JSON.stringify({
        stableAccountID,
        displayEmail: auth.email || undefined,
        accountKind: auth.authMethod === 'api_key' ? 'api' : 'subscription',
        plan: auth.subscriptionType || undefined,
        availability: 'unsupported',
      })}\n`);
    } else {
      const credentials = await readCredentials();
      const accessToken = credentials?.claudeAiOauth?.accessToken || credentials?.accessToken || credentials?.access_token;
      if (!accessToken) throw new Error('Claude OAuth access token is unavailable');
      const response = await fetch('https://api.anthropic.com/api/oauth/usage', {
        headers: {
          authorization: `Bearer ${accessToken}`,
          'anthropic-beta': 'oauth-2025-04-20',
          'content-type': 'application/json',
          'user-agent': 'dieter-quota/1',
        },
        signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) throw new Error('Claude usage request failed');
      process.stdout.write(`${JSON.stringify(normalizeUsage(auth, await response.json()))}\n`);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch {
    process.stderr.write('Claude quota probe failed\n');
    process.exitCode = 1;
  }
}
