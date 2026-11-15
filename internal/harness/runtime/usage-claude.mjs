// Prints the plan usage of the Claude Code login in CLAUDE_CONFIG_DIR as one
// line of normalized JSON for Dieter's provider accounts. It sends no prompt:
// the Agent SDK's accountInfo() and its usage report come from the official
// Claude Code binary, which owns the login (proposal P0.8), so Dieter never
// reads or refreshes the credential.
//
// Output: {"loggedIn":bool,"identity":{email,organization,plan},
//          "usage":{plan,windows:[{kind,label,usedPercent,resetsAt,durationMinutes}],spend,unavailable}}
import process from "node:process";
import { fileURLToPath } from "node:url";

const probeTimeoutMs = 25_000;
const maxWindows = 16;

function percent(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return Math.round(Math.max(0, Math.min(100, value)) * 10) / 10;
}

function usageWindow(kind, label, durationMinutes, value) {
  const usedPercent = percent(value?.utilization);
  if (usedPercent === undefined) return undefined;
  const window = { kind, label, usedPercent, durationMinutes };
  if (typeof value?.resets_at === "string" && value.resets_at) window.resetsAt = value.resets_at;
  return window;
}

/**
 * Normalizes accountInfo() and the SDK usage report into the shape of a
 * provider-logins usage record. Windows are labelled like the Go engine
 * labels rate_limit_event windows, so turn observations replace them.
 */
export function normalizeUsage(info, report) {
  const loggedIn = Boolean(info?.email || info?.subscriptionType);
  const plan = report?.subscription_type || info?.subscriptionType || undefined;
  const identity = {};
  if (info?.email) identity.email = String(info.email);
  if (info?.organization) identity.organization = String(info.organization);
  if (plan) identity.plan = String(plan);
  const usage = {};
  if (plan) usage.plan = String(plan);
  const limits = report?.rate_limits;
  const firstParty = !info?.apiProvider || info.apiProvider === "firstParty";
  if (!loggedIn) {
    usage.unavailable = "signed_out";
    return { loggedIn, identity, usage };
  }
  if (!firstParty || report?.rate_limits_available === false || !limits) {
    usage.unavailable = "unsupported";
    return { loggedIn, identity, usage };
  }
  const windows = [
    usageWindow("five_hour", "5h", 300, limits.five_hour),
    usageWindow("weekly", "Weekly", 10_080, limits.seven_day),
  ];
  if (Array.isArray(limits.model_scoped)) {
    for (const scoped of limits.model_scoped) {
      const label = String(scoped?.display_name || "Model").slice(0, 60);
      windows.push(usageWindow("model", label, 10_080, scoped));
    }
  } else {
    windows.push(
      usageWindow("model", "Opus", 10_080, limits.seven_day_opus),
      usageWindow("model", "Sonnet", 10_080, limits.seven_day_sonnet),
    );
  }
  usage.windows = windows.filter(Boolean).slice(0, maxWindows);
  // Extra-usage amounts are in minor units of the currency (cents for USD).
  const extra = limits.extra_usage;
  if (extra?.is_enabled && Number.isFinite(extra.monthly_limit)) {
    usage.spend = {
      used: Math.max(0, Number.isFinite(extra.used_credits) ? extra.used_credits : 0) / 100,
      limit: Math.max(0, extra.monthly_limit) / 100,
      currency: String(extra.currency || "USD").toUpperCase(),
    };
  }
  return { loggedIn, identity, usage };
}

/** Runs a prompt-less SDK session, reads account and usage, and closes it. */
export async function probe({ sdk, cwd = process.cwd(), timeoutMs = probeTimeoutMs } = {}) {
  const { query } = sdk ?? (await import("@anthropic-ai/claude-agent-sdk"));
  let release;
  const idle = new Promise((resolve) => {
    release = resolve;
  });
  async function* noPrompt() {
    await idle;
  }
  const session = query({
    prompt: noPrompt(),
    options: { cwd, settingSources: [], persistSession: false },
  });
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("the Claude usage probe timed out")), timeoutMs);
  });
  try {
    return await Promise.race([
      (async () => {
        const info = await session.accountInfo();
        if (!info?.email && !info?.subscriptionType) return normalizeUsage(info, undefined);
        const report = await session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({
          skipBehaviors: true,
        });
        return normalizeUsage(info, report);
      })(),
      timeout,
    ]);
  } finally {
    clearTimeout(timer);
    release();
    session.close?.();
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    const result = await probe();
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(0);
  } catch (error) {
    process.stderr.write(`${String(error?.message ?? error)}\n`);
    process.exit(1);
  }
}
