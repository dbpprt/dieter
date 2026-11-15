# Implementation plan: managed provider accounts

Status: implemented on branch `dieter/3f06225f6b34-managed-login-experience-for-claude`,
2026-11-14 (§16 lists what was deferred) · rationale, constraints and spike
evidence: [provider-accounts.md](provider-accounts.md)

This is the end-to-end build plan for Claude and ChatGPT accounts in Dieter:

- signing in from the Mac, iOS and Android apps (and the CLI) for any machine;
- several accounts per provider, and the account chosen per chat;
- a **Providers** page in Settings on Mac and mobile;
- plan usage (token budget) attached to each account, **replacing today's
  gateway-based provider quota mechanism completely**.

It also fixes two production problems the spike found, so they ship in the
same change:

- Codex quick titles fail silently today (proposal §4.1).
- The Claude adapter handles OAuth tokens itself (card
  `c_7152335f4a2ee3c3e65872ae`; folding it into milestone M3 is recommended,
  §15).

## 0. Decisions this plan builds on

| Decision                                                                                                                         | Source                             |
| -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Dieter never reads, refreshes, stores or replicates Claude.ai credentials; Claude Code owns each login                           | Anthropic terms, proposal §3.1     |
| One login per account per machine; accounts, login state and usage replicate, credentials never do                               | Proposal §3.3, operator 2026-11-14 |
| ChatGPT: Codex login first (device code, browser with forwarded callback); Sign in with ChatGPT (SIWC) as a second method in M10 | Operator 2026-11-14                |
| Dieter-owned Codex home `DIETER_HOME/codex`; existing Dieter Codex threads do not resume (clean break)                           | Operator 2026-11-14                |
| Quick-title fix ships in the same change, not as a separate card                                                                 | Operator 2026-11-14                |
| The gateway quota pipeline is deleted; usage lives on the account records, replicated end-to-end encrypted between daemons       | This request                       |
| No compatibility layers: one release raises the client and daemon floors                                                         | Invariants, operator preference    |

## 1. Architecture

```text
 App (Mac / iOS / Android) ── Kotlin core `providers` ──┐
   Settings › Providers, composer Account picker,       │  ProviderAccountService RPCs
   sign-in sheet, usage meters                          │  (mutual TLS: direct, WebRTC, relay)
                                                        ▼
 CLI `dieter provider …` ─────────────────────▶ daemon (any machine for account-wide edits,
                                                 the target machine for sign-in)
                                                   internal/api/provider_accounts.go
                                                   internal/engine/accounts
                                                     ├─ Registry      KV records (accounts, defaults, logins)
                                                     ├─ Logins        claude auth login | codex app-server | SIWC
                                                     ├─ Homes         shadow Claude config dirs, DIETER_HOME/codex
                                                     ├─ Broker        per-account Codex/SIWC access tokens
                                                     ├─ Usage         probes, turn-observed limits, token ledger
                                                     └─ Status        login checks, adoption, cleanup
                                                   internal/engine turn admission ──▶ runner.mjs (auth, env)
 daemons ◀══ peer sync (kv.provider-*) ══▶ daemons            gateway: no provider data at all
```

- **Account-wide data** (accounts, defaults) is written through the
  ProviderAccountService on any reachable daemon and replicates as KV records.
- **Machine-scoped data** (login state, usage observed on that machine) uses
  single-writer KV records keyed by daemon. Only that daemon writes them, the
  same convention as `channel-claims`.
- **Secrets never enter KV.** Every client and peer can read KV records
  (`GetKV`, `WatchChanges`). Credentials stay in the provider tool's store or
  in a 0600 file under `DIETER_HOME/provider-accounts/<id>/`.
- **Clients read accounts from their account replica** (`AccountSnapshot.kv`),
  so the Providers page works offline from cache. Sign-in sessions are live
  RPC streams to the target machine.

## 2. Data model

### 2.1 Replicated KV namespaces

They are validated strictly in `internal/replication/schema/provider_accounts.go`
(modelled on `schema/channel.go`: `strictJSON` with `DisallowUnknownFields`
and bounded strings). `internal/api/kv.go` refuses public writes to them.

**`provider-accounts`**: one key per account, `pa_<26 base32>`. Any daemon
writes it with compare-and-set; deletion is a tombstone.

```json
{
  "provider": "claude" | "chatgpt",
  "label": "Work",                      // 1–60 runes, single line
  "method": "claude-code" | "codex" | "siwc" | "host" | "environment",
  "identity": {                         // empty until the first verified sign-in
    "email": "…", "organization": "…", "organizationId": "…",
    "workspaceId": "…", "subject": "…", "plan": "max"
  },
  "includeInSummary": true,
  "siwc": { "clientId": "oaiapp_…" },  // SIWC only; a public client id, not a secret
  "createdAt": "RFC3339", "createdBy": "<daemonId>"
}
```

**`provider-account-defaults`**: key `claude` or `chatgpt`, value
`{"accountId":"pa_…"}`.

**`provider-logins`**: key `<accountId>.<daemonId>`, single writer.

```json
{
  "state": "signed_in" | "signed_out" | "expired" | "failed",
  "method": "claude-code" | "codex" | "siwc" | "host" | "environment",
  "identity": { … },                    // what this machine verified
  "verifiedAt": "RFC3339",
  "error": { "code": "identity_mismatch", "message": "…" },
  "usage": {                             // newest provider-reported limits seen by this machine
    "plan": "max", "observedAt": "RFC3339", "source": "probe" | "turn",
    "windows": [ { "kind": "five_hour" | "weekly" | "model" | "other",
                   "label": "Weekly", "usedPercent": 12.0,
                   "resetsAt": "RFC3339", "durationMinutes": 10080 } ],
    "credits": { "balance": "…", "unlimited": false },
    "spend": { "used": 0, "limit": 0, "currency": "USD" },
    "resetCredits": { "available": 1 },
    "unavailable": "signed_out" | "unsupported" | "rate_limited" | ""
  },
  "dieterTokens": {                      // Dieter's own turns on this account, from this machine
    "fiveHour": { "input": 0, "output": 0, "total": 0 },
    "sevenDay": { "input": 0, "output": 0, "total": 0 },
    "observedAt": "RFC3339"
  }
}
```

- **Bounds.** At most 16 windows, value at most 8 KiB (the CRDT limit is
  32 KiB), keys valid for `crdt.ValidID`.
- **Clients merge usage per account** by taking the freshest `usage` across
  that account's login records. They sum `dieterTokens` across machines.
- **Peer-write gap.** `PeerService.PutPeerRecord` reaches
  `kanban.ValidatePeerWrite`, which accepts every KV kind today. Extend it to
  refuse `kv.provider-*` and `kv.channel*` on that generic path. That closes
  the gap the spike's Explore pass found for channels too.

### 2.2 Local, never replicated

```text
DIETER_HOME/
  codex/                          shared CODEX_HOME for every Dieter Codex turn and quick title
    config.toml                   rendered: the user's ~/.codex/config.toml + Dieter's provider block
  provider-accounts/
    <accountId>/
      claude/                     CLAUDE_CONFIG_DIR (canonical path, never a symlink)
        .claude.json              Claude Code's own; Dieter mirrors only `mcpServers` into it
        projects -> ~/.claude/projects        shadow symlinks (§4.3)
        settings.json, CLAUDE.md, skills/, agents/, commands/, plugins/ -> ~/.claude/…
      codex/                      Codex auth home (auth.json, file store), never used for turns
      siwc.json                   SIWC tokens for this host (0600; M10)
      session/                    a running login's scratch dir (browser hook output), removed afterwards
    ledger.ndjson                 token ledger: {at, accountId, input, output, total}, bounded to 8 days / 4 MiB
    audit.ndjson                  sign-in, sign-out and reset events (no secrets), 4 MiB × 2 like vault audit
```

- Claude Code's credential lives in the macOS Keychain item
  `Claude Code-credentials-<sha256(dir)[:8]>`, or in
  `claude/.credentials.json` on Linux.
- `internal/store/home/paths.go` gains `ProviderAccountsDir()`,
  `ProviderAccountDir(id)` and `CodexHome()`. Every path passed to a CLI comes
  from these functions, because the Keychain item name depends on the exact
  string.

### 2.3 Proto changes

Run `just generate` afterwards, and update `api/swift-module-mappings.asciipb`
for the new file.

**New `api/proto/dieter/v1/provider_accounts.proto`.** Its RPC names are
unique across the package, as `TestGRPCAPIImplementsEveryDeclaredRPC`
requires.

