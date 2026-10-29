import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { open, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import process from "node:process";
import { parse as parseTOML } from "smol-toml";

const maxInputBytes = 64 * 1024;
const baseURL = "https://chatgpt.com/backend-api/wham";

async function readBoundedFile(path, limit = maxInputBytes) {
  let file;
  try {
    file = await open(path, "r");
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
  try {
    const buffer = Buffer.alloc(limit + 1);
    let size = 0;
    while (size < buffer.length) {
      const { bytesRead } = await file.read(buffer, size, buffer.length - size, null);
      if (!bytesRead) break;
      size += bytesRead;
    }
    if (size > limit) throw new Error("OpenAI credential input exceeded its limit");
    return buffer.subarray(0, size).toString("utf8");
  } finally {
    await file.close();
  }
}

function readMacKeychain(account) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(
      "security",
      ["find-generic-password", "-s", "Codex Auth", "-a", account, "-w"],
      { stdio: ["ignore", "pipe", "ignore"] },
    );
    const chunks = [];
    let size = 0;
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, 6_000);
    child.stdout.on("data", (chunk) => {
      size += chunk.length;
      if (size <= maxInputBytes) chunks.push(chunk);
      else child.kill("SIGKILL");
    });
    child.once("error", () => {
      clearTimeout(timer);
      reject(new Error("OpenAI Keychain lookup failed"));
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (timedOut || size > maxInputBytes)
        reject(new Error("OpenAI Keychain lookup exceeded its limit"));
      else if (code === 44)
        resolveResult(undefined); // errSecItemNotFound
      else if (code !== 0) reject(new Error("OpenAI Keychain lookup failed"));
      else resolveResult(Buffer.concat(chunks).toString("utf8"));
    });
  });
}

function tokenClaims(token) {
  try {
    return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
  } catch {
    return {};
  }
}

export async function readCredentials({
  profileRoot = resolve(process.env.CODEX_HOME || join(homedir(), ".codex")),
  platform = process.platform,
  readKeychain = readMacKeychain,
} = {}) {
  const configText = await readBoundedFile(join(profileRoot, "config.toml"), 1024 * 1024);
  const config = configText === undefined ? {} : parseTOML(configText);
  const mode = config.cli_auth_credentials_store || "file";
  if (!["file", "keyring", "auto", "ephemeral"].includes(mode)) {
    throw new Error("OpenAI credential-store mode is invalid");
  }
  if (mode === "ephemeral") return { availability: "unsupported" };
  // Encrypted secret storage is owned by Codex and cannot be read as a Keychain JSON item.
  if (mode !== "file" && config.features?.secret_auth_storage)
    return { availability: "unsupported" };
  let auth;
  if (mode === "keyring" || mode === "auto") {
    // A stale fallback file must not stand in for an unreadable active keyring account.
    if (platform !== "darwin") return { availability: "unsupported" };
    const canonical = await realpath(profileRoot).catch(() => resolve(profileRoot));
    const account = `cli|${createHash("sha256").update(canonical).digest("hex").slice(0, 16)}`;
    try {
      const document = await readKeychain(account);
      if (document !== undefined) auth = JSON.parse(document);
    } catch (error) {
      if (mode === "keyring") throw error;
    }
  }
  if (auth === undefined && mode !== "keyring") {
    const document = await readBoundedFile(join(profileRoot, "auth.json"));
    if (document !== undefined) auth = JSON.parse(document);
  }
  if (auth === undefined) return { availability: "signed_out" };
  const modeFromAuth = auth.auth_mode || (auth.OPENAI_API_KEY ? "apikey" : "chatgpt");
  if (modeFromAuth !== "chatgpt") {
    return {
      availability: "unsupported",
      accountKind: modeFromAuth === "apikey" ? "api" : undefined,
    };
  }
  const accessToken = auth.tokens?.access_token;
  if (typeof accessToken !== "string" || !accessToken) return { availability: "signed_out" };
  // JWT claims provide display metadata only; the usage API verifies the bearer and account.
  const claims = tokenClaims(auth.tokens?.id_token || accessToken);
  const metadata = claims["https://api.openai.com/auth"];
  return {
    accessToken,
    accountID: auth.tokens?.account_id || metadata?.chatgpt_account_id,
    email: claims.email,
    plan: metadata?.chatgpt_plan_type,
  };
}

function percent(value) {
  return Number.isFinite(value) ? Math.max(0, Math.min(100, Math.ceil(value))) : undefined;
}

function iso(value) {
  if (typeof value !== "string" && (!Number.isFinite(value) || value <= 0)) return undefined;
  const date = new Date(typeof value === "string" ? value : value * 1000);
  return Number.isFinite(date.getTime()) ? date.toISOString() : undefined;
}

function normalizeWindow(bucketID, position, value) {
  const usedPercent = percent(value?.used_percent);
  if (usedPercent === undefined) return undefined;
  const seconds = value.limit_window_seconds;
  const duration = Number.isInteger(seconds) && seconds > 0 ? Math.floor(seconds / 60) : undefined;
  const kind =
    duration === 300
      ? "five_hour"
      : duration === 10_080
        ? "weekly"
        : duration >= 40_000 && duration <= 45_000
          ? "monthly"
          : "other";
  const label =
    kind === "five_hour"
      ? "5h"
      : kind === "weekly"
        ? "Week"
        : kind === "monthly"
          ? "Month"
          : position === "primary"
            ? "Primary"
            : "Secondary";
  return {
    id: `${bucketID}:${position}`,
    label,
    kind,
    usedPercent,
    remainingPercent: 100 - usedPercent,
    durationMinutes: duration,
    resetsAt: iso(value.reset_at ?? value.resets_at),
  };
}

