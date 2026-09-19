# Provider account quota plan

Status: implemented for OpenAI Codex accounts. The provider-neutral protocol,
gateway coordination, daemon collector, CLI, and Mac/Android surfaces are in
place. Claude remains explicitly unsupported until its pinned harness exposes
an equivalent structured, read-only quota operation.

## Decision

Use the gateway as the account-wide coordinator and latest-snapshot cache, and
use enrolled daemons only as credential-local collectors:

```text
OpenAI / Claude account
        |
        | provider credential stays local
        v
eligible daemon quota adapter
        |
        | normalized, credential-free snapshot over the authenticated daemon link
        v
gateway selection + latest-snapshot store
        |
        +----> Mac / Android header bars + account-usage details
        +----> Dieter CLI
```

Each daemon advertises which provider accounts it can read. When data is
missing or stale, the gateway chooses one online daemon that advertises the
account, requests a refresh, validates and stores the normalized result, and
notifies clients. By default, the gateway schedules this once every 60 seconds
for every discovered account with at least one eligible online daemon, whether
or not a native client currently has the usage view open. The gateway must
never receive a provider access token, refresh token, API key, credential file,
or raw provider response.

Account cardinality is explicitly one-to-many per provider. A signed-in Dieter
user can have 1–N distinct OpenAI accounts (and likewise 1–N Claude accounts),
and a daemon can advertise several locally configured accounts at once. The
gateway deduplicates copies of the same provider account seen on several
daemons, but never combines different accounts merely because they have the
same plan. Public responses group the complete account list by provider and
include one deterministic provider summary for the compact header bar; the
popover preserves the independent quota, reset, credit, availability, source,
and freshness state of every account.

This deliberately changes one existing gateway invariant: the gateway will
store a small amount of provider-account metadata. It still will not store
projects, conversations, working-tree data, harness credentials, or provider
request/response content. README, security documentation, settings copy, and
`AGENTS.md` must describe that exception precisely when the feature lands.

## Initial scope

The first release covers subscription-plan capacity used by the two Dieter
harnesses:

- OpenAI Codex through ChatGPT authentication: usage windows, used/remaining
  percentage, an explicit five-hour window when returned, the next scheduled
  window reset, plan type, credit balance state, ordinary-usage permission, and
  available rate-limit-reset credits with expiry.
- Claude Code through a Claude subscription: plan usage windows and reset
  times—including a rolling five-hour window when returned—and the next
  scheduled reset, plus the user's usage-credit spend/limit when the supported
  structured provider surface supplies it.

API billing, organization spend, and per-model API request/token rate limits
are not the same thing as subscription capacity and must not be merged into the
same bars. A later adapter can add API-account metrics with an explicit
`account_kind`. OpenAI API rate limits are organization/project/model scoped
and are normally reported in API response headers; Dieter must not make a paid
model request merely to sample those headers.

The UI should call a percentage “remaining” only when the provider returned a
real used percentage. Dynamic message estimates are not an absolute quota, so
Dieter must not invent “messages left.”

Keep two reset concepts distinct throughout the schema and UI:

- **Next scheduled reset** is the earliest authoritative future `resets_at`
  among the account's current quota windows, labeled with the window that will
  reset. Dieter must not extrapolate it from a duration when the provider omits
  the timestamp.
- **Reset credits** are OpenAI's banked, consumable rate-limit resets. Show the
  available count and provider-supplied expiry separately. Reading quota data
  never redeems one.

## Provider feasibility findings

### OpenAI Codex

Dieter pins `@openai/codex-sdk` 0.154.0 and its Codex 0.154.0 executable in
`internal/harness/runtime/package.json`. The executable's generated app-server
schema has a structured, read-only `account/rateLimits/read` operation. Its
response includes:

- an optional stable `accountId`;
- the backward-compatible quota bucket and a map of buckets by `limitId`;
- primary and secondary windows with `usedPercent`, `windowDurationMins`, and
  `resetsAt`;
- plan type, ordinary-usage permission, credit balance/unlimited state, and
  individual spend-control state; and
- available reset-credit count and optional detail rows with status, kind,
  grant time, and expiry.