```proto
service ProviderAccountService {
  rpc ListProviderAccounts(ListProviderAccountsRequest) returns (ListProviderAccountsResponse);
  rpc CreateProviderAccount(CreateProviderAccountRequest) returns (CreateProviderAccountResponse);
  rpc UpdateProviderAccount(UpdateProviderAccountRequest) returns (UpdateProviderAccountResponse);   // label, include_in_summary
  rpc DeleteProviderAccount(DeleteProviderAccountRequest) returns (DeleteProviderAccountResponse);
  rpc SetDefaultProviderAccount(SetDefaultProviderAccountRequest) returns (SetDefaultProviderAccountResponse);
  rpc StartProviderLogin(StartProviderLoginRequest) returns (StartProviderLoginResponse);           // on the target machine
  rpc WatchProviderLogin(WatchProviderLoginRequest) returns (stream ProviderLoginEvent);
  rpc SubmitProviderLoginInput(SubmitProviderLoginInputRequest) returns (SubmitProviderLoginInputResponse); // code | callback_url
  rpc CancelProviderLogin(CancelProviderLoginRequest) returns (CancelProviderLoginResponse);
  rpc SignOutProviderAccount(SignOutProviderAccountRequest) returns (SignOutProviderAccountResponse); // this machine
  rpc CheckProviderLogin(CheckProviderLoginRequest) returns (CheckProviderLoginResponse);           // this machine
  rpc RefreshProviderUsage(RefreshProviderUsageRequest) returns (RefreshProviderUsageResponse);
  rpc ConsumeProviderUsageReset(ConsumeProviderUsageResetRequest) returns (ConsumeProviderUsageResetResponse);
}

enum ProviderKind { PROVIDER_KIND_UNSPECIFIED = 0; PROVIDER_KIND_CLAUDE = 1; PROVIDER_KIND_CHATGPT = 2; }
enum ProviderLoginMethod { …_UNSPECIFIED = 0; CLAUDE_CODE = 1; CODEX = 2; SIWC = 3; HOST = 4; ENVIRONMENT = 5; }
enum ProviderLoginState { …_UNSPECIFIED = 0; SIGNED_IN = 1; SIGNED_OUT = 2; EXPIRED = 3; FAILED = 4; }

message ProviderAccount {            // decoded KV record + per-machine logins, for the CLI and tests
  string id = 1; ProviderKind provider = 2; string label = 3; ProviderLoginMethod method = 4;
  ProviderIdentity identity = 5; bool include_in_summary = 6; bool is_default = 7;
  repeated ProviderMachineLogin logins = 8; ProviderUsage usage = 9; ProviderTokenUsage dieter_tokens = 10;
}
message ProviderMachineLogin { string daemon_id = 1; ProviderLoginState state = 2; string verified_at = 3;
  string error_code = 4; string error_message = 5; ProviderUsage usage = 6; ProviderTokenUsage dieter_tokens = 7; }
message ProviderUsage { string plan = 1; string observed_at = 2; repeated ProviderUsageWindow windows = 3;
  ProviderCredits credits = 4; ProviderSpend spend = 5; int32 reset_credits_available = 6; string unavailable = 7; }
message ProviderUsageWindow { string kind = 1; string label = 2; double used_percent = 3; string resets_at = 4; int32 duration_minutes = 5; }

message StartProviderLoginRequest { string account_id = 1; ProviderLoginMethod method = 2;
  enum Flow { FLOW_UNSPECIFIED = 0; FLOW_PASTE_CODE = 1; FLOW_DEVICE_CODE = 2; FLOW_BROWSER = 3; } Flow flow = 3; }
message StartProviderLoginResponse { string login_id = 1; ProviderLoginChallenge challenge = 2; }
message ProviderLoginChallenge {
  string open_url = 1;          // the URL to open on the user's device
  string local_url = 2;         // localhost-redirect variant, for a client on the daemon's host
  int32 callback_port = 3;      // loopback port for forwarding (Claude random, Codex 1455)
  string user_code = 4;         // device code
  string expires_at = 5;
  enum Input { INPUT_UNSPECIFIED = 0; INPUT_CODE = 1; INPUT_NONE = 2; INPUT_CALLBACK = 3; } Input expects = 6;
}
message ProviderLoginEvent { oneof event { ProviderLoginChallenge challenge = 1; ProviderLoginWaiting waiting = 2;
  ProviderLoginSucceeded succeeded = 3; ProviderLoginFailed failed = 4; } }
message SubmitProviderLoginInputRequest { string login_id = 1; oneof input { string code = 2; string callback_url = 3; } }
message ConsumeProviderUsageResetRequest { string account_id = 1; string idempotency_key = 2; string credit_id = 3; }
message ConsumeProviderUsageResetResponse { string outcome = 1; ProviderUsage usage = 2; } // reset | nothingToReset | noCredit | alreadyRedeemed
```

**Changes to existing protos.** Field numbers were checked against the
current files.

| File                              | Change                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `dieter/v1/common.proto`          | `HarnessSelection.account_id = 5`. `Card`: `reserved 37; reserved "provider_account_key";`, add `provider_account_id = 49` (owner-local, like `provider_options`).                                                                                                                                                                                                                                                                    |
| `dieter/v1/cards.proto`           | `CreateConversationRequest.account_id = 27`; `DraftAgentSettings.account_id = 5`.                                                                                                                                                                                                                                                                                                                                                     |
| `dieter/v1/conversations.proto`   | `SendMessageRequest.account_id = 10`.                                                                                                                                                                                                                                                                                                                                                                                                 |
| `dieter/v1/schedules.proto`       | `Schedule.account_id = 44`; `ScheduleDraft.account_id = 43`.                                                                                                                                                                                                                                                                                                                                                                          |
| `dieter/gateway/v1/gateway.proto` | Delete the 5 quota RPCs and every `Provider*` message and enum (L292-527). `DaemonLinkFrameKind`: `reserved 16 to 20`. `DaemonLinkFrame`: `reserved 20 to 25` plus their names. Keep `capabilities = 19` (still carries `control_webrtc_v1`). Rewrite the comments at L12-17 and L76-78.                                                                                                                                              |
| `dieter/core/v1/state.proto`      | `CreationPreferences.account_by_provider = 6` (`map<string,string>`).                                                                                                                                                                                                                                                                                                                                                                 |
| `dieter/client/v1/client.proto`   | Delete the Quotas domain (`Command.quotas = 66`, `SLICE_QUOTAS = 19`, `Update.quotas = 30`, L3345-3481); add `reserved`. Add the Providers domain (§7.2): `Command.providers = 86`, `SLICE_PROVIDERS = 29`, `Update.providers = 40`, `Result.provider_sign_in = 49`. Agent picker: `AgentChoice.account = 5`; `AgentControlsState.accounts = 20`, `account_enabled = 21`; `ConversationState.provider_notice` (the next free number). |

**Floors.** `buf breaking` flags the gateway and `dieter.v1` changes. The
same change raises `deploy/gateway/compatibility-policy.json` to the release
that ships this (planned `0.7.0-dev.0`); CI enforces it
(`.github/workflows/ci.yml:132-142`).

### 2.4 Go model

- `model.HarnessSelection.AccountID` (`json:"accountId,omitempty"`).
- `model.Card.ProviderAccountID`, which replaces `ProviderAccountKey`
  (`model.go:225`). It is owner-local, with yaml tag `provider_account_id_cache`.
- `model.Schedule.AccountID`.
- `store/kanban/cards.go` `CardCacheInput.ProviderAccountID` replaces
  `ProviderAccountKey` (L428-492).
- `store/conversations` `cloneSelection` copies `AccountID`
  (`cache.go:56-81`).
- `store/schedules` `Input.AccountID` (create L355, update L609).
- The account ID is **not** added to the replicated `item/summary` fields
  (`replication/schema/domain.go:93-96`). It travels with the owned card, as
  `provider_options` does (`api/changes_local.go:330-339`).

## 3. Milestones and order

One branch. Each milestone is a compile-checked commit (`go build ./...`,
`go vet` on touched packages, Kotlin and Swift compile where touched). The
slow suites run once, in M11. Estimates are agent-days.

