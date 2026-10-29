import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { collectQuota, normalizeUsage, readCredentials } from "./quota-openai.mjs";

const credentials = { accessToken: "fixture-access-token", accountID: "acct_fixture" };
const usage = {
  account_id: "acct_fixture",
  email: "person@example.com",
  plan_type: "plus",
  rate_limit: {
    allowed: true,
    primary_window: { used_percent: 12.2, limit_window_seconds: 18_000, reset_at: 1_800_000_000 },
    secondary_window: { used_percent: 40, limit_window_seconds: 604_800 },
  },
  rate_limit_reset_credits: { available_count: 0 },
};

async function temporaryProfile(t, config, auth) {
  const root = await mkdtemp(join(tmpdir(), "dieter-openai-quota-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  if (config !== undefined) await writeFile(join(root, "config.toml"), config);
  if (auth !== undefined) await writeFile(join(root, "auth.json"), JSON.stringify(auth));
  return root;
}

// Use actual HTTP against an isolated loopback fixture; only the test adapter replaces the host.
async function provider(t, handler) {
  const calls = [];
  const server = createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    calls.push({ method: req.method, path: req.url, headers: req.headers, body });
    const reply = handler(req, calls.length);
    res.writeHead(reply.status || 200, { "content-type": "application/json", ...reply.headers });
    res.end(typeof reply.body === "string" ? reply.body : JSON.stringify(reply.body));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(
    () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(resolve);
      }),
  );
  const origin = `http://127.0.0.1:${server.address().port}`;
  const fetchImpl = (url, options) => {
    assert.equal(new URL(url).origin, "https://chatgpt.com");
    return fetch(`${origin}${new URL(url).pathname}`, options);
  };
  return { calls, fetchImpl };
}

function auth(accountID = "acct_fixture") {
  return {
    auth_mode: "chatgpt",
    tokens: {
      access_token: "fixture-access-token",
      refresh_token: "codex-owned-refresh",
      account_id: accountID,
    },
    last_refresh: "2026-10-09T00:00:00Z",
    unknown_field: "preserve-me",
  };
}

test("reads only the selected file profile and derives display metadata without changing auth", async (t) => {
  const claims = {
    email: "jwt@example.com",
    "https://api.openai.com/auth": { chatgpt_plan_type: "pro" },
  };
  const document = auth();
  document.tokens.id_token = `header.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.signature`;
  const root = await temporaryProfile(
    t,
    '[plugins."sample@marketplace"]\nenabled=true\n',
    document,
  );
  const before = await readFile(join(root, "auth.json"));
  const result = await readCredentials({ profileRoot: root, platform: "linux" });
  assert.deepEqual(result, { ...credentials, email: "jwt@example.com", plan: "pro" });
  assert.equal(result.refreshToken, undefined);
  assert.deepEqual(await readFile(join(root, "auth.json")), before);
  const other = await temporaryProfile(t, undefined, auth("acct_other"));
  assert.equal(
    (await readCredentials({ profileRoot: other, platform: "linux" })).accountID,
    "acct_other",
  );
});

test("Keychain lookup is scoped to the canonical profile, including a symlink", async (t) => {
  const root = await temporaryProfile(
    t,
    'cli_auth_credentials_store="keyring"\n',
    auth("stale-file"),
  );
  const alias = `${root}-alias`;
  await symlink(root, alias);
  t.after(() => rm(alias));
  const expectedKey = `cli|${createHash("sha256")
    .update(await realpath(root))
    .digest("hex")
    .slice(0, 16)}`;
  const keys = [];
  const result = await readCredentials({
    profileRoot: alias,
    platform: "darwin",
    readKeychain: async (key) => {
      keys.push(key);
      return JSON.stringify(auth());
    },
  });
  assert.deepEqual(keys, [expectedKey]);
  assert.equal(result.accountID, credentials.accountID);
});