The adapter should launch the pinned app server directly, initialize it, call
`account/read` and `account/rateLimits/read`, normalize the response, and exit.
It must not parse `/status` terminal text and must never call
`account/rateLimits/consume`, because redeeming a reset credit is a separate,
user-authorized mutation outside this plan.

Official OpenAI documentation confirms that current Codex subscription limits
and reset times are shown in the usage dashboard and `/status`. It also
explains that Codex estimates use a five-hour period, that weekly limits may
also apply, and that the limits are usage-dependent rather than fixed message
counts. See [Codex pricing and usage limits](https://developers.openai.com/codex/pricing#what-are-the-usage-limits-for-my-plan)
and [current usage limits](https://developers.openai.com/codex/pricing#where-can-i-see-my-current-usage-limits).
For the separate API-account case, see [rate-limit response headers](https://developers.openai.com/api/docs/guides/rate-limits#rate-limits-in-headers).

### Claude Code

The pinned Claude harness currently uses Claude Code 2.1.245. Official Claude
Code documentation says interactive `/usage` shows subscription-plan bars,
activity, usage breakdown, and usage-credit spend. It also says Claude Code
falls back to a locally cached usage snapshot no older than 60 minutes when
the usage endpoint is throttled. Claude documents rolling five-hour and weekly
seat windows for Team and Enterprise plans. See [Claude Code cost and usage tracking](https://code.claude.com/docs/en/costs#using-the-usage-command)
and [Claude subscription windows](https://code.claude.com/docs/en/costs#claude-for-teams-and-enterprise).

Unlike Codex app-server, the currently integrated Claude harness does not
expose a documented structured quota operation to Dieter. Make this the first
implementation gate:

1. Prove that the pinned Claude bridge or supported SDK can request the same
   plan-usage data as `/usage` without submitting a model prompt or consuming
   tokens.
2. Capture a sanitized structured fixture and identify a stable account
   identifier suitable for correlation.
3. Put that call behind the same provider-neutral adapter contract as Codex.

Do not ship terminal-screen scraping, reverse-engineered HTTP calls using raw
OAuth tokens, or direct reads of provider credential files in gateway code. If
the pinned Claude integration has no stable structured seam, land the common
protocol and OpenAI adapter first, keep Claude explicitly `unsupported`, and
finish Claude only after adding or upstreaming a supported bridge operation.

## Normalized model

Define provider-neutral messages in `api/proto/dieter/gateway/v1/gateway.proto`.
The public snapshot needs these concepts, not provider JSON:

- `provider`: initially `openai_codex` or `anthropic_claude`;
- `account_key`: an opaque gateway-account-scoped correlation key;
- `account_kind`: subscription, API, or unknown;
- `plan`: a bounded provider label, optional;
- `availability`: available, signed out, unsupported, temporarily unavailable,
  or permission denied;
- `windows`: bounded rows containing a stable bucket ID, display label,
  normalized kind (`five_hour`, `weekly`, `monthly`, `model`, or `other`), used
  percentage, derived remaining percentage, optional duration, and optional
  authoritative absolute reset time;
- `next_reset_at` and `next_reset_window_id`: the earliest future reset from the
  current returned windows, absent when the provider supplied no future reset;
- `credits`: optional balance as a decimal string, `has_credits`, and
  `unlimited`;
- `spend_allowance`: optional decimal used/limit values, currency, remaining
  percentage, and reset time;
- `reset_credits`: available count plus a bounded list of display title, kind,
  status, grant time, and expiry; omit the provider's redemption identifier;
- `ordinary_usage_allowed`: optional provider-authoritative boolean;
- `refreshed_at`, `next_refresh_at`, `fresh_until`, and `last_success_at`;
- `refresh_state`: idle, refreshing, throttled, or failed; and
- `online_source_count`, so clients can explain why stale data cannot refresh.

Keep freshness separate from availability. A valid old snapshot with no online
source is `stale`, not zero usage and not signed out. Do not infer restored
access from an elapsed reset time when the provider also returned an
authoritative permission state. Classify a provider window as `five_hour` when
its structured duration is 300 minutes or the provider contract identifies it
as such; do not invent that row from plan marketing text.

Use integers for percentages, RFC 3339 timestamps on Dieter APIs, and decimal
strings for money/credits. Reject out-of-range values and unknown oversized
payloads at the daemon and gateway boundaries. Initial bounds should be no more
than 8 accounts per provider per daemon, 16 windows per account, 32 reset-credit
details, 128 characters per label, and 64 KiB for a complete presence or result
frame.

Expose quota reads as provider groups rather than a flat list that each client
must interpret differently:

```text
ProviderQuotaGroup
  provider
  accounts[]
  summary

ProviderQuotaSummary
  total_account_count
  numeric_account_count
  unavailable_account_count
  remaining_percent?        // selected value, never an average or sum
  summary_account_key?      // account that supplied the selected value
  summary_window_id?
  summary_window_kind?
  freshness
```

The gateway derives `summary` from its account catalog so Mac, Android, CLI,
and future clients agree. Consider every valid percentage from every included
quota window of every distinct account, including a retained stale snapshot, and
select the lowest remaining percentage. This is a conservative warning about
the most constrained account/window, not an estimate of interchangeable pooled
capacity. Break ties by window reset time (earliest first), then account key
and window ID for stable rendering. A stale selected snapshot retains its value
but marks the summary stale. Signed-out, unsupported, failed, or percentage-less
accounts do not contribute a fabricated number; count them in
`unavailable_account_count`. If no account has a numeric value, omit the bar
value and derive the outlined status from the bounded account states. Any
account add, removal, snapshot, or state change recomputes and publishes the
group atomically.

## Private account correlation

The gateway needs to recognize the same provider account on two machines
without relying on its email or uploading its provider identifier.

1. Generate and persist a random 256-bit correlation key per authenticated
   GitHub account in the gateway store.
2. Return that key only to an authenticated enrolled daemon in the daemon-link
   hello acknowledgement.
3. On the daemon, compute
   `HMAC-SHA256(key, provider || 0x00 || stable_provider_account_id)`.
4. Send only that digest as `account_key`; never send the input identifier.

Do not hash an access token or refresh token. If a provider supplies no stable
account ID, that adapter is not eligible for cross-daemon refresh until the
structured provider integration supplies one. Account email is never used as
the correlation input. When the structured account API returns it, the daemon
may include a bounded display-only email in the normalized snapshot; it remains
owner-scoped and must never be logged.

The UI identifies rows by provider, plan, optional provider-supplied display
email, and a short digest suffix. Optional user-defined nicknames can be a later
gateway-owned feature.

## Daemon collection service

Add an `internal/providerquota` package independent from harness model
discovery. Slow provider startup must not delay `GetHarnesses`, heartbeats, or
agent admission.

The package should expose a small adapter interface:

```go
type Adapter interface {
    Discover(context.Context) ([]Account, error)
    Refresh(context.Context, Account) (Snapshot, error)
}
```

`Discover` returns local opaque handles and stable IDs; the manager turns IDs
into account HMACs and retains the handles only in daemon memory. `Refresh`
returns only the normalized schema. Adapter errors crossing the daemon link
must be bounded codes and safe summaries, never raw stderr, HTTP bodies, or
credential paths.

For OpenAI, discovery must enumerate every explicit Codex credential profile
known to Dieter, not just whichever account is active in a default process
environment. A local account source binds an opaque in-memory handle to its
credential context (for example, its configured runtime/profile root). The
adapter launches the pinned app server in that exact context, calls
`account/read`, and verifies that the returned stable ID hashes to the requested
`account_key` before accepting `account/rateLimits/read`; a mismatch is a
bounded identity error, never quota data for another row. Reconcile and send
the complete presence set when profiles are added, removed, signed in, signed
out, or switched. Do not scan arbitrary home-directory locations for accounts,
upload profile names or paths, or mutate the user's active Codex account during
discovery or refresh. If Dieter does not yet have an explicit multi-profile
registry, adding that local registry is part of phase 1 rather than silently
falling back to one global Codex login.

Run discovery after the gateway hello acknowledgement supplies the correlation
key, on provider-auth changes when observable, and on a slow jittered interval.
Send presence changes in their own control frame. Do not attach quota snapshots
to every 5–20 second liveness heartbeat.

Handle gateway refresh requests off the daemon-link receive loop with bounded
work: one in-flight refresh per provider account, at most two provider probes
per daemon, and a 15-second default deadline. Coalesce duplicates. Cancellation
ends only the probe it owns and must not affect an active agent turn. Verify in
fixtures that a quota probe can coexist with an active provider bridge without
corrupting or racing credential state; otherwise coordinate through a
provider-specific read lock and return the cached snapshot rather than blocking
agent work.

The probe runs from Dieter's private runtime directory, never a project or card
worktree. It must not submit a prompt, create a conversation, wake an agent, or
consume subscription capacity.

## Daemon-link protocol

Extend `DaemonLinkFrame` with typed messages and new frame kinds:

- `PROVIDER_ACCOUNTS`: daemon-to-gateway account presence and adapter
  capability;
- `PROVIDER_QUOTA_REFRESH_REQUEST`: gateway-to-daemon provider, account key,
  request ID, and deadline;
- `PROVIDER_QUOTA_REFRESH_RESULT`: daemon-to-gateway normalized snapshot or
  bounded error code.

Add `provider_quota_v1` to negotiated daemon-link capabilities and add the
per-owner correlation key to `HELLO_ACK`. A new daemon connected to an old
gateway receives neither and leaves quota collection disabled. A new gateway
never selects an old daemon that did not advertise the capability.

Keep quota requests out of the existing client relay stream map. They are
gateway-owned control work, not user-relayed `DieterService` RPCs. Give them a
separate bounded pending-request map and queue so a slow provider cannot occupy
one of the 16 client relay slots or delay heartbeat acknowledgement. Match every
result by daemon ID, generation, request ID, provider, and account key; discard
late results after timeout, reconnect, revocation, or source removal.

## Gateway coordinator and storage

Add a quota manager beside `Hub`, explicitly started and stopped by the
production gateway server. Constructing a handler in a test must not create an
uncontrolled background loop. Give the manager a clock/ticker dependency so
the 60-second schedule is deterministic under tests.

Persist only the current normalized snapshot and account/source directory:

```text
provider_accounts
  (github_id, provider, account_key, account_kind, plan,
   first_seen_at, last_seen_at)

provider_account_preferences
  (github_id, provider, account_key, summary_included, updated_at)

provider_account_sources
  (github_id, provider, account_key, daemon_id, capability,
   last_seen_at, last_success_at, last_failure_code)

provider_quota_snapshots
  (github_id, provider, account_key, schema_version, snapshot,
   source_daemon_id, refreshed_at, fresh_until)
```

Use foreign keys where practical, one atomic migration, and the existing
single-writer/transaction rules. Store a validated protobuf or normalized JSON
blob, never raw provider JSON. Overwrite the latest snapshot instead of keeping
history. Remove source rows when a daemon is revoked or stops advertising an
account; retain the last snapshot as stale for 30 days, then prune accounts
with no source. Sign-out must make quota data unreachable immediately through
session authentication; a future “delete account data” operation can remove
retained rows explicitly.

All reads and writes are scoped by the authenticated principal's immutable
GitHub ID. The gateway derives that owner from the enrolled daemon record and
must ignore any owner identity supplied in a quota frame.

### Refresh policy

- Return cached data immediately. A missing row schedules an immediate refresh;
  the UI never turns a gateway request into an unbounded provider wait.
- Default to one refresh attempt per account every 60 seconds whenever at least
  one online daemon advertises both the exact account key and
  `provider_quota_v1`. This schedule runs even with no connected quota watcher.
- Spread each account's initial phase deterministically within the first minute
  so many accounts do not fire together, then keep a 60-second cadence. Set
  `next_refresh_at` to the next slot and treat a successful snapshot as fresh
  until that slot. Missing one slot makes the age visible as stale; it never
  turns the values into zero.
- When the first eligible daemon appears or an account is newly discovered,
  refresh immediately, then join the normal 60-second cadence. When the last
  eligible daemon disappears, stop attempts for that account without deleting
  its cached snapshot. Resume immediately when a source returns.
- Coalesce all refreshes for one `(github_id, provider, account_key)`.
- A manual refresh joins an in-flight request. Otherwise it may start the
  account's next attempt early, but never causes more than one provider request
  inside a 60-second interval unless the preceding attempt failed before
  reaching the provider.
- Honor provider retry hints. On failure, preserve the last successful
  snapshot and pause the one-minute schedule for the provider's `retry_after`
  or a bounded 1, 2, 5, 15, then 60-minute backoff. The next successful refresh
  restores the default 60-second cadence. This exception is necessary because
  Claude documents that its usage endpoint can be rate limited.
- Choose an online capable source that advertises the exact account key. Prefer
  the last successful source, then the least recently attempted source. Try at
  most one alternate daemon after a transport/startup failure; do not fan out
  provider calls.
- Bound the gateway globally, initially to eight simultaneous provider
  refreshes and one per account. Reads are idempotent, but an uncertain result
  still must not cause simultaneous retries.
- If a scheduled slot arrives while the account's previous request is still in
  flight, coalesce it instead of queueing another probe. Record the skipped slot
  and schedule the next attempt promptly after completion, still subject to
  throttling/backoff.

Use gateway receive time for `refreshed_at` so a daemon with a skewed clock
cannot make a result appear fresh indefinitely. Preserve provider-supplied
absolute reset/expiry times as data and expose clock-skew-safe relative labels
from the client.

## Gateway API and CLI

Add authenticated gateway RPCs rather than overloading daemon presence:

- `ListProviderQuotas`: provider-grouped account arrays, their gateway-derived
  summaries, and refresh/source state for the signed-in gateway account;
- `WatchProviderQuotas`: an initial grouped catalog followed by atomic
  group/account updates and bounded heartbeats; and
- `RefreshProviderQuotas`: request one account/provider or all stale accounts,
  coalesce work, and return current state plus whether refresh was accepted.

Increment `GatewayAPIVersion`. New clients hide the feature against an older
gateway instead of showing an error loop. Keep the existing early HTTP
authentication rejection and gRPC interceptors; quota RPCs are authenticated
by default and need explicit owner-isolation/security tests.

Add gateway-scoped CLI parity:

```text
dieter quota list [--gateway URL] [--refresh] [--format json|jsonl]
dieter quota watch [--gateway URL]
dieter quota refresh [PROVIDER] [--account KEY]
```

These commands use the CLI's Dieter gateway session and do not accept global
`--machine`, because selection belongs to the gateway. Give the group and every
leaf useful offline help. Update root help, `README.md`, the Dieter CLI skill,
and CLI tests. Machine-specific diagnostics may report which daemons advertise
quota capability, but normal output must not expose full account keys or source
daemon internals.

## Native UI

Make the compact quota strip the primary at-a-glance surface. On Mac, place it
at the trailing edge of the conversation header—the upper-right area indicated
in the reference screenshot. The concrete integration point is the primary row
in `ConversationChrome`, immediately before the existing workspace, runtime,
menu, and content-pane controls. It must represent the active gateway account,
not the currently selected machine, project, card, or harness.

At a normal pane width the strip contains one compact provider chip for OpenAI
and one for Claude:

```text
…conversation title…    OpenAI  5h [██████░░]    Claude  5h [████░░░░]
…conversation title…    OpenAI · 3  5h [██░░░░░░] Claude  5h [████░░░░]
```

- OpenAI uses a semantic blue provider token; Claude uses a semantic orange
  provider token. Define dark- and light-appearance variants in `DieterTheme`
  rather than borrowing the user-selected app accent.
- Each chip has a short provider label or mark, the name of the window driving
  the summary, and a neutral track whose colored fill is **remaining** quota.
  Full means all reported capacity remains. Do not invert that meaning between
  providers.
- The summary uses the lowest valid remaining percentage among that provider's
  active accounts and windows, so it is a conservative warning rather than an
  average. If that is not the five-hour window, label it `Week`, `Month`, or the
  bounded provider label instead of leaving the bar ambiguous.
- With one account, the chip is its exact summary and omits an account-count
  badge. With multiple accounts for one provider, show the total count (for
  example `OpenAI · 3`) and let the detail surface enumerate all of them with
  the privacy-safe digest suffix. The fill remains the gateway-selected minimum
  across accounts/windows; never add, average, or otherwise imply that separate
  account quotas are one pooled allowance. If any account lacks a usable
  percentage, retain the numeric summary from the other accounts but add a
  status marker and accessible text such as “1 of 3 accounts unavailable.”
- Do not reserve an empty chip for an undiscovered provider. Signed-out,
  unsupported, failed, or missing percentage states use an outlined chip and a
  status glyph, never an empty bar that could be mistaken for 0% remaining.

At narrower widths, first hide the provider text while retaining the provider
mark, window label, and bar; then collapse both providers into one quota button
before allowing the strip to collide with the existing header controls. In the
compact board conversation, put that button in `sidebarActions`. The collapsed
button shows the most constrained provider and opens the same details. Android
uses the equivalent trailing app-bar control; tap opens a sheet because hover
does not exist.

### Hover, focus, and account details

Hovering a provider chip opens an anchored detail popover after a short delay.
Keep it open while the pointer moves between chip and popover, and add a small
dismiss delay to avoid flicker. Hover must not initiate a provider request: it
only reads the gateway projection already maintained by the 60-second refresh
loop.

The popover lists each account for that provider. For every account show:

- provider, plan, and a short digest suffix only when disambiguation is needed;
- **Next planned reset** near the top, for example “5-hour window resets today
  at 15:42”; show “Not reported by provider” when no current window has an
  authoritative future reset time;
- a dedicated five-hour progress row when the provider returns that window,
  showing used and remaining percentage plus its exact reset time;
- one progress row for every other provider window, for example “Weekly: 41%
  remaining · resets Friday 09:00”;
- credit/spend information when present;
- for OpenAI, “2 reset credits available” and the nearest expiry, with an
  optional disclosure for bounded detail rows;
- “Updated 24 seconds ago,” the next automatic refresh, refreshing state, or a
  clear stale reason; and
- a refresh button plus a link to the provider's official usage page.

Start the popover with a compact explanation such as “Showing the lowest
remaining limit across 3 accounts.” Put the account/window currently driving
the header summary first and mark it “Header summary”; order the remaining
accounts by the stable privacy-safe suffix so live refreshes do not reshuffle
them. Each refresh action targets that account; an additional provider-level
action refreshes all visible accounts using the existing per-account
coalescing and rate limits. Removing or losing one account removes only its
row and immediately recomputes the header summary.

The compact chip is also a button: click toggles the popover, keyboard focus
shows the same information on activation, Escape dismisses it, and Android tap
opens the detail sheet. Provide one combined accessibility label and value,
for example “OpenAI quota, five-hour window, 62 percent remaining, resets today
at 15:42.” VoiceOver and TalkBack must expose freshness and stale status. Color
identifies the provider only; text/marks identify OpenAI versus Claude, while a
warning glyph and status text communicate low, stale, or unavailable states.

Use a neutral unfilled track with sufficient contrast in every Dieter palette.
Keep the blue and orange hues stable across palettes, with appearance-specific
values chosen by contrast tests. Animate only the changed fill on a new
snapshot; use a static refresh glyph when Reduce Motion is enabled. Do not run
a per-second view timer merely to update relative labels.

Also add a full **Account usage** panel in the existing Agents settings on Mac
and the equivalent Android settings surface. It uses the same gateway-scoped
view model and contains the same account rows in a roomier layout. Clicking
“Account usage” in the header popover opens that panel. Keep cached catalogs
separate for multiple configured gateways; switching gateways must never flash
the previous gateway's bars.

Never render missing data as 0%. If all sources are offline, retain the last
bars and say that no eligible machine is online. If an adapter is signed out or
unsupported, show the action on a daemon rather than asking the native client
for provider credentials. If there is no five-hour window, say “No five-hour
limit reported” in expanded details rather than deriving one from another
window. Once a returned reset time has passed, mark it “refresh needed” until a
new provider snapshot arrives; do not advance the timestamp locally by five
hours.

Use text as well as color, accessible progress labels, Dynamic Type/adaptive
layout on Android, and VoiceOver/TalkBack coverage. The header strip, popover,
and settings panel must consume one gateway projection and one refresh path.

The current Connection settings text says the gateway stores only sign-in and
discovery information. Update it to say that provider credentials, projects,
and conversations stay on machines while the gateway may cache normalized
quota metadata for the signed-in account.

## Implementation sequence

### 0. Provider proof and fixtures

- Build isolated Codex and Claude quota probes against pinned versions.
- Generate Codex app-server schemas during fixture maintenance and fail tests
  when the consumed fields change incompatibly.
- Prove a supported, structured, token-free Claude path or record Claude as
  blocked without weakening the adapter boundary.
- Produce sanitized fixtures for signed-in, signed-out, multiple windows,
  one and several OpenAI accounts, duplicate copies of one account on multiple
  daemons, a five-hour window, no five-hour window, next-reset selection,
  credits, reset credits, provider throttling, and malformed responses.

Exit: stable account identity and structured normalized snapshots are proven
for each provider that will ship.

### 1. Model and local collector

- Add provider-neutral Go types, validation, redaction, and adapter interfaces.
- Implement Codex and the proven Claude adapter.
- Add manager concurrency, timeouts, explicit multi-profile discovery, account
  HMACs, requested-account identity verification, and mock adapters. Keep
  provider work out of project directories and harness catalog discovery.

Exit: a daemon can discover and refresh disposable fixture accounts without a
gateway and without submitting a model request.

### 2. Daemon-link and gateway cache

- Add negotiated frame capability, correlation-key delivery, account presence,
  bounded refresh request/result handling, selection, coalescing, failover, and
  backoff.
- Add gateway migrations, latest-snapshot persistence, revocation cleanup, and
  retention.
- Add the always-on, source-aware 60-second scheduler with deterministic test
  time, coalescing, and provider backoff.
- Cover new/old daemon and gateway combinations.

Exit: two isolated daemons advertising the same account produce one gateway
row, and either daemon can refresh it after the other disconnects.

### 3. Public API and CLI

- Add list/watch/refresh gateway RPCs, regenerate all clients with `just proto`,
  increment the gateway API version, and implement CLI commands/help.
- Add authentication, owner isolation, body/frame limit, direct gateway, and
  proxy-mode tests.

Exit: a signed-in CLI sees fresh and stale snapshots correctly without choosing
a machine.

### 4. Mac and Android UI

- Add gateway-scoped quota state and recovery to both clients.
- Add blue OpenAI and orange Claude quota chips to the trailing conversation
  header, with conservative summary bars, responsive collapse, and anchored
  hover/focus/click details on Mac.
- Add the Android app-bar/tap-sheet equivalent and adaptive full account-usage
  panels on both clients, including refresh actions, stale states, and provider
  links.
- Hide the panel for old gateways and keep cached values through daemon loss.

Exit: native UI tests cover the header bars and details in fresh, refreshing,
stale, offline, signed-out, unsupported, multiple-account, multiple-window,
credit, and reset-expiry states.

### 5. Documentation, validation, and rollout

- Update the gateway data-boundary claims in `AGENTS.md`, README, landing-page
  security/configuration docs, native UI copy, privacy disclosures, and the CLI
  skill.
- Roll out capability-gated and monitor only safe counters: refresh result code,
  latency, age, provider, and selected-source count. Never log account keys,
  labels, balances, reset details, provider bodies, or credentials.
- Keep one rollback switch that disables gateway refresh requests while leaving
  cached rows readable and stale.

Exit: security documentation matches storage reality and all focused checks
pass.

## Required tests

- Adapter fixtures: schema drift, null/unknown fields, percentage bounds,
  decimal handling, five-hour classification, multiple buckets, earliest-future
  reset selection, elapsed resets, reset-credit expiry, throttling, timeout,
  and secret redaction.
- Daemon manager: discovery changes, auth loss, duplicate requests, provider
  semaphore, cancellation, active-turn coexistence, and no process leaks.
- Link/hub: handshake key delivery, capability negotiation, 64 KiB bounds,
  request correlation, late results, reconnect generation, revocation, stalled
  queues, and heartbeat independence.
- Gateway store/manager: atomic migration, GitHub-owner isolation, same-account
  deduplication, different-account separation, source removal, selection,
  failover, 60-second cadence with and without watchers, immediate refresh on
  source return, coalescing, backoff, stale preservation, pruning, provider
  grouping, deterministic summary tie-breaking, and atomic summary recompute.
- API/CLI: missing/expired session, gateway version compatibility, list/watch/
  refresh help and JSON output, and no accidental `--machine` routing.
- Native clients: per-gateway state, reconnect, manual-refresh coalescing,
  blue/orange provider identity, remaining-fill direction, one-account and
  multi-account summary display, unavailable-account status, complete stable
  popover rows, summary-window selection, hover persistence,
  keyboard/click/tap parity, accessibility labels, narrow header collapse,
  Reduce Motion, and offline cached display.
- Isolated end to end: temporary gateway, two enrolled daemons, mock provider
  accounts, direct account API calls, daemon disconnect/failover, and owner
  separation. Never use the operator daemon or real provider credentials.

Run `just check-changed --dry-run`, then `just check-changed`; run focused
gateway/daemon/harness tests and the related Mac and Android test suites. Any
real-account smoke test must be explicit, read-only, separately authorized, and
must confirm that no provider request consumes model usage.

## Acceptance criteria

- The same OpenAI or Claude account on two online daemons appears once.
- One Dieter user can expose 1–N distinct OpenAI accounts. Each distinct account
  appears once even when plans match, while duplicate sources for the same
  account collapse behind that account row.
- The gateway asks only one eligible daemon for a refresh and fails over at
  most once after a transport/startup failure.
- By default, each discovered account is refreshed once every 60 seconds while
  an eligible daemon is online, including when no client is watching; fake-clock
  tests permit only bounded scheduler tolerance and no duplicate provider call.
- With no eligible daemon, no refresh probe is attempted. The first returning
  eligible daemon triggers an immediate refresh and restarts the cadence.
- With every daemon offline, the last successful snapshot remains visible and
  is clearly stale.
- The upper-right conversation header shows a blue OpenAI bar and orange Claude
  bar when those accounts exist. Each fill means remaining quota and names the
  window it summarizes; color is never the only provider or status cue.
- Each provider gets one header bar. It selects the most constrained returned
  account/window without adding or averaging quotas, shows the provider's total
  account count when greater than one, and signals any accounts without usable
  data. Hover, focus/click, and Android tap expose a separate stable row for
  every account and every returned window, including each account's five-hour
  limit and next planned reset.
- The quota controls collapse before colliding with existing conversation
  controls and remain operable with keyboard navigation, VoiceOver, TalkBack,
  narrow layouts, and Reduce Motion.
- OpenAI shows all returned windows, reset times, credit state, available reset
  count, and expiry without exposing redemption IDs.
- OpenAI quota bars stay blue. The header uses the conservative minimum across
  accounts whose gateway-owned `summary_included` preference is enabled; the
  popover keeps excluded accounts visible and offers an immediate inclusion
  toggle.
- An authenticated user can consume one OpenAI reset credit for an exact
  account after confirmation. The gateway preserves a UUID idempotency key and
  routes the request only to an online capability-advertising daemon that has
  that account; the daemon consumes through the structured app-server API and
  returns a refreshed normalized snapshot.
- Claude shows provider-authoritative plan windows through a structured,
  token-free integration; terminal parsing is not accepted.
- When supplied by either provider, the five-hour window has a dedicated row
  with used/remaining percentage and its authoritative reset time.
- The account summary shows the next planned reset and names its window; when
  no future reset is returned, it says the schedule is unavailable rather than
  estimating one.
- No provider credential or raw provider response reaches gateway storage,
  native clients, logs, or metrics.
- A different GitHub account cannot enumerate, correlate, refresh, or read the
  stored accounts or snapshots.
- Old clients, gateways, and daemons continue their existing behavior without
  reconnect loops or malformed presence failures.
- Refresh work is bounded and does not delay daemon heartbeats, client relay
  RPCs, or agent turns.

## Main implementation risk

OpenAI is ready for a structured implementation with the pinned app-server
contract. Claude is the only material feasibility risk: `/usage` proves the
data exists, but not that Dieter's pinned harness exposes a supported structured
read. Resolve that in phase 0. Do not compensate for a missing interface by
moving Claude credentials to the gateway or scraping its interactive terminal.