| #   | Milestone                                                                                      | Days | Depends on |
| --- | ---------------------------------------------------------------------------------------------- | ---- | ---------- |
| M1  | Protos, KV schema, store paths, peer-write guard                                               | 1.5  | –          |
| M2  | `internal/engine/accounts`: registry, homes, logins (Claude, Codex), adoption, status, cleanup | 4    | M1         |
| M3  | Turn wiring: selection, admission, runner `auth`/env, Codex home, quick titles, discovery      | 2.5  | M2         |
| M4  | Usage: probes, turn-observed limits, token ledger, reset credits                               | 2    | M2, M3     |
| M5  | Delete the gateway, link and daemon quota pipeline; floors                                     | 1.5  | M4         |
| M6  | API service, CLI `dieter provider`, dieterclient, CLI reference                                | 2.5  | M2–M4      |
| M7  | Kotlin core `providers` domain, client contract, agent picker                                  | 3    | M6         |
| M8  | macOS app: Settings › Providers, sign-in sheet, composer, sidebar, banners                     | 3    | M7         |
| M9  | Compose (iOS, Android, desktop shell): Providers in Settings and More, sheets, composer, inbox | 3    | M7         |
| M10 | Sign in with ChatGPT as a second ChatGPT method                                                | 3    | M3, M8, M9 |
| M11 | Fixtures, Maestro flows, docs, ADR, full verification, release prep                            | 3    | all        |

The total is about 29 agent-days. M8 and M9 can run in parallel once M7's
contract is in. M10 can follow in a later release without touching the rest.

## 4. Daemon (M1–M4)

### 4.1 Store and schema (M1)

- `internal/replication/schema/provider_accounts.go`:
  - namespace constants;
  - `ProviderNamespaceKind`;
  - `decodeProviderAccount`, `decodeProviderDefault`, `decodeProviderLogin`;
  - key helpers `ProviderLoginKey(account, daemon)` and
    `ParseProviderLoginKey`;
  - registration in `ValidateKV` (`schema/kv.go:58-63`).
- `internal/store/kv/provider_accounts.go`:
  - `PutProviderAccount` (CAS on revision, `OperationID home.NewID("op_")`,
    4 retries like `PutChannel`);
  - `DeleteProviderAccount` (tombstone);
  - `PutProviderLogin` (no-op if unchanged);
  - `DeleteProviderLogin`, `EachProviderAccount`, `EachProviderLogin`.
- `internal/api/kv.go`: refuse public mutations of `provider-*` next to the
  channel refusal (L105-109).
- `internal/store/kanban/shared.go` `ValidatePeerWrite`: refuse `kv.provider-*`
  and `kv.channel*` through the generic peer-write path.
- `internal/store/home/paths.go`: the path helpers (§2.2).
- `internal/store/home/permissions.go`: add `provider-accounts/*/siwc.json`
  and the ledger to the hardened list.
- Tests:
  - validators (good, bad and oversized values for each namespace);
  - KV writer conflicts and tombstones;
  - the peer-write refusal.

### 4.2 Engine package `internal/engine/accounts` (M2)

The constructor is `accounts.New(Options{Store, Executables, Clock, Logger,
DaemonID, Backend})`. The engine holds it and the API receives it through
`api.Options`.