test("auto store prefers Keychain and falls back to the selected file on lookup failure", async (t) => {
  const root = await temporaryProfile(t, "cli_auth_credentials_store='auto'\n", auth("acct_file"));
  assert.equal(
    (
      await readCredentials({
        profileRoot: root,
        platform: "darwin",
        readKeychain: async () => JSON.stringify(auth("acct_keychain")),
      })
    ).accountID,
    "acct_keychain",
  );
  assert.equal(
    (
      await readCredentials({
        profileRoot: root,
        platform: "darwin",
        readKeychain: async () => {
          throw new Error("fixture failure");
        },
      })
    ).accountID,
    "acct_file",
  );
  assert.equal(
    (
      await readCredentials({
        profileRoot: root,
        platform: "darwin",
        readKeychain: async () => undefined,
      })
    ).accountID,
    "acct_file",
  );
  assert.equal(
    (
      await readCredentials({
        profileRoot: root,
        platform: "darwin",
        readKeychain: async () => "not json",
      })
    ).accountID,
    "acct_file",
  );
});

test("missing Keychain credentials never fall back to a stale file or another profile", async (t) => {
  const root = await temporaryProfile(
    t,
    'cli_auth_credentials_store="keyring"\n',
    auth("stale-file"),
  );
  assert.deepEqual(
    await readCredentials({
      profileRoot: root,
      platform: "darwin",
      readKeychain: async () => undefined,
    }),
    { availability: "signed_out" },
  );
});

test("signed-out, API key and process-only profiles make no provider requests", async (t) => {
  for (const [config, document, expected] of [
    [undefined, undefined, "signed_out"],
    [undefined, { OPENAI_API_KEY: "fixture-api-key" }, "unsupported"],
    ['cli_auth_credentials_store="ephemeral"\n', auth(), "unsupported"],
    ['cli_auth_credentials_store="keyring"\n', auth(), "unsupported"],
    ['cli_auth_credentials_store="auto"\n', auth(), "unsupported"],
    [
      'cli_auth_credentials_store="auto"\n[features]\nsecret_auth_storage=true\n',
      auth(),
      "unsupported",
    ],
  ]) {
    const root = await temporaryProfile(t, config, document);
    const read = await readCredentials({ profileRoot: root, platform: "linux" });
    const result = await collectQuota({
      credentials: read,
      fetchImpl: () => assert.fail("provider must not be contacted"),
    });
    assert.equal(result.availability, expected);
    assert.equal(JSON.stringify(result).includes("fixture-api-key"), false);
  }
});

test("normalizes windows, credits, spend and reset details using provider permission", () => {
  const result = normalizeUsage(
    credentials,
    {
      ...usage,
      rate_limit: { ...usage.rate_limit, allowed: false },
      additional_rate_limits: [
        {
          metered_feature: "codex_other",
          rate_limit: { primary_window: { used_percent: 150, limit_window_seconds: 2_592_000 } },
        },
      ],
      credits: { balance: 25.5, has_credits: true, unlimited: false },
      spend_control: {
        individual_limit: {
          used: "2.50",
          limit: "10.00",
          remaining_percent: 75,
          reset_at: 1_800_000_000,
        },
      },
      rate_limit_reset_credits: { available_count: 2 },
    },
    {
      available_count: 1,
      credits: [
        {
          title: "Full reset",
          reset_type: "codex_rate_limits",
          status: "available",
          granted_at: "2026-10-01T00:00:00Z",
          expires_at: "2026-11-01T00:00:00Z",
        },
      ],
    },
  );
  assert.equal(result.stableAccountID, "acct_fixture");
  assert.equal(result.displayEmail, "person@example.com");
  assert.equal(result.plan, "plus");
  assert.deepEqual(
    result.windows.map((w) => [w.id, w.kind, w.usedPercent, w.remainingPercent]),
    [
      ["codex:primary", "five_hour", 13, 87],
      ["codex:secondary", "weekly", 40, 60],
      ["codex_other:primary", "monthly", 100, 0],
    ],
  );
  assert.equal(result.windows[0].resetsAt, "2027-01-15T08:00:00.000Z");
  assert.deepEqual(result.credits, { balance: "25.5", hasCredits: true, unlimited: false });
  assert.deepEqual(result.spendAllowance, {
    used: "2.50",
    limit: "10.00",
    remainingPercent: 75,
    resetsAt: "2027-01-15T08:00:00.000Z",
  });
  assert.equal(result.resetCredits.availableCount, 1);
  assert.equal(result.resetCredits.details[0].grantedAt, "2026-10-01T00:00:00.000Z");
  assert.equal(result.ordinaryUsageAllowed, false);
  assert.equal(
    normalizeUsage(credentials, { ...usage, rate_limit: { primary_window: { used_percent: 100 } } })
      .ordinaryUsageAllowed,
    undefined,
  );
});