function scalar(value) {
  return typeof value === "string" || typeof value === "number" ? String(value) : undefined;
}

export function normalizeUsage(credentials, usage, details) {
  const windows = [];
  const buckets = [["codex", usage.rate_limit]];
  for (const limit of (Array.isArray(usage.additional_rate_limits)
    ? usage.additional_rate_limits
    : []
  ).slice(0, 16)) {
    buckets.push([
      String(limit.metered_feature || limit.limit_name || "default").slice(0, 128),
      limit.rate_limit,
    ]);
  }
  for (const [id, limit] of buckets) {
    for (const position of ["primary", "secondary"]) {
      const window = normalizeWindow(id, position, limit?.[`${position}_window`]);
      if (window) windows.push(window);
    }
  }
  const summary = usage.rate_limit_reset_credits;
  const reset = Number.isInteger(details?.available_count) ? details : summary;
  const individual = usage.spend_control?.individual_limit;
  return {
    stableAccountID: usage.account_id || credentials.accountID,
    displayEmail: usage.email || credentials.email,
    accountKind: "subscription",
    plan: usage.plan_type || credentials.plan,
    availability: "available",
    windows: windows.slice(0, 16),
    credits: usage.credits
      ? {
          balance: scalar(usage.credits.balance),
          hasCredits: Boolean(usage.credits.has_credits),
          unlimited: Boolean(usage.credits.unlimited),
        }
      : undefined,
    spendAllowance:
      individual && typeof individual === "object"
        ? {
            used: scalar(individual.used),
            limit: scalar(individual.limit),
            remainingPercent: percent(individual.remaining_percent),
            resetsAt: iso(individual.reset_at),
          }
        : undefined,
    resetCredits:
      Number.isInteger(reset?.available_count) && reset.available_count >= 0
        ? {
            availableCount: reset.available_count,
            details: (Array.isArray(details?.credits) ? details.credits : [])
              .slice(0, 32)
              .map((credit) => ({
                title: credit.title || credit.description || "Rate-limit reset",
                kind: credit.reset_type,
                status: credit.status,
                grantedAt: iso(credit.granted_at),
                expiresAt: iso(credit.expires_at),
              })),
          }
        : undefined,
    ordinaryUsageAllowed:
      typeof usage.rate_limit?.allowed === "boolean" ? usage.rate_limit.allowed : undefined,
  };
}

async function request(path, credentials, fetchImpl, signal, body) {
  const headers = {
    authorization: `Bearer ${credentials.accessToken}`,
    accept: "application/json",
    "user-agent": "dieter-quota/1",
  };
  if (credentials.accountID) headers["ChatGPT-Account-Id"] = credentials.accountID;
  if (body) headers["content-type"] = "application/json";
  const response = await fetchImpl(`${baseURL}/${path}`, {
    method: body ? "POST" : "GET",
    headers,
    body: body ? JSON.stringify(body) : undefined,
    redirect: "error",
    signal: AbortSignal.any([signal, AbortSignal.timeout(8_000)]),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error("OpenAI quota request failed");
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > maxInputBytes) throw new Error("OpenAI quota response exceeded its limit");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function verifyAccount(credentials, usage) {
  const id = usage.account_id || credentials.accountID;
  if (
    typeof id !== "string" ||
    !id ||
    (usage.account_id && credentials.accountID && usage.account_id !== credentials.accountID)
  ) {
    throw new Error("OpenAI quota account identity is invalid");
  }
  return id;
}

export async function collectQuota({
  credentials,
  env = process.env,
  fetchImpl = fetch,
  signal = AbortSignal.timeout(12_000),
}) {
  if (credentials.availability) return credentials;
  const action = env.DIETER_QUOTA_ACTION || "read";
  if (!["read", "consume_reset"].includes(action))
    throw new Error("OpenAI quota action is invalid");
  let usage = await request("usage", credentials, fetchImpl, signal);
  const accountID = verifyAccount(credentials, usage);
  let resetOutcome;
  if (action === "consume_reset") {
    const idempotencyKey = env.DIETER_QUOTA_IDEMPOTENCY_KEY;
    if (!idempotencyKey || accountID !== env.DIETER_QUOTA_EXPECTED_ACCOUNT_ID) {
      throw new Error("OpenAI quota reset identity or idempotency key is invalid");
    }
    // Bind every subsequent request to the account verified before this mutation.
    credentials = { ...credentials, accountID };
    const reset = await request(
      "rate-limit-reset-credits/consume",
      credentials,
      fetchImpl,
      signal,
      {
        redeem_request_id: idempotencyKey,
      },
    );
    resetOutcome = new Map([
      ["reset", "reset"],
      ["nothing_to_reset", "nothingToReset"],
      ["no_credit", "noCredit"],
      ["already_redeemed", "alreadyRedeemed"],
    ]).get(reset.code);
    if (!resetOutcome) throw new Error("OpenAI quota reset outcome is invalid");
    usage = await request("usage", credentials, fetchImpl, signal);
    verifyAccount(credentials, usage);
  }
  let details;
  if (usage.rate_limit_reset_credits?.available_count !== 0) {
    try {
      details = await request(
        "rate-limit-reset-credits",
        { ...credentials, accountID },
        fetchImpl,
        signal,
      );
    } catch {
      // Credit details are optional; retain the count in a successful usage response.
    }
  }
  return { ...normalizeUsage(credentials, usage, details), resetOutcome };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const signal = AbortSignal.timeout(12_000);
    const credentials = await readCredentials();
    process.stdout.write(`${JSON.stringify(await collectQuota({ credentials, signal }))}\n`);
  } catch {
    process.stderr.write("OpenAI quota probe failed\n");
    process.exitCode = 1;
  }
}