| File              | Responsibility                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `registry.go`     | Read and write the three namespaces. `Accounts()` returns account records joined with logins and defaults. Create, update, delete and set-default, with identity binding by CAS (first verified identity wins). Default resolution (§4.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `backend.go`      | The `Backend` interface: `ClaudeLogin`, `CodexLogin`, `SIWCLogin`, `CheckClaude`, `CheckCodex`, `SignOut*`, `ProbeClaudeUsage`, `ProbeCodexUsage`, `ConsumeCodexReset`, `CodexToken`. `execBackend` is the real one. Tests and the fixture gateway use a fixture backend (§11.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `executables.go`  | Resolve `claude` and `codex` inside the harness runtime (the platform-package layout of `runtime-packages.mjs:89-108`: `@anthropic-ai/claude-agent-sdk-<plat>/claude`; `@openai/codex-<plat>/vendor/<triple>/bin/codex`). Taken from `SubprocessRunner.RuntimeDirectory`; tests override it through `Environment.RuntimeDir`.                                                                                                                                                                                                                                                                                                                                                                                                       |
| `homes.go`        | The shadow Claude directory. Create the dir (0700). Link `projects`, `settings.json`, `CLAUDE.md`, `skills`, `agents`, `commands` and `plugins` to `~/.claude/*` when they exist. Mirror `mcpServers` from `~/.claude.json` into the account's `.claude.json` (read-modify-write that key only, atomically) before each turn. Removal unlinks symlinks and never recurses through them. Also renders `DIETER_HOME/codex/config.toml` (§4.5).                                                                                                                                                                                                                                                                                        |
| `login.go`        | `LoginManager`. At most 4 sessions per daemon, 1 per account, and 1 Codex browser session per host (port 1455). Lifetime 30 minutes. Sessions end on cancel, on daemon shutdown (`Serve` shutdown hook), or when the last watcher has been gone for 5 minutes. Events fan out to watchers through a bounded broadcast (16 events).                                                                                                                                                                                                                                                                                                                                                                                                  |
| `login_claude.go` | Spawns `claude auth login --claudeai [--email <identity.email>]` with a minimal env: `HOME`, `USER`, `PATH`, `LANG`, `CLAUDE_CONFIG_DIR`, and `BROWSER=<session>/browser-hook.sh` (the hook writes `$1` to `<session>/browser-url`). It parses `visit: (https://…)` from stdout into `open_url`, takes `local_url` and `callback_port` from the hook output, and sets `expects = INPUT_CODE`. Input: a code is written verbatim with a newline (format `code#state`); a callback URL must be `http://localhost:<callback_port>/callback?…` and is replayed with `GET`, following loopback redirects only. On exit 0 it runs `claude auth status --json`, then binds the identity (`email`, `orgId`, `orgName`, `subscriptionType`). |
| `login_codex.go`  | `codex -c cli_auth_credentials_store="file" app-server` with `CODEX_HOME=<account>/codex`, through `internal/harness/codexrpc` (new: JSON-lines client with 1 MiB line cap, initialize/initialized, request/response, notifications). Device code is the default: `account/login/start {type:"chatgptDeviceCode"}` gives `open_url=verificationUrl`, `user_code` and `expires_at = now+15m`; on "timed out" it starts a new code and emits a fresh challenge, at most 3 times. Browser: `{type:"chatgpt"}` gives `open_url=authUrl` and `callback_port=1455`; the callback replay follows the redirect to `/success` (P0.4). On `account/login/completed` it calls `account/read` for `email`, `planType` and `chatgptAccountId`.   |
| `login_siwc.go`   | M10 (§10).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `broker.go`       | `CodexToken(ctx, accountID) (token, baseURL)` under a per-account mutex plus an `fsx` lock file in the account dir. If the `auth.json` access token expires within 24 h or `last_refresh` is more than 7 days old, it runs `account/read {refreshToken:true}` on the account's auth home and reads the file again. SIWC has its own branch (M10). `host` accounts read `~/.codex/auth.json` and refresh it the same way. `environment` accounts return the daemon env key.                                                                                                                                                                                                                                                          |
| `status.go`       | Checks every login at most every 15 minutes, and right after an auth failure in a turn: `claude auth status --json` (local) or Codex `account/read` (local). It writes `state` and `verifiedAt`. Runner auth-failure frames (§4.6) set `expired` at once.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `adoption.go`     | At start and every 30 minutes, adopts what the host already has. Default `~/.claude` signed in → a `host` account matched by identity (created if missing, labelled with the email); default `~/.codex` signed in → same. `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`CODEX_API_KEY` in the daemon env → an `environment` account per provider on this machine. Nothing is copied or moved.                                                                                                                                                                                                                                                                                                                                               |
| `cleanup.go`      | Acts on tombstoned accounts and on accounts this machine no longer has. It signs out (`claude auth logout` on the account dir; Codex `account/logout`; SIWC revoke; never for `host` or `environment`), removes the dir, tombstones its own login record, and writes an audit entry.                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `audit.go`        | Bounded `audit.ndjson` with no secrets: account, machine, action, outcome, time.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

**Identity binding.** Each provider has a stable identity:

- Claude: `orgId + lower(email)`.
- ChatGPT (Codex): `chatgptAccountId`.
- SIWC: `sub + workspace`.

A sign-in whose identity differs from the bound identity is signed out at
once and fails with `identity_mismatch` ("signed in as bob@…, this account is
alice@…").

**Agents are refused.** Every mutating entry point refuses a turn-token
caller in the API layer (§6.1).

### 4.3 Claude turns (M3)

- `resolveTurnSelection` (`engine/turn_selection.go:25-82`) gains account
  resolution:
  - The harness `claude-code` accepts Claude accounts; `codex` accepts
    ChatGPT accounts.
  - Other harnesses must have an empty `account_id`; otherwise
    `fault.Invalid`.
  - A change between turns needs the catalog capability `account-selection`
    at level `between-turns`. Add it to `claude-code` and `codex` in
    `harness/catalog/harnesses.yaml`.
- Admission (`turn_admission.go:89-221`) calls
  `accounts.ResolveTurn(provider, accountID)`. It returns
  `TurnAuth{Env map[string]string, Auth map[string]string}`, or a
  `fault.FailedPrecondition` whose message names the account and machine
  ("Work isn't signed in on box"). The UI does not depend on this error: it
  checks readiness from KV before sending (§7.4).
- **For a Claude account:**
  - `Env`: `CLAUDE_CONFIG_DIR=<canonical dir>`, plus `ANTHROPIC_API_KEY=""`,
    `ANTHROPIC_AUTH_TOKEN=""`, `CLAUDE_CODE_OAUTH_TOKEN=""`. Env can only be
    appended (`harness.go:368-370`), so empty values mask host keys. M3
    verifies that Claude Code treats `""` as unset.
  - `Auth`: `{}`.
  - `host`: as above but without `CLAUDE_CONFIG_DIR`.
  - `environment`: `Auth` holds the env keys, and no blanking.
- `homes.Prepare(accountID)` runs before every Claude turn (`mcpServers`
  mirror and symlink check).
- `harness.Request` gains an `Auth map[string]string` field (JSON `auth`,
  omitted when empty). `TurnAuth.Env` merges into `Request.Environment` (`turn_tokens.go:68-74`
  `agentEnvironment`).
- Recovery (`turn_recovery.go:254-384`) resolves `TurnAuth` again from
  `ActiveTurn.Selection.AccountID`, because tokens may have rotated.
- `UpdateCardCache` writes `ProviderAccountID` (`turn_admission.go:186-191`).

### 4.4 Default resolution

An empty `account_id` resolves in this order:

1. the card's `ProviderAccountID` (the last turn);
2. `provider-account-defaults[provider]`;
3. the single account of that provider signed in on this machine.

The resolved ID is stored on the turn and the card, so a chat stays on its
account until the user changes it.

### 4.5 Codex turns, Codex home, quick titles (M3)

- **The shared home.** Every Dieter Codex process uses
  `CODEX_HOME=DIETER_HOME/codex` (`Env`). That covers turns, quick titles,
  usage probes that need no auth home, and model discovery.
- **The rendered config.** `homes.RenderCodexConfig()` writes
  `config.toml` = the user's `~/.codex/config.toml` with any top-level
  `model_provider` and any `[model_providers.agent_bridge_openai]` removed,
  plus:

  ```toml
  model_provider = "agent_bridge_openai"
  [model_providers.agent_bridge_openai]
  name = "Agent Bridge OpenAI"
  base_url = "https://chatgpt.com/backend-api/codex"
  env_key = "CODEX_API_KEY"
  wire_api = "responses"
  supports_websockets = false
  ```

  - Implementation: decode, edit and encode with `github.com/pelletier/go-toml/v2`
    (new dependency), or line-based removal before the first table plus
    validation with `codex app-server --print-startup-config`.
  - It is re-rendered when the source file's mtime or size changes, and
    always written atomically.
  - Without the global block, `turn/start` fails (proposal §4.1, P0.4).

- **Turn auth.** `Auth = {CODEX_API_KEY: broker token, OPENAI_BASE_URL:
base}`. Base: `https://chatgpt.com/backend-api/codex` for codex and host;
  `https://api.openai.com/v1` for environment and SIWC.
- **Quick titles** (`conversation_creation.go:177-232`):
  - The request gets the default ChatGPT account's `TurnAuth` on this
    machine.
  - With no ChatGPT login, it skips title generation and logs at info.
  - `scheduleQuickTaskTitle` logs failures at warn instead of dropping them
    silently (`quick_task_title.go:46-49`).
- **Model discovery** (`harness/discovery.go:451-487`) reads
  `DIETER_HOME/codex/models_cache.json`. Every hour, and when the cache is
  missing, `accounts` refreshes it through app-server `model/list` using the
  default account's token.
- **Existing Dieter Codex conversations** keep their resume handle. Resume
  fails with "no rollout found" and the runner starts a fresh thread. The
  operator accepted this clean break; the release notes say so.

### 4.6 Runner changes (`internal/harness/runtime`, M3–M4)

- `runner.mjs:333-344`: pass `auth: request.auth` to `createLocalClaudeCode`
  and `createLocalCodex` when `request.auth` is present. This replaces the
  adapter's credential discovery for Claude and Codex.
- **Auth failures.** The second-failure text in `claude-resilience.mjs`
  becomes "The Claude sign-in for this account was rejected on this machine.
  Sign in again in Settings › Providers." The runner also emits
  `{"type":"auth-failure"}`, and Go maps it to `accounts.MarkExpired`.
- **Usage frames.** The runner emits
  `{"type":"provider-usage","data":{…}}`:
  - Claude: from SDK `rate_limit_event` messages (`SDKRateLimitInfo`:
    `rateLimitType`, `utilization`, `resetsAt`, `status`).
  - Codex: from app-server `account/rateLimits/updated` (`RateLimitSnapshot`:
    `primary`/`secondary` `{usedPercent, resetsAt, windowDurationMins}`,
    `planType`, `credits`), if the bridge surfaces raw notifications. If it
    doesn't, Codex relies on probes; M4 verifies this.
- `harness.Output` gains these two frame types. `turn_execution.go` routes
  them to `accounts.ObserveUsage` and `accounts.MarkExpired` with the active
  turn's account.
- **New `usage-claude.mjs`** replaces `quota-claude.mjs`. It runs a
  prompt-less SDK query in `CLAUDE_CONFIG_DIR` (as in
  `tools/spikes/provider-accounts/live/usage.mjs`) and prints normalized
  JSON: `accountInfo()` plus
  `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({skipBehaviors:true})`.
- **Delete** `quota-claude.mjs`, `quota-openai.mjs` and their tests, and the
  `smol-toml` dependency and its lockfile entries.
- Tests in the style of `runner-auth-retry.test.mjs` (hooks swap
  `./claude-runtime.mjs` and `./codex-runtime.mjs` to capture settings):
  - `auth` is passed through;
  - the frames are emitted;
  - the new failure text.

### 4.7 Usage collector (M4), replacing `internal/providerquota`

`accounts/usage.go` collects usage for every signed-in login on this machine.

- **Probes.**
  - Claude: `usage-claude.mjs` every 5 minutes with jitter.
  - Codex: `account/rateLimits/read` on the account auth home every
    2 minutes, plus `account/usage/read` for the provider's token summary.
  - SIWC: no probe endpoint known; turn-observed limits only, plus the
    "Manage usage" link.
- **No duplicate probes across machines.** A probe is skipped when any
  machine's login record for the same account has `usage.observedAt` within
  the interval. All machines see each other's records through peer sync.
- **Turn-observed updates** from runner frames update usage at once, at most
  one KV write per account per 60 seconds.
- **Writes** happen only on a material change: a window moves by 1 point or
  more, a reset time changes, or availability changes. Otherwise at most every
  15 minutes, to keep `observedAt` fresh for "updated N min ago".
- **Token ledger.**
  - On each finished turn, `{at, accountId, input, output, total}` is
    appended from the turn's usage (the same data `conversations.TokenUsage`
    sums).
  - Rolling 5-hour and 7-day sums go into `dieterTokens`.
  - The ledger is pruned past 8 days or 4 MiB.
- **Reset credits.** `ConsumeProviderUsageReset` runs on a machine with a
  signed-in Codex login for that account. It calls app-server
  `account/rateLimitResetCredit/consume {idempotencyKey, creditId}` and
  returns the **outcome** to the caller, which today's gateway path never
  did. It then probes again.
- **Refresh.** `RefreshProviderUsage` probes immediately, still subject to a
  30-second per-account floor.

## 5. Delete the quota pipeline (M5)

| Area            | Delete or change                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Gateway         | Delete:<br>- `internal/gateway/quota_manager.go`, `quota_storage.go` and their tests (`quota_manager_test.go`, `quota_result_test.go`, `quota_storage_test.go`, `quota_late_e2e_test.go`);<br>- `TestGatewayRejectsUnauthenticatedProviderQuotaRPCsBeforeReadingBody`.<br>`hub.go`: remove the quota channel, capability map, HELLO_ACK correlation key, frame handlers 16/18/20, `SupportsProviderQuota*`, `SendProviderQuota*`, `sendQuotaFrame` and the `signalChanged` calls. `service.go`: remove the 5 handlers. `server.go`: remove the `Quota` wiring. |
| Gateway storage | `storage.go`: remove the six `provider_*` objects from the baseline script and add `DROP TABLE IF EXISTS` for `provider_quota_snapshots`, `provider_account_sources`, `provider_accounts`, `provider_account_preferences` and `provider_account_keys`. Keep `user_version = 1`; the script is idempotent. Remove the `RevokeDaemon` deletes at L493-503.                                                                                                                                                                                                       |
| Link            | Delete `internal/link/provider_quota.go`. `gateway_client.go`: remove the `ProviderQuotas` field, quota constants, `supportsGatewayCapability`, quota negotiation, `quotaSend`/`enqueueQuota`, the discovery loop, and the refresh and reset handlers. Keep `control_webrtc_v1` in `controlCapabilities`.                                                                                                                                                                                                                                                      |
| Relay           | Delete `internal/transport/relay/quota.go`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Daemon          | Delete the `internal/providerquota` package. `run.go`: remove the quota source, `gatewayLink{quotas}` and `options.ProviderAccountKey`. `services.go`: remove `ServiceOptions.ProviderAccountKey`. Engine: remove `app.go:26` `ProviderAccountKey` and the `turn_admission.go:95-99` lookup. `harness.go:331-336`: remove `RuntimeDirectory` if accounts doesn't adopt it (it does, §4.2).                                                                                                                                                                     |
| Config          | `platform/config/daemon.go`: remove `CodexHome`, `ClaudeConfigDir`, `CodexAccountHomes` and `ClaudeAccountHomes`, and their entries in `env_test.go`. Discovery still reads env through `harness.Environment`.                                                                                                                                                                                                                                                                                                                                                 |
| Lint            | `.golangci.yml`: remove the `providerquota` denials (L79-80, L198-199) and update the comment at L171-172.                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Floors          | `deploy/gateway/compatibility-policy.json`: `minimumClientVersion` and `minimumDaemonVersion` → `0.7.0-dev.0`.                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

## 6. API and CLI (M6)

### 6.1 `internal/api/provider_accounts.go`

- **Wiring.** `providerAccountsAPI` is mounted in `service.go`: handler type,
  embed, compile-time assert, `handlers()`. `api.Options.Accounts` is wired
  in `daemon/services.go:87-92`.
- **Agents are refused.** Every mutating RPC refuses a turn-token caller by
  presence, like `trustAPI.admit` (`trust.go:38-46`): "agents cannot manage
  provider accounts". Reads stay open, so agents can list accounts and pass
  `--account` when they create cards.
- **Routing.** Account-wide RPCs (Create, Update, Delete, SetDefault) run on
  any daemon. Machine RPCs (StartProviderLogin, SignOutProviderAccount,
  CheckProviderLogin, ConsumeProviderUsageReset) act on the daemon that
  serves the call. Clients and the CLI pick it with `--machine` or
  `MachineChoice`.
- **`WatchProviderLogin`** is bounded at 16 concurrent watches with a
  15-second heartbeat. It ends after `succeeded` or `failed`.
- **`SubmitProviderLoginInput`** never logs the input. Audit records only the
  kind ("code submitted", "callback forwarded").
- **Errors**: `fault.Invalid` (bad input), `fault.NotFound` (unknown
  account), `fault.Conflict` (session running, port 1455 busy),
  `fault.FailedPrecondition` (no login for a machine RPC, identity mismatch),
  `fault.PermissionDenied` (turn token).
- **Engine-side additions:**
  - `CreateConversationRequest.account_id`, `SendMessageRequest.account_id`,
    `DraftAgentSettings.account_id` and the schedule fields are mapped in
    `conversation_snapshots.go:36-55, 116-134`, `conversations.go:93,141`,
    `cards.go:212-242` and `convert.go` (`protoCard` `provider_account_id`,
    `protoSchedule`).
  - `changes_local.go:335` projects `provider_account_id` on owned cards.
- **Tests:**
  - per-RPC handler tests with a fake backend;
  - turn-token refusal;
  - `TestGRPCAPIImplementsEveryDeclaredRPC` and `rpc_parity_test` stay
    green.

### 6.2 CLI `dieter provider` (`internal/cli/rpc_provider.go`)

| Command                                                                                   | RPC(s)                                                                                |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `dieter provider list [--format table\|json\|jsonl\|ids]`                                 | ListProviderAccounts                                                                  |
| `dieter provider add claude\|chatgpt --label L [--method codex\|siwc]`                    | CreateProviderAccount                                                                 |
| `dieter provider rename ACCOUNT LABEL`                                                    | UpdateProviderAccount                                                                 |
| `dieter provider include\|exclude ACCOUNT`                                                | UpdateProviderAccount (`include_in_summary`)                                          |
| `dieter provider default ACCOUNT`                                                         | SetDefaultProviderAccount                                                             |
| `dieter provider remove ACCOUNT --confirm REMOVE`                                         | DeleteProviderAccount                                                                 |
| `dieter provider login ACCOUNT [--device-code\|--browser] [--code CODE] [--callback URL]` | StartProviderLogin, WatchProviderLogin, SubmitProviderLoginInput, CancelProviderLogin |
| `dieter provider logout ACCOUNT`                                                          | SignOutProviderAccount                                                                |
| `dieter provider check ACCOUNT`                                                           | CheckProviderLogin                                                                    |
| `dieter provider usage [ACCOUNT] [--refresh] [--format …]`                                | ListProviderAccounts, RefreshProviderUsage                                            |
| `dieter provider reset ACCOUNT --confirm RESET`                                           | ConsumeProviderUsageReset (fresh UUIDv4 key, printed)                                 |

- `ACCOUNT` is an ID or a unique label. Global `--machine` picks the target
  daemon for login, logout, check and reset.
- **Interactive `login`.**
  - It prints the URL (and the device code), then waits.
  - With a Claude paste-code challenge on a TTY, it reads the code with echo
    off, like `vaultPrompt` (`rpc_vault.go:119-128`).
  - It also accepts the failed callback address.
  - Ctrl-C calls `CancelProviderLogin`.
  - `--code` or `--callback` make it non-interactive.
- `--account ID|LABEL` is added to `card create|send`, `chat …` and
  `schedule edit` (`rpc_cards.go:178,712,955`, `rpc_schedules.go:228`).
- **Delete** `internal/cli/quota.go` and `quota_test.go`, and the `quota`
  command entry (`commands.go:56-62`).
- **Same-change updates:**
  - `internal/transport/dieterclient/client.go`: add the service to the
    interface, to `New` and to the Connect variant.
  - `help_contract_test.go`: `rpcCommand` maps all 13 RPCs.
  - Regenerate the CLI reference with
    `go run ./tools/clidocs -o site/content/docs/reference/cli.md`.
  - `.agents/skills/dieter-cli/SKILL.md`: replace the quota section with
    `dieter provider`.
- **Tests:**
  - CLI unit tests with a fake client;
  - `provider_cli_e2e_test.go` (`daemonCLIWithRunner`);
  - a topology e2e (`internal/testkit/topology/provider_accounts_e2e_test.go`,
    `-tags e2e`): create an account on daemon A; sign in on B through the
    fixture backend over local, direct TLS and relay; peer sync shows B's
    login on A; a turn on B uses the account (FakeRunner asserts `Auth` and
    `Environment`); delete it and B cleans up.

## 7. Kotlin core (M7)

### 7.1 Package `com.getdieter.core.providers` (`apps/kotlin/core/runtime/src/commonMain`)

| File                    | Responsibility                                                                                                                                                                                                                                                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ProviderRecords.kt`    | Decode `provider-accounts`, `provider-account-defaults` and `provider-logins` from `AccountSnapshot.kv`. Tolerant: unknown fields are ignored, bad records are skipped and counted.                                                                                                                                                              |
| `ProviderAccounts.kt`   | A state holder like `ProviderQuotas`, with `MutableStateFlow<ProvidersView>`. It combines the KV records, machines (presence and reachability from `MachineChoice`, roster membership; login records of removed devices are dropped) and active sign-in sessions. Started in `CoreRuntime` next to `navigationKv` (`CoreRuntime.kt:326`).        |
| `ProviderUsage.kt`      | Pick the freshest usage per account, sum `dieterTokens`, compute severity and summary ("62% left", resets in …, stale after 30 min). This logic moves from `Quotas`/`QuotaRows`, which are deleted.                                                                                                                                              |
| `ProviderSignIn.kt`     | The sign-in session state machine: Start, then a Watch stream, then Submit or Cancel against the target daemon (`sessions.call(daemonId){ DaemonApi.providerAccounts }`). "All machines" walks every online machine without a signed-in login, one after another. Device-code challenge refreshes reach the UI. Cancelled when the sheet closes. |
| `ProviderCommands.kt`   | Executes `ProvidersCommand`. Account-wide edits go to any reachable machine (`MachineChoice.any()`) and retry while offline. Machine actions go to the named daemon. Reset uses a stable idempotency key per account until it gets an answer, as `ProviderQuotas.consumeReset` does today.                                                       |
| `ProviderReadiness.kt`  | Readiness of an account on a machine: `READY`, `SIGNED_OUT`, `EXPIRED`, `MACHINE_OFFLINE`, `NO_ACCOUNT`, each with a reason text. Used by the composer and creation.                                                                                                                                                                             |
| `ProvidersPresenter.kt` | `ProvidersView` → `ProvidersSlice` (rows, summary, sessions).                                                                                                                                                                                                                                                                                    |

### 7.2 Client contract (`client.proto`)

```proto
message ProvidersCommand { oneof action {
  ProviderCreate create = 1; ProviderRename rename = 2; ProviderRef remove = 3; ProviderRef set_default = 4;
  ProviderInclusion set_included = 5; ProviderSignInStart sign_in = 6; ProviderRef sign_in_all = 7;
  ProviderSignInInput submit = 8; ProviderSessionRef cancel = 9; ProviderMachineRef sign_out = 10;
  ProviderMachineRef check = 11; ProviderRef refresh_usage = 12; ProviderRef consume_reset = 13; } }
message ProvidersSlice {
  repeated ProviderGroupRow groups = 1;          // Claude, ChatGPT
  ProviderSummary summary = 2;                   // header: tightest included window per provider
  repeated ProviderSignInSession sessions = 3;   // live sheets
  bool loading = 4; string error = 5;
}
message ProviderGroupRow { string provider = 1; string title = 2; repeated ProviderAccountRow accounts = 3; string default_account_id = 4; }
message ProviderAccountRow {
  string id = 1; string label = 2; string identity = 3; string plan = 4; string method = 5;
  bool is_default = 6; bool included = 7; ProviderSeverity severity = 8; string summary = 9;   // "62% left · resets 18:00"
  repeated ProviderWindowRow windows = 10; string usage_updated = 11; string dieter_tokens = 12;
  repeated ProviderMachineRow machines = 13; bool can_reset = 14; string reset_label = 15; string manage_usage_url = 16;
}
message ProviderMachineRow { string daemon_id = 1; string name = 2; bool online = 3; string state = 4; string detail = 5; bool can_sign_in = 6; bool can_sign_out = 7; }
message ProviderSignInSession { string id = 1; string account_id = 2; string daemon_id = 3; string machine = 4;
  string phase = 5; string open_url = 6; string local_url = 7; string user_code = 8; string expires_in = 9;
  string expects = 10; string error = 11; int32 remaining = 12; }  // remaining machines in "all machines"
enum ProviderSeverity { PROVIDER_SEVERITY_UNSPECIFIED = 0; PROVIDER_SEVERITY_OK = 1; PROVIDER_SEVERITY_LOW = 2; PROVIDER_SEVERITY_EXHAUSTED = 3; }
message AgentAccountOption { string id = 1; string label = 2; string detail = 3; string readiness = 4; string reason = 5; }
```

- **The agent picker.** `AgentChoice.account` is a new arm (5).
  `AgentControlsState.accounts` and `account_enabled` are added.
  `AgentControls` (`selection/AgentControls.kt`) lists the accounts for the
  chosen harness's provider, marks readiness on the target machine, and
  disables sending when the chosen account isn't ready. `choosing()`
  (`CreationCommands.kt:341-370`) and `CreationExports.agentControls` handle
  the new arm.
- **Creation and sending.**
  - `Creation.request()` (`composition/Creation.kt:358-397`) maps
    `account_id`.
  - `CreationMemory` remembers `account_by_provider`.
  - `Selections.forSend` and `pending` carry the account.
  - `ConversationSession.chooseAgent` stores it in drafts.
- **`ConversationState.provider_notice`** carries `{account, machine, reason,
action: sign_in|sign_in_again|choose_account}`. It is set when the chosen
  account isn't ready on the owner machine, or after a turn's auth failure
  turns the login `expired`.
- **Header summaries.** The Inbox strip and the Mac sidebar now read
  `ProvidersSlice.summary`.
- **Delete:**
  - the `quotas/` package (`ProviderQuotas.kt`, `QuotaRows.kt`,
    `UsageWidget.kt`) and `client/rules/QuotaExports.kt`;
  - the `CoreRuntime` quota wiring (L61, 211, 248, 422) and
    `MachineCommands.kt:40`;
  - `SliceMappers.quotasSlice`;
  - the quota tests (`QuotaRowsTest`, `UsageWidgetTest`, `QuotaExportsTest`,
    `QuotasEndToEndTest`, the `DomainRulesTest` quota case and the
    `ClientApiAdminEndToEndTest` lines).
- `sync/AccountView.kt:776`: map `provider_account_id`.
- **SharedRules for Swift.** `ProviderExports` provides `providerRows`
  (encoded `ProvidersSlice` group → rows), `usageText`, `severity`,
  `readinessReason` and `deviceCodeDisplay`. The `quota*` exports are deleted
  (`SharedRules.kt:173-189`).
- **Tests:**
  - commonTest: record decoding, usage merge across machines, readiness,
    presenter;
  - jvmTest: `ProviderSignIn` against a fake `DaemonApi` (challenge, device
    refresh, submit, cancel, all machines);
  - e2e: `ClientApiProvidersEndToEndTest` on the fixture gateway (§11.2).

## 8. macOS app (M8)

| Area                     | Work                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Settings section         | `DieterSettingsSection`: replace `.usage` with `.providers` (symbol `key.horizontal`, subtitle "Claude and ChatGPT accounts"), id `settings.providers`. Page switch case `.providers: ProvidersSettings()`. `AppNavigationTests` expects "Providers".                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Model                    | `Features/Providers/Model/ProvidersModel.swift`: ref-counted `observe()`/`release()` of `.providers` through `SliceSubscription`, `run {}` command helper, `working`/`failure`, like `DevicesModel`. `AppSession.providersModel` replaces `lazy var quotas`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Page                     | `Features/Providers/Views/ProvidersSettings.swift`. One `SettingsPanel` per provider: "Add account", default picker. Per account (`ProviderAccountPanel.swift`): label, identity, plan, method; usage meters for 5 hours and weekly (`ProviderUsageMeters.swift`, moved from `ProviderQuotaMeter`); "updated N min ago"; Dieter tokens (5 h / 7 d); include-in-summary toggle; reset credit (OpenAI) with its confirmation; machine matrix with per-row Sign in, Sign out, Check; "Sign in on all machines"; rename sheet (template `RenameMachineSheet`); remove confirmation. Ids: `providers.add`, `providers.account.<id>`, `providers.account.<id>.signin.<daemon>`, `providers.account.<id>.signin-all`, `providers.account.<id>.reset`. |
| Add-account sheet        | `AddProviderAccountSheet.swift`: provider (Claude, ChatGPT), label, ChatGPT method (Codex sign-in; SIWC from M10 with "Continue with ChatGPT" branding), then straight into the sign-in sheet for the machine the user picks (default: this Mac's daemon when there is one).                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Sign-in sheet            | `ProviderSignInSheet.swift`, steps from `ProviderSignInSession`. Title "Sign in to Claude Code on ‹machine›" or "Sign in to Codex on ‹machine›". Step 1: Open (`NSWorkspace.shared.open`); same host uses `local_url`, which finishes by itself. Step 2: paste-code field (monospaced), the device code with a Copy button (`NSPasteboard`) and an expiry countdown, or "Paste the address your browser couldn't open". Progress, success and failure; "Next machine" during "all machines". Ids `providers.signin.open`, `.code`, `.submit`, `.copy-code`, `.callback`.                                                                                                                                                                       |
| Automatic callback (M11) | `ProviderCallbackListener.swift`: an `NWListener` on `127.0.0.1:<callback_port>` while the sheet shows a remote-machine Claude or Codex browser flow. It forwards the request line as `submit(callback_url)` and answers "Signed in, you can close this tab". The app isn't sandboxed, so no entitlement is needed.                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Composer and creation    | An Account menu (`ComposerSelectionMenu`, id `<prefix>.account`) in `AgentComposerMenus` (`ComposerControls.swift:266-317`) and `AgentControlFields` (`HarnessFields.swift:43`). Options show "Work · Max" with readiness; a disabled option says why (pattern in `NewProjectSheet.swift:66-79`). The conversation header shows an account chip.                                                                                                                                                                                                                                                                                                                                                                                               |
| Banner                   | `ProviderNoticeBanner.swift` beside `TurnFailureBanner` in `ConversationTimeline.swift:178-200`: "Work isn't signed in on box", with Sign in (opens the sheet for that machine) and Choose account.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Sidebar                  | `ProviderSidebarBlock` replaces `ProviderQuotaSidebarBlock` in `SidebarStatusPanel.swift`. The `.task` load in `AppSidebar.swift:55-58` is removed; the slice is live.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Delete                   | `Features/ProviderQuotas/**`, `ProviderQuotaPreviewRenderTests.swift`, `SettingsPages.swift` `UsageSettings`, the quota entries in `api-boundary-allowlist.txt` (L99-100). Keep `DieterTheme.openAIQuota`, renamed `openAITint`, because channels use it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Tests                    | `ProvidersModelTests` (`ScriptedCoreClient`: slices, commands, sheet steps), a render test for the page, and a Maestro flow (§11.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

## 9. Compose: iOS, Android, desktop shell (M9)

| Area                     | Work                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Navigation               | `ToolPage.PROVIDERS` replaces `USAGE` (`navigation/Navigation.kt:85`), title "Providers", new `Glyph.KEY`. `MobileRoute.ProviderAccount(accountId)` for the detail screen. `ToolScope.kt`: route both. `RouteContent` passes `openUrl` into `ToolScreen` (`MobileApp.kt:349`), closing the gap noted in the integration map.                                                                                                                                                                            |
| Settings                 | `settings/SettingsScreen.kt`: a new `item("providers")` section after "connection", with each account's label, the tightest window and the readiness dot. A tap opens `ProviderAccount`; "Manage providers" opens the page. This puts providers in Settings on mobile, as asked.                                                                                                                                                                                                                        |
| More                     | `More.kt` entry "Providers" with value "62% left" replaces Usage. Android `MoreSheet` hides it the same way it hid USAGE today (L261).                                                                                                                                                                                                                                                                                                                                                                  |
| Screens                  | `providers/ProvidersScreen.kt` (groups, accounts, add); `providers/ProviderAccountScreen.kt` (meters, Dieter tokens, machines with actions, include toggle, reset with `ConfirmDialog`, rename with `PromptDialog`, remove); `providers/UsageMeters.kt` (from `UsageScreen.kt`). Model `store/ProvidersModel.kt` (`observe(SLICE_PROVIDERS)` ref-counted, `action{}` commands).                                                                                                                         |
| Sheets                   | `providers/AddAccountSheet.kt` (`Sheet` with `MobileTextField` label and a provider picker) and `providers/SignInSheet.kt` (the same steps as on Mac; Open uses the host `openUrl`; the code field follows `DevicesScreen.kt:106-146`; `LocalClipboardManager` copy for device codes; countdown; "Paste the address"). Tags: `providers-add`, `provider-<id>`, `provider-signin-<daemon>`, `provider-signin-all`, `signin-open`, `signin-code`, `signin-submit`, `signin-copy-code`, `signin-callback`. |
| Automatic callback (M11) | Android: a loopback `ServerSocket` in the app process while the Custom Tab or browser is open. iOS: an `NWListener` while the app stays active, which only works with an in-app browser sheet (ASWebAuthenticationSession or SFSafariViewController). M11 tests both first; if iOS can't hold the listener, iOS keeps "paste the address".                                                                                                                                                              |
| Composer                 | An Account `PickerRow` in `creation/AgentSettings.kt` (creation, schedules, conversation agent sheet). The option subtitle shows readiness; `PickerRow` cannot disable single options, so the core blocks sending instead. The composer chip becomes "provider · account · model" (`Composer.kt:85-94`). Banner `provider_notice` in `ConversationScreen.kt` next to the turn-failure banner (L336-347).                                                                                                |
| Inbox and desktop        | `InboxScreen.UsageStrip` reads the providers summary. `DesktopSidebar.StatusPanel` (L580-670) reads providers (tags `sidebar-provider-<id>`). `DesktopNavigation`: USAGE → PROVIDERS. `DesktopPalette`: "Open providers".                                                                                                                                                                                                                                                                               |
| Delete                   | `tools/UsageScreen.kt`, `MachinesModel` quota code (L6-34), the `MobileStore` quota hooks (L371-373, L429), `Glyph.USAGE`.                                                                                                                                                                                                                                                                                                                                                                              |
| Tests                    | `ProvidersModelTest` (`FakeMobileCore`), a desktop UI test (fixture publishes `SLICE_PROVIDERS`), and Maestro flows (§11.3).                                                                                                                                                                                                                                                                                                                                                                            |

## 10. Sign in with ChatGPT (M10)

- **Account method `siwc`.** `login_siwc.go` is a Go OAuth client with a
  loopback listener on `127.0.0.1:<port>/auth/callback` (the client forwards
  it, §8, §9). It uses:
  - `client_id=dynamic_agent_client` with `agent_name_hint=Dieter` on first
    registration;
  - the issued `client_id` from the account record plus this host's saved
    `id_token_hint` afterwards (no prompt, P0.5);
  - `ext_agent_host_id = urn:ietf:params:oauth:jwk-thumbprint:sha-256:<thumbprint of the daemon's roster Ed25519 key>`;
  - scope `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`
    and `resource=https://api.openai.com/v1`.
- **Token exchange and checks.** It verifies `state`, nonce and `aud`, and
  requires `chatgpt.tokens.use.direct`. Without that scope the login is saved
  with `unavailable = "plan_usage_not_granted"`.
- **Storage and lifetime.**
  - `siwc.json` (0600) per host.
  - Refresh is serialized under the account lock.
  - Revocation on sign-out goes through
    `https://auth.openai.com/api/accounts/oauth/revoke`.
- **Turns.** `OPENAI_BASE_URL=https://api.openai.com/v1`. 1-hour tokens renew
  inside long turns through `[model_providers.agent_bridge_openai.auth]
command = "<dieter>", args = ["provider","token","--turn"],
refresh_interval_ms = 300000` (P0.6). That needs one more RPC,
  `GetProviderTurnToken`, which:
  - requires the turn token;
  - returns only the turn's own account;
  - refuses `--machine`;
  - maps to the CLI command `dieter provider token`.

  M10 also verifies that the global `base_url` in `DIETER_HOME/codex/config.toml`
  does not override the per-thread base URL. If it does, SIWC turns use a
  second provider ID.

- **UI duties** (OpenAI guidelines):
  - a "Continue with ChatGPT" button in the add-account sheet;
  - a first-use "You're using your ChatGPT plan" modal;
  - "Using ChatGPT plan · Manage usage" near the composer;
  - "no web search on this account", because web search fails on the plan
    route (P0.5).
- **Usage**: turn-observed only, plus the "Manage usage" link.

## 11. Fixtures and tests

### 11.1 Go

- **Unit tests:**
  - schema;
  - KV writers;
  - registry (CAS, identity binding, defaults);
  - homes (symlinks, `mcpServers` mirror, removal never follows links, Codex
    config render and re-render);
  - login drivers against fake executables (shell scripts on a fixture
    runtime dir; `claude` prints both URLs and accepts `FIXTURE-CODE#state`;
    `codex` speaks the app-server subset over JSON lines);
  - broker locking and refresh triggers;
  - usage (dedupe across machines, throttling, ledger sums);
  - status and adoption;
  - cleanup;
  - turn admission (`Auth` and `Environment` per method);
  - quick titles with and without an account;
  - API handlers and turn-token refusal;
  - CLI.
- **e2e:** the topology test (§6.2) plus a gateway test that the deleted RPCs
  are gone and the tables dropped.

### 11.2 Fixture gateway (`tools/fixtures/gateway`)

- **Seeded data.** `-e2e-fixture` seeds, through the real KV writers:
  - "Work" (Claude), signed in on daemon A and signed out on B, with usage
    windows;
  - "Personal" (ChatGPT), signed in on A and B, with a reset credit;
  - a default for each provider.
- **Fixture backend.** It is in-process: a paste code `FIXTURE-CODE`
  succeeds; a device code auto-approves after 2 seconds; a callback URL with
  `code=fixture` succeeds; usage changes deterministically. `usage.go` and
  `showcaseUsageQuotas` are replaced by seeded provider records, so the
  showcase screenshots keep a populated Providers page.
- Delete the `-usage-fixture` flag.

### 11.3 Device flows

- `tests/maestro/mac/providers.yaml`:
  1. Settings › Providers.
  2. "Work" shows its usage.
  3. Sign in on the second machine with `FIXTURE-CODE`; the state flips to
     signed in.
  4. In a new chat, choose "Work" in the Account menu and send; the header
     chip shows Work.
  5. Remove a scratch account.
- `tests/maestro/mobile/providers.yaml`: the same through Settings ›
  Providers, using `common/more.yaml` with `PLACE: providers` for the More
  path, plus the device-code variant (copy, wait for auto-approval).
- They run on `just e2e mac|android|ios tags:smoke`, and only on the E2E app
  identities and fixture gateways (AGENTS.md safety rules).

### 11.4 Live canary (manual, not in CI)

`tools/spikes/provider-accounts/live/` already holds the scripts. The release
checklist adds one real sign-in per provider on an isolated daemon (temporary
`DIETER_HOME`, free port, fixture gateway), one turn each, sign-out, then
`claude auth status` and `security dump-keychain` to show nothing is left.

## 12. Docs (M11)

- **ADR 0006, "Provider accounts".** Dieter never reads, stores, refreshes
  or replicates Claude.ai credentials. Logins are per machine. Account
  metadata, login state and usage replicate as KV records. Credentials never
  leave the machine that signed in. Login mutations refuse agent turns. The
  gateway stores no provider data.
- **`docs/invariants.md`:**
  - remove "normalized, credential-free provider quota snapshots" from the
    gateway list (L109-113);
  - add the provider-login rules under "Network and identity" and
    "Execution".
- **`docs/architecture.md`** (L16, L155-169: quota flow → accounts flow) and
  **`docs/threat-model.md`** (assets table: per-account Claude config dirs,
  Codex auth homes, `siwc.json`; gateway can/cannot lists; prompt-injection
  section: agents cannot sign in; stolen host: per-account sign-out; L93-94,
  L360).
- **ADR 0002** (quota snapshots no longer exist), `SECURITY.md:45`.
- **`docs/reference/environment.md`:** remove `DIETER_*_ACCOUNT_HOMES` and
  `DIETER_QUOTA_*`; describe `CODEX_HOME` and `CLAUDE_CONFIG_DIR` as
  host-login only.
- **User guide `site/content/docs/providers.md`.** It covers:
  - adding accounts and signing in from Mac, iPhone and Android, and the CLI;
  - why each machine signs in separately;
  - choosing an account per chat;
  - usage and resets;
  - SIWC;
  - troubleshooting (device codes disabled, port 1455, identity mismatch).
- **Other site pages:**
  - `harnesses.md` (replace "Provider quotas", L108-136);
  - `security.md` (L120, L137-146);
  - `gateway.md` (L15, L114);
  - `configuration.md` (L30, L66);
  - `cli.md` (L44, L53, L160-170);
  - `tour.md` (L94, L123, L166, with new screenshots from the showcase
    fixture);
  - `_index.md:45`, `architecture.md:15`, `site/layouts/index.html:73`;
  - the regenerated CLI reference.
- **Other files:** `apps/kotlin/README.md` (L76, L187), `docs/building.md`
  (L102-104), and a `CHANGELOG.md` entry.

## 13. Verification and release (M11)

1. **Checks.** Run `mise exec -- just check-changed --dry-run`, then the
   selected checks once:
   - `just lint`, `just generate` (no drift), `just test`, `just test-e2e`;
   - runtime `npm test`;
   - `just kotlin` core and UI tests, `just mac` unit tests;
   - `just e2e mac tags:smoke`, `just e2e android tags:smoke`,
     `just e2e ios tags:smoke`;
   - `just site check`.

   Rerun only what fails.

2. **Live canary** (§11.4).
3. **Release** `0.7.0` through `release.yml`: floors at `0.7.0-dev.0`;
   release notes cover the clean breaks (gateway usage data gone; existing
   Dieter Codex chats start new threads).
4. **Roll out daemons first, then the gateway** (the fleet procedure).
   Clients and daemons below the floor are refused until they update, as with
   0.6.

## 14. Acceptance criteria

1. **Sign-in from any app.** From a phone, add "Work" (Claude) and sign in on
   two machines, one with a pasted code and one by forwarding the address.
   Within a sync round, every app and `dieter provider list` on every machine
   show the same matrix.
2. **Default account.** A new chat on either machine defaults to Work. The
   turn runs with Work's `CLAUDE_CONFIG_DIR`, and no Claude token passes
   through Dieter code: the runner receives `auth: {}`.
3. **Switching.** Switching a chat to "Personal" between turns keeps the
   session; the next turn resumes it.
4. **Missing sign-in.** Choosing an account that isn't signed in on the
   chat's machine shows the reason in the picker, blocks sending, and offers
   "Sign in on ‹machine›".
5. **8-hour boundary.** A Claude turn across the token boundary finishes
   without a 401. A server-rejected token recovers through the runner retry
   and marks nothing expired unless the refresh fails.
6. **ChatGPT.** A ChatGPT account added with a device code (auto-restarted
   after 15 minutes) or a forwarded browser login runs Codex turns from
   `DIETER_HOME/codex`, and new cards get generated titles again.
7. **Usage.** Settings › Providers shows per-account 5-hour and weekly
   windows, "updated N min ago" and Dieter tokens. The header summaries
   follow `includeInSummary`. A ChatGPT reset returns its outcome.
8. **Removal.** Removing an account signs it out and deletes its directory on
   every machine; host logins are never signed out.
9. **CLI parity.** Every operation works through `dieter provider …`
   locally, and with `--machine` over direct TLS and relay.
10. **Agents.** A turn token cannot create, sign in, sign out, reset or
    delete accounts.
11. **Gateway.** The gateway has no provider tables, RPCs or link frames.
    `grep -ri quota internal/gateway` is empty apart from unrelated words.

## 15. Notes

- **Overlap with card `c_7152335f4a2ee3c3e65872ae`.** Its runner `auth`
  change and Claude quota rewrite are M3 and M4 here. Two options:
  - If it hasn't started, merge it into this work (`dieter card merge`) so
    the code changes once.
  - If it ships first, M3 and M4 build on it and delete its interim
    `quota-claude.mjs`.
- **To verify while building**, each with a test or a short live check:
  - Claude Code treats an empty `ANTHROPIC_API_KEY` as unset (M3);
  - whether the Codex bridge surfaces `account/rateLimits/updated` to the
    runner (M4);
  - global versus per-thread `base_url` for SIWC (M10);
  - the iOS loopback listener during an in-app browser sheet (M11).
- **Business and Team workspaces** were not tested; there is no account. If
  routing needs it, `ChatGPT-Account-ID` goes through the bridge's
  `start.headers`.

## 16. Implementation status (2026-11-14)

Milestones M1–M9 are built. M10 and M11 are built in part.

**Built:**

- Protos and the client contract.
- The `accounts` engine, with Claude Code, Codex and SIWC sign-in drivers, the
  Codex broker, usage, adoption, status checks and cleanup.
- The turn wiring: selection, admission, recovery, queue, schedules and quick
  titles.
- Runner `auth` and usage frames.
- The API, and the CLI `dieter provider` with `--account`.
- Deletion of the gateway quota pipeline.
- The Kotlin core providers domain, with an optimistic view of a just-created
  account.
- Mac Settings › Providers, the sign-in sheet, the composer and schedule
  account pickers, and the notice banner.
- The Compose equivalents on Android, iOS and the desktop shell.
- Fixture gateway seeding, plus tests at every level and Maestro flows.

**Deferred:**

- Automatic callback forwarding in the apps (the loopback listeners of §8 and
  §9). "Paste the address" covers it.
- The SIWC `auth.command` renewal block in the rendered Codex config. Long SIWC
  turns can outlive their 1-hour token.
- The hourly `model/list` refresh. Discovery reads the newest
  `models_cache.json` of the Dieter Codex home and the account auth homes.
- Storing Codex `account/usage/read` results.
- Waking cleanup on peer-synced tombstones. Removed accounts are cleaned up on
  the next background tick, within about 20 s.
- The device-code variant of the Maestro flow.
- The iOS device flow run, which needs internal disk space for a simulator.

Turns resolve provider accounts only when the daemon runs the real subprocess
runner, or when a fixture supplies an accounts backend. Tests with injected
runners keep the adapters' own credentials.