test("direct HTTP read uses only usage when the reset count is zero", async (t) => {
  const fixture = await provider(t, () => ({ body: usage }));
  const result = await collectQuota({ credentials, env: {}, fetchImpl: fixture.fetchImpl });
  assert.equal(result.windows[0].remainingPercent, 87);
  assert.equal(fixture.calls.length, 1);
  assert.equal(fixture.calls[0].path, "/backend-api/wham/usage");
  assert.equal(fixture.calls[0].headers.authorization, "Bearer fixture-access-token");
  assert.equal(fixture.calls[0].headers["chatgpt-account-id"], "acct_fixture");
  assert.equal(JSON.stringify(result).includes("fixture-access-token"), false);
});

test("reset details enrich a nonzero or missing summary, with a summary fallback on failure", async (t) => {
  for (const count of [2, undefined]) {
    const fixture = await provider(t, (req) =>
      req.url.endsWith("/usage")
        ? {
            body: {
              ...usage,
              rate_limit_reset_credits:
                count === undefined ? undefined : { available_count: count },
            },
          }
        : { body: { available_count: 3, credits: [] } },
    );
    const result = await collectQuota({ credentials, env: {}, fetchImpl: fixture.fetchImpl });
    assert.equal(result.resetCredits.availableCount, 3);
    assert.equal(fixture.calls.length, 2);
  }
  const fixture = await provider(t, (req) =>
    req.url.endsWith("/usage")
      ? { body: { ...usage, rate_limit_reset_credits: { available_count: 2 } } }
      : { status: 503, body: {} },
  );
  assert.equal(
    (await collectQuota({ credentials, env: {}, fetchImpl: fixture.fetchImpl })).resetCredits
      .availableCount,
    2,
  );
  assert.equal(
    normalizeUsage(
      credentials,
      { ...usage, rate_limit_reset_credits: { available_count: 2 } },
      { available_count: null },
    ).resetCredits.availableCount,
    2,
  );
});

test("expired credentials are never refreshed or rewritten", async (t) => {
  const root = await temporaryProfile(t, undefined, auth());
  const before = await readFile(join(root, "auth.json"));
  for (const status of [401, 403]) {
    const fixture = await provider(t, () => ({
      status,
      body: { error: "fixture-secret-do-not-print" },
    }));
    await assert.rejects(
      collectQuota({
        credentials: await readCredentials({ profileRoot: root, platform: "linux" }),
        env: {},
        fetchImpl: fixture.fetchImpl,
      }),
      /^Error: OpenAI quota request failed$/,
    );
    assert.equal(fixture.calls.length, 1);
    assert.deepEqual(await readFile(join(root, "auth.json")), before);
  }
});

test("reset validates identity, forwards the caller idempotency key and rereads usage", async (t) => {
  for (const [code, outcome] of [
    ["reset", "reset"],
    ["nothing_to_reset", "nothingToReset"],
    ["no_credit", "noCredit"],
    ["already_redeemed", "alreadyRedeemed"],
  ]) {
    const fixture = await provider(t, (req) => ({
      body: req.method === "POST" ? { code } : usage,
    }));
    const result = await collectQuota({
      credentials,
      env: {
        DIETER_QUOTA_ACTION: "consume_reset",
        DIETER_QUOTA_IDEMPOTENCY_KEY: "exact-request-key",
        DIETER_QUOTA_EXPECTED_ACCOUNT_ID: "acct_fixture",
      },
      fetchImpl: fixture.fetchImpl,
    });
    assert.equal(result.resetOutcome, outcome);
    assert.deepEqual(
      fixture.calls.map((c) => [c.method, c.path]),
      [
        ["GET", "/backend-api/wham/usage"],
        ["POST", "/backend-api/wham/rate-limit-reset-credits/consume"],
        ["GET", "/backend-api/wham/usage"],
      ],
    );
    assert.deepEqual(JSON.parse(fixture.calls[1].body), { redeem_request_id: "exact-request-key" });
  }
});

test("changed account or missing idempotency key prevents reset mutation", async (t) => {
  for (const [returnedID, expectedID, key] of [
    ["acct_changed", "acct_fixture", "key"],
    ["acct_fixture", "acct_changed", "key"],
    ["acct_fixture", "acct_fixture", undefined],
  ]) {
    const fixture = await provider(t, () => ({ body: { ...usage, account_id: returnedID } }));
    await assert.rejects(
      collectQuota({
        credentials,
        env: {
          DIETER_QUOTA_ACTION: "consume_reset",
          DIETER_QUOTA_IDEMPOTENCY_KEY: key,
          DIETER_QUOTA_EXPECTED_ACCOUNT_ID: expectedID,
        },
        fetchImpl: fixture.fetchImpl,
      }),
    );
    assert.equal(fixture.calls.length, 1);
    assert.equal(fixture.calls[0].method, "GET");
  }
});

test("HTTP bodies, credential files, redirects and cancellation are bounded", async (t) => {
  for (const reply of [
    { body: "x".repeat(64 * 1024 + 1) },
    { body: "<html>fixture-secret</html>" },
    { status: 302, headers: { location: "https://example.invalid/" }, body: {} },
  ]) {
    const fixture = await provider(t, () => reply);
    await assert.rejects(collectQuota({ credentials, env: {}, fetchImpl: fixture.fetchImpl }));
    assert.equal(fixture.calls.length, 1);
  }
  const fixture = await provider(t, () => ({ body: usage }));
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    collectQuota({ credentials, env: {}, fetchImpl: fixture.fetchImpl, signal: controller.signal }),
  );
  assert.equal(fixture.calls.length, 0);
  const root = await temporaryProfile(t, undefined, auth());
  await writeFile(join(root, "auth.json"), "x".repeat(64 * 1024 + 1));
  await assert.rejects(
    readCredentials({ profileRoot: root, platform: "linux" }),
    /exceeded its limit/,
  );
});

test("executable quota probe never starts Codex or Git, even with configured plugins", async (t) => {
  const root = await temporaryProfile(t, '[plugins."sample@marketplace"]\nenabled=true\n', auth());
  const bin = join(root, "bin");
  await mkdir(bin);
  const marker = join(root, "unexpected-process");
  for (const command of ["codex", "git", "security"]) {
    await writeFile(join(bin, command), `#!/bin/sh\n: > '${marker}'\nexit 1\n`, { mode: 0o700 });
  }
  const adapter = join(root, "fetch-fixture.mjs");
  await writeFile(
    adapter,
    `globalThis.fetch = async (url) => {\n  if (url !== 'https://chatgpt.com/backend-api/wham/usage') throw new Error('unexpected URL');\n  return new Response(${JSON.stringify(JSON.stringify(usage))});\n};\n`,
  );
  const script = fileURLToPath(new URL("./quota-openai.mjs", import.meta.url));
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--import", adapter, script], {
      env: { PATH: bin, CODEX_HOME: root },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const timeout = setTimeout(() => child.kill("SIGKILL"), 5_000);
    let stdout = "",
      stderr = "";
    child.stdout.on("data", (data) => {
      stdout += data;
    });
    child.stderr.on("data", (data) => {
      stderr += data;
    });
    child.once("error", reject);
    child.once("close", (code) => {
      clearTimeout(timeout);
      resolve({ code, stdout, stderr });
    });
  });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).stableAccountID, "acct_fixture");
  assert.equal(result.stderr, "");
  await assert.rejects(readFile(marker), { code: "ENOENT" });
});
