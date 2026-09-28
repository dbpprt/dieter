# Dieter product assessment — 28 September 2026

Assessment only. No product code was changed. Code evidence refers to
`HEAD 99a85897` (release 0.4.326). Live observations come from read-only CLI
commands against the operator's own daemon and from the public
`gateway.getdieter.com/healthz`. The uncommitted work in progress on this date
(harness checkpoint shutdown, Android Quick Task draft) is noted where it
matters but not counted as shipped.

**How to read this report**

- **Fact**: checked in code, a command, or a live endpoint, with a cited path.
- **H#**: a hypothesis. Plausible but not validated.
- **R#**: a decision that needs user research (§11).
- **D#**: a decision that belongs to the owner (§11).
- Live usage numbers come from one heavily dogfooded account (n = 1). They show
  how the product behaves, not what the market wants.

---

## 1. Executive summary

Dieter is technically strong, but in practice it is a single-operator product.
The engineering (durable conversations, idempotent admission, signed
replication, three native clients, a hardware-accelerated remote screen) is well
ahead of the product around it. The headline promise is *"Close your laptop.
Keep your agents running."* The *running* half is mostly delivered. The
*closing the loop while away* half — knowing when work is done, is blocked, or
needs you, and acting on it — is not.

Five findings dominate:

1. **Activation is closed.** Every client and the CLI send new users to a
   gateway that admits only numeric GitHub IDs listed in an environment variable
   (`internal/gateway/config.go:93-102`). There is no request-access path. A
   rejected user sees "This GitHub account is not allowed." (`auth.go:414`). The
   only alternative is self-hosting a public TLS service with a GitHub OAuth app
   and TURN. On top of that, the first command a Homebrew user copies is wrong
   (`scripts/homebrew_formula.py:52`).
2. **The away-from-desk loop is broken.**
   - There is no push notification path on any platform.
   - The daemon only emits `starting`, `running`, `idle` and `failed`. So on Mac,
     a successful turn never notifies, and only failures do
     (`apps/mac/Sources/DieterCore/RuntimeActivity.swift:19-24`).
   - The Mac notification toggles are hard-wired `.constant(true)`
     (`DieterSettingsView.swift:1050-1052`).
   - Android notifies board cards only when they enter Review on boards the user
     opted into. That opt-in set is empty by default.
   - iOS has no notifications, no inbox and no read receipts.
3. **Board status has no ground truth.**
   - "Review" is a lane the *agent* moves itself into, following prompt text
     (`internal/prompt/prompt.go`, `DefaultBoardSkillTemplate`).
   - A blocked card and a working card look the same.
   - Agent questions are ordinary replies. The `waiting_for_user` state that all
     three clients render is never produced by the daemon; it appears only in
     test fixtures (`scripts/isolated-gateway/inbox_fixture.go:30`).
4. **Trust is under-disclosed and over-scoped.**
   - Every harness runs with approvals off (`runner.mjs:345`,
     `permissionMode: 'allow-all'`, which maps to Claude
     `bypassPermissions` / Codex `danger-full-access`). The docs say only
     "unsandboxed".
   - Any enrolled daemon authenticates as the whole account (`auth.go:240-262`),
     so one prompt-injected agent can reach every host.
   - There is no per-device session revocation.
   - The relay is not end-to-end encrypted.
   - Replicated board state recently stalled silently for about 2.5 days
     (`docs/board-lookup-investigation-2026-09-28.md`).
5. **The core promise has been commoditized.** Claude Code Remote Control and
   cloud sessions, Codex remote hosts, and Cursor "My Machines" now bundle
   "keep running while the laptop is closed, steer from your phone" into
   $20–200 subscriptions. Open-source peers on the same own-hardware
   architecture (Paseo, Happy/Happier) have 3–4 orders of magnitude more
   adoption (§9). What Dieter can still defend is **vendor-neutral agents on
   hardware you own, with the board as the durable record, and no third-party
   control plane holding transcripts.** That last claim is only credible once
   the relay is end-to-end encrypted.

**Recommendation.** For the next six weeks, stop adding surface area (screens,
harnesses, replicated record types) and make the promise true for one user:

- open, guided activation;
- daemon-owned attention states that drive honest notifications;
- visible trust boundaries;
- a release process that doesn't strand clients.

Then build push, actionable mobile notifications, an end-to-end encrypted
relay, and blast-radius controls. Monetizing a hosted gateway comes only after
that (§8).

---

## 2. What the product is today (facts)

| Aspect | Current state |
| --- | --- |
| Components | Go daemon/CLI (`dieter`, 25 command groups, 132 RPCs in `api/proto/dieter/v1/dieter.proto`); Go gateway (20 account-scoped RPCs); macOS 26+ app (≈53k lines of Swift, Apple Silicon); Android 8+ app (≈37k lines of Kotlin); iOS/iPadOS beta (≈11k lines) |
| Agents | Codex, Claude Code, Pi, Oh My Pi (OMP), DeepSeek Harness, via a pinned AI SDK harness runtime (`internal/harness/runtime`) |
| Execution | Unsandboxed, full-auto, on the daemon host; one active turn per conversation; concurrent turns allowed in one checkout |
| Work model | Project → checkout(s) → board → fixed lanes (Todo/Running/[Review]/Done) → card = one durable conversation; plus standalone chats, labels with agent instructions, schedules, folders |
| Remote surfaces | Files, Changes/Git, terminals, background processes, remote exec, remote screen (WebRTC/HEVC) |
| Networking | Direct TLS → WebRTC (direct/TURN) → bounded gateway relay |
| Distribution | Homebrew formula + cask (Mac); `curl \| sh` + cosign (Linux); sideloaded APK with self-updater (Android); manual TestFlight (iOS) |
| Cadence | 460 commits since 2026-08-20; 255 tags (≈6 per day); every push to `main` releases; only the 2 newest GitHub releases are kept (`just/release.just:211-224`) |
| Business | MIT license; no pricing, billing, entitlements, analytics or crash reporting anywhere; GitHub Issues and Discussions disabled; 5 stars |

**Engineering focus in September (facts).** Of 348 non-merge commits, about 110
were features/UI, about 68 test/CI stabilisation, about 61 screen
sharing/remote desktop/terminals, about 35 release/deploy, and about 40 core
runtime or data-integrity fixes. Remote desktop, WebRTC control, terminals and
exec make up ≈10k of ≈57k non-test Go lines in `internal/`. Screens is
≈2.5k of ≈10.4k iOS lines, while iOS still lacks an inbox and Changes.

---

## 3. Target users and jobs to be done

**Inferred primary user** (H1, R1): a solo senior developer or "agent power
user" who:

- pays for several agent subscriptions (the quota view supports up to eight
  accounts per provider, `internal/providerquota/manager.go:341-367`);
- owns always-on hardware such as a Mac mini or Linux box;
- runs several agents in parallel;
- wants to check in and steer from a phone.

The live account matches this: 5 machines, 2 OpenAI Pro plus 1 Claude Max
account, 54 cards.

**Jobs, and how well they are served today**

| # | Job | Served? |
| --- | --- | --- |
| J1 | "Hand off a coding task and walk away without it dying." | Mostly. Graceful-restart resume failed in practice until the uncommitted checkpoint fix; there is no sleep prevention. |
| J2 | "Know when something finished, failed, or needs me — without watching." | **No** (§5.4). |
| J3 | "Answer or redirect an agent from my phone in under a minute." | Partly. Android works in-app; iOS doesn't; there are no actionable notifications. |
| J4 | "Review what the agent did and ship it safely." | Partly. Changes and diffs exist, but Review is self-declared, project mode mixes agents' edits, Validate can pass while checking nothing, and PRs are GitHub-only via `gh`. |
| J5 | "Use my best subscription/machine for each task." | Data exists (quota plus `provider_account_key` per card), but nothing dispatches on it. |
| J6 | "Run recurring maintenance agents." | Schedules exist; success means "turn ended without error". |
| J7 | "Keep one view of all projects across machines." | Replicated boards exist, with a recent multi-day silent stall. |

**Non-target today**: teams (no multi-user model), enterprise (no SSO, audit or
policy), Windows users, and people who want a web UI or hosted compute.

---

## 4. Positioning

**Current (facts).** The headline is consistent across README, website and
Homebrew. The framing drifts:

- the landing page says "The workspace you wanted for **Codex**";
- the README says a workspace for five harnesses;
- `hugo.toml` says "headless coding agents across your machines".

The README also mixes marketing with implementation detail: route racing,
causal frontiers, `placementRevision`, board-retirement CLI flags and
re-enrollment recovery (`README.md:33-46,171-204`). That contradicts
`CONTRIBUTING.md:89-91`.

**Assessment.** "Close your laptop, keep your agents running" no longer
differentiates. Vendors now say the same thing (§9). What competitors can't
easily copy is a combination:

- **neutral**: any vendor's agent, including open models;
- **yours**: runs on hardware and credentials you control; the control plane
  never stores transcripts;
- **durable**: every task is a permanent conversation on a shared board with
  schedules, across machines.

**Proposed positioning** (H2; must be tested, R5): *"The control room for the
coding agents you already pay for — on your own machines, across all of them,
with nothing stored in anyone's cloud."*

The privacy clause is only honest after the relay is end-to-end encrypted
(§8, Next).

---

## 5. Current-state findings by area

Severity: **High** blocks the promise or adoption. **Med** degrades a core
journey. **Low** is polish.

### 5.1 Onboarding and activation

- **High — Closed default gateway, with no path to access.**
  - Evidence: `config.go:93-102`, `auth.go:414`; the CLI (`cli.go:736`,
    `daemon_ops.go:408`), Mac (`DieterEndpoint.swift:36`), Android
    (`DieterRepository.kt:195`) and iOS (`IOSStore.swift:83`) all default to
    `gateway.getdieter.com`.
  - The CLI polls until the 10-minute enrollment expiry, then reports
    "daemon enrollment expired".
  - Impact: almost every organic visitor dead-ends at step 2. Whether this is a
    deliberate private beta is decision **D1**.
- **High — The Homebrew caveat prints `dieter setup /path/to/git-project`.**
  Setup rejects positional arguments (`daemon_ops.go:418`) and the caveat omits
  `--gateway`.
- **High — Self-hosting is the only open door, and it is an operator's
  runbook.** It needs a public domain, TLS, a GitHub OAuth app, a reverse proxy,
  secrets and optionally coturn. The signed bundle "imports the observed running
  deployment" (`deploy/gateway/README.md:125-127`).
- **Med — Setup forces optional screen permissions.** It calls them "Required"
  and exits non-zero if they are declined (`daemon_ops.go:578`). The docs say
  screen hosting "does not prevent agent work". There is no `--skip-screen`.
- **Med — The Mac permission gate returns on every launch.** It demands
  Accessibility and Screen Recording before showing any value, and "Skip for
  Now" is held only in memory (`RequiredPermissions.swift:30,61-63`).
- **Med — No preflight for agent login.** `doctor`
  (`internal/cli/doctor.go:23-111`) checks git, node, npm, tmux and storage, but
  not:
  - enrollment;
  - gateway reachability;
  - the compatibility floor;
  - service health;
  - host sleep settings;
  - whether each agent is installed and logged in.

  `harness list` has no "ready" column. An unauthenticated agent is selectable
  and only fails at runtime.
- **Med — Client-first dead ends.**
  - Mac shows red text: "No Dieter daemons are enrolled for this account."
    (`DieterStore+Connection.swift:101-105`).
  - The empty board state has no action (`BoardView.swift:113-124`).
  - Android says "Start Dieter on an enrolled machine…" (`ScreenShared.kt:124`).
  - None of them link to install instructions.
- **Med — Private model defaults are shipped.**
  - OMP defaults to `tailscale/glm-5.3-flash-exl3`
    (`config/harnesses.yaml:176`).
  - Pi's only named model is `box/qwen3_6_27b` (`:155`).
  - Auto-titles use `gpt-5.3-codex-spark` (`internal/app/conversation_creation.go:72`).
  - New users get routes that cannot work for them.
- **Measured journey (Mac, from code; not timed).** About 7 commands, 2 GitHub
  sign-ins, a timed machine-code approval, up to 4 OS permission prompts, and
  about 15 new concepts (gateway, allowlist, daemon/machine, enrollment,
  service, project, checkout, board, lane, card vs chat, harness,
  model/effort, worktree vs project, execution owner, route).

### 5.2 Core agent workflow

- **High — Status is not ground truth.**
  - The daemon moves cards only on start (to Running) and on Done
    (auto-archive). Review is the agent's own claim.
  - Live: 3 of 6 Running-lane cards were `idle`, i.e. blocked or unattended,
    one of them since 2026-09-25.
  - Impact: the board can't be trusted as a status view, which is the product's
    main visual promise.
- **Med — Questions aren't first-class.**
  - Claude's AskUserQuestion pause has no answer RPC or UI; there is no
    approval RPC among the 132.
  - Structured multiple-choice questions are lost.
  - "Needs you" states in all clients never fire.
  - `tour.md`'s claim that "questions waiting for your answer continue to need
    attention" is false.
- **Med — Interrupted work looks finished.**
  - A crash-interrupted turn becomes `idle` with only an abort chunk in the
    transcript (`internal/store/conversation.go:592-596`).
  - Android's retry banner only appears for `failed`.
  - There is no "Continue" action and no retry command.
- **Med — "Steer" is cancel plus queue** (`ConversationComposer.swift:51-55`).
  The in-flight turn is aborted rather than redirected. It's acceptable if it
  is labelled honestly.
- **Med — Background work cannot wake an agent.**
  - Registered processes (at most 8 per daemon, output kept 30 minutes,
    `remoteexec/manager_unix.go:28-40`) don't wake an idle conversation.
  - A managed daemon update kills them.
  - "Watch CI, then fix it" needs a human.
- **Low–Med — Attachments reach the agent only as file paths** appended to the
  prompt (`local-attachments.mjs:21-22`), not as model image inputs. Whether
  this hurts quality depends on each harness's tools (H3).
- **Low — Token usage is unreliable.** 35 of 54 cards have no usage data, and
  14 of the 19 that do are flagged partial. Cached and uncached input aren't
  split, and there is no cost figure. One card shows 1.06 billion input tokens,
  which is misleading without a cache split.

### 5.3 Review, Git and shipping

- **High — Project mode, the mode actually used, can't attribute changes to an
  agent.**
  - 53 of 54 live cards ran in project mode on `main` in one dirty checkout,
    with three concurrent agents.
  - A commit can capture another agent's half-finished edits.
  - Worktree merges are blocked whenever any project-mode agent is active
    (`gitops/manager.go:99-105`).
  - Worktrees have no setup hook (dependencies, `.env`) and aren't cleaned up on
    archive.
- **Med — Validate can pass while checking nothing.** It loops over an empty
  `ValidationCommands` list (`gitops/manager.go:636-640`), yet `push_base`
  "publishes validated" results.
- **Med — The review loop is split across clients.**
  - Android can send line comments to the agent
    (`WorkspaceChangesScreen.kt:480-486`); Mac stores comments but can't send
    them.
  - PR checks and reviews refresh only when the user asks.
  - PRs are GitHub-only via the host's `gh` CLI. A GitLab remote reports "GitHub
    CLI is not authenticated".
- **Low** — Commits force `--no-gpg-sign`. iOS has no Changes or Git at all.

### 5.4 Notifications, attention and cross-device continuity

- **High — No push anywhere.** There are no APNs or FCM tokens and no
  device-registration RPC.
  - Android keeps a `remoteMessaging` foreground service with a partial wake
    lock, defaulting to **Live** (`BackgroundSyncMode.kt:19`).
  - iOS suspends when backgrounded (`DieterIOSRootView.swift:85-91`).
  - Mac notifies only while the app runs.
- **High — The notification vocabulary doesn't match the daemon.**
  - Mac only ever notifies on failure. The toggles are fake. Clicking a
    notification can't open the conversation, although Settings says it does
    (`DieterSettingsView.swift:1056`).
  - The notification body is the raw runtime string ("Status changed to
    failed").
  - Android says "Chat finished" for crashes and user stops.
  - Board-card failures, and all scheduled runs, notify nobody by default.
- **Med — "Needs attention" is computed differently on each surface.**
  - Mac Inbox: unread replies.
  - Island (the notch overlay): running plus Review lane.
  - Menu bar: Review lane.
  - Sidebar badge: running.
  - Failures count as attention nowhere.

  The daemon's unread-reply receipt (`responseSeq > seenResponseSeq`) is the one
  signal that works across Mac and Android.
- **Med — iOS breaks continuity.** It never calls `MarkConversationRead`, keeps
  drafts and outbox only in memory, and caps transcripts at 240 messages.

### 5.5 Projects, boards, multi-machine and collaboration

- **High — Replication failures are silent and strict.**
  - Removing a field (`commentCount`) made already-signed summaries invalid,
    which blocked peer sync on one host from 2026-09-25 to 2026-09-28. The only
    evidence was a log line.
  - No native client calls `GetPeerStoreStatus`.
  - The user worked around it by creating duplicate boards. Live:
    `project list` still shows 3 boards named "Main" in this project, and
    `peer status` shows 1 conflict.
  - Impact: this directly damages the "one shared board" promise.
- **High — Work is stranded on dead or revoked hosts.** Conversations can't be
  transferred or re-homed (`docs/peer-store.md`: "no transcript or task
  transfer is implied"). Transcripts are unreadable while the owner host is
  offline.
- **High (business) — No multi-user model.** One GitHub ID per account; no
  invites, roles, assignees or shared boards; board comments removed. That is
  consistent with the solo target user, but it rules out team revenue for now
  (R1).
- **Med — Protocol mechanics leak into the product.**
  - `board retire --revision REV --operation ID`.
  - Vector clocks in the public `Board` message (`dieter.proto:518-530`).
  - `peer put` with raw JSON to resolve conflicts.
  - The Mac conflict sheet titles sections with raw field suffixes.
  - Eight different "make it go away" verbs (archive, retire, remove, revoke,
    unenroll, detach, delete, consolidate).
  - Empty-board retirement alone took 5,603 inserted lines across 66 files
    (`7e369c48`).
- **Med — "Global" prompt templates are per-daemon.**
  `$DIETER_HOME/settings.yaml` holds them. The Mac editor writes to the selected
  machine only, so agent behaviour silently differs between hosts.
- **Med — Second-machine trap.** `project open` on a second host creates a new
  project identity; the fix is `project consolidate`.
- **Med — The Mac Archive is unreachable.** No code sets `section = .archive`.
  Search excludes archived items (`TaskSearchIndex.swift:32`). Yet the
  delete-project dialog says "You can restore it from Archive"
  (`DieterRootView.swift:1189`), and board deletion is blocked by archived cards
  the user can't see.
- **Low** — Labels are scoped to a board, not a project. Android can restore
  boards but not retire them.

### 5.6 Reliability and trust

- **Facts on failure handling**:
  - A graceful restart suspends and resumes turns. A turn without a
    continuation is marked interrupted and never replayed
    (`turn_recovery.go:20-24`). This failed in practice on 2026-09-28: a 1 MB
    checkpoint was truncated at 64 KB (the fix is uncommitted,
    `docs/harness-checkpoint-shutdown-2026-09-28.md`).
  - Stuck workers are cancelled after 30 s without heartbeats.
  - 429s and quota exhaustion fail the turn, with no wait-until-reset.
  - No code keeps the host awake; nothing uses `IOPMAssertion`,
    `systemd-inhibit` or `caffeinate`.
- **Risk — Release cadence makes the fragile path frequent.** About 6
  releases a day, forced floors and automatic daemon updates mean the
  suspend/resume path runs constantly, and every update kills background
  processes.
- **Risk — Compatibility floors drift between policy and production.**
  - The repo policy says `0.4.325-dev.0`
    (`deploy/gateway/compatibility-policy.json`).
  - The live gateway enforces `0.4.309-dev.0`.
  - iOS reports `MARKETING_VERSION = 0.1.0` (`project.pbxproj:129`), so a
    source build or a default TestFlight upload is below the floor.
- **Risk — Single VPS.** The gateway, TURN and relay run on one VPS. The TURN
  quota was exhausted once (`docs/investigations/2026-09-21-relay-fallback.md`).

### 5.7 Desktop UX (macOS)

- **Navigation.** There are 10 sections; boards sit two levels deep inside
  expandable projects. Terminals and Screens sit at the same level as Inbox and
  Chats. The sidebar mixes projects, machines with latency figures, and
  provider quotas.
- **Duplicated entry points:**
  - three task-creation forms with different required fields;
  - two ways to open a project;
  - "Add a Git project" twice.
- **Command palette.** 10 fixed commands, none for Screens, Settings, Changes,
  Machines or Archive. There are no ⌘1–9 section shortcuts.
- **Composer.** Rich (attachments, provider/model/effort, queue, ↑ recall), but
  there are no slash commands and no @file mentions.
- **Settings.** "General" is a catch-all: 8 visual designs, store path, a
  "Sandboxed" row, a disabled "Open at login" placeholder, and "Archive
  project…".
- **Stale docs and screenshots.**
  - `workspace.md`, `configuration.md` and `docs/conversation-workspace.md`
    point to a toggle removed on 2026-09-23.
  - Public screenshots predate Inbox.
  - One reference screenshot renders a blank sidebar.
- **Minimum window width is 1080 px**, which rules out half-screen use on
  laptops.

### 5.8 Mobile UX (Android, iOS)

Parity summary: ✓ yes, ◐ partial, ✗ no.

| Capability | Mac | Android | iOS |
| --- | --- | --- | --- |
| Inbox / needs attention | ✓ | ✓ (default tab + widget) | ✗ |
| Read receipts | ✓ | ✓ | ✗ |
| Boards | ✓ | ✓ | ◐ list |
| Changes / diff / commit | ✓ | ✓ | ✗ |
| Schedules, labels, project admin | ✓ | ✓ | ✗ |
| Background processes | ✓ | ✗ | ✗ |
| Remote screen, terminals | ✓ | ✓ | ✓ |
| Alerts with app closed | ✗ | foreground service only | ✗ |
| Actionable notifications | ✗ | "Mark done" only | ✗ |
| Share into Dieter | — | ✗ | ✓ |

- **High — iOS can't deliver "pick up from your phone".** It is a viewer
  without alerts, and possibly locked out by the version floor.
- **Med — The Android composer is unfriendly for quick follow-ups.**
  - The pills read "Mock / Mock / Low" with no labels.
  - The placeholder says "Message the local agent…" although the agent is
    remote.
  - There's no dictation button and no quick-reply chips.
  - Stop is one tap with no confirmation, next to the overflow menu.
- **Med — Android Quick Task → "More options" loses the typed text.**
  Reproduced; the fix is uncommitted.
- **Med — Distribution.**
  - A self-updating sideloaded APK (`REQUEST_INSTALL_PACKAGES`) can't go on
    Play as-is.
  - iOS App Store preparation is pending a privacy policy, a review contact and
    a reviewer environment (`apps/ios/APP_STORE_PREPARATION.md:151-170`).
  - Google's announced sideloading developer verification (external,
    unverified here) is a looming risk.

### 5.9 Accessibility

Counts are from grep over non-test source, so they are estimates.

**Mac**
- 138 `accessibilityLabel`s; about 38 of 58 icon-only buttons rely only on
  `.help` tooltips.
- The selected sidebar item isn't announced, and badges are read as bare
  numbers.
- 515 fixed font sizes, 92 of them 9pt or smaller.
- No Increase Contrast or differentiate-without-colour support; Reduce Motion
  and Reduce Transparency are honoured.

**Android**
- 103 `contentDescription`s across 254 `Icon(` calls.
- 1 `Role`, 0 live regions, 0 custom actions.
- Card semantics tell TalkBack users to "hold and drag", and swipe-only actions
  have no accessible alternative.

**iOS**
- Mostly semantic text styles, but no accessibility audits.

**All platforms**
- No localization.
- No automated accessibility checks, although the e2e harness could host them.
- This fails "keep both native clients accessible and adaptive" in `AGENTS.md`,
  and will fail any enterprise VPAT review.

### 5.10 Settings and administration

- **Settings live in five scopes:** gateway `.env`, per-daemon YAML,
  replicated peer fields, gateway quota settings, and client-local. The user
  can't tell which scope an edit affects.
- **The gateway has no admin plane.**
  - The admin docs are a proposal (`docs/gateway-admin-implementation-plan-2026-09-22.md:3`).
  - Adding a user means re-rendering and redeploying.
  - There is no session list and no remote device revoke.
  - Sessions last 30 days.
  - A global cap of 1,000 auth records (`auth.go:38`) and a per-peer rate limit
    behind a proxy (`render.py:112`, `PROXY_MODE=1`) would bite a public hosted
    gateway (H4).

### 5.11 Integrations

- **Exist:** GitHub PR create/view/merge and checks, via the `gh` CLI on each
  host (`internal/scm/github.go`); an agent-facing CLI with a skill file;
  harness-native MCP (not managed by Dieter).
- **Missing:** GitLab or Bitbucket, issue import (GitHub, Linear, Jira),
  outbound webhooks, Slack, an MCP server exposing Dieter, calendar-driven
  schedules.
- **Assessment.** The CLI plus skill file is a genuine strength: agents already
  drive the board. An outbound "attention" webhook and GitHub issue → card
  would carry the most leverage per unit of effort (R1).

### 5.12 Security and privacy

- **G1 High — One compromised host compromises every host.**
  - A daemon's peer proof yields an account principal (`auth.go:240-262`).
  - With it, a daemon can exchange tokens for any sibling daemon
    (`service.go:502-512`).
  - `--machine` signs with `identity-key.pem`, which is owned by the same user
    the agents run as.
  - So any agent (unsandboxed, allow-all) can `remote exec` on every machine in
    the account. This is by design (the board instructions tell agents to use
    the CLI), but it is not disclosed as a fleet-wide trust boundary.
- **G2 High — Full-auto is neither disclosed nor configurable.** Android's
  creation copy says "full access to this project's files"
  (`CreationScreens.kt:344`), which understates it.
- **G3 High (for a hosted offering) — The gateway operator can reach every
  customer.**
  - One gateway signing key roots every token.
  - There is no rotation (`trust/tokens.go`, key ID fixed at
    `dieter-gateway-v1`).
  - The operator can read relayed payloads.
  - There are no terms, privacy policy, or data processing agreement.
- **G4 High — A lost phone or laptop can't be revoked on its own.** Revocation
  covers only the caller's own token. Sessions carry no device information.
  There is no app lock.
- **Med:**
  - No audit trail of who ran exec, a terminal, screen control or shutdown.
  - No host-side "being viewed" indicator on macOS or X11.
  - The loopback data plane is unauthenticated for other local users on shared
    Linux hosts.
  - No hard delete, retention policy or redaction.
  - The Mac session file is plaintext with 0600 permissions.
- **Keep:** no web UI, no telemetry, scope-less OAuth, cosign-pinned installs
  and updates, bounded relay, and "cancelling a transport never stops an
  agent".

### 5.13 Support and diagnostics

- GitHub Issues, Discussions and private vulnerability reporting are all
  disabled, yet Issues is the documented bug channel and the App Store support
  URL.
- There is no support bundle and no remote log retrieval.
- The daemon log never uses ERROR. In one week on the operator host there were
  45k WARN lines, 29k of them one benign hydration message, which buries real
  signals.

### 5.14 Packaging, pricing, monetization, analytics and retention

- **Pricing.** No pricing, plans or metering anywhere. The landing page says
  "No per-seat software license; model-provider and infrastructure costs
  remain yours". The hosted gateway is the only natural paid surface.
- **Analytics.** None, which matches the privacy stance, but the stance is
  never stated to users. The result is no activation funnel, no failure rates
  and no retention signal outside dogfooding.
- **Retention loops.** Schedules (recurring value), the Android widget and
  Inbox exist. The strongest loop — "your agent finished; tap to review and
  ship" — is missing (§5.4).
- **Legal and diligence.** No CLA/DCO. About 40% of commits come from a second
  contributor via a corporate email. Check IP provenance before any commercial
  licensing, fundraising or acquisition (D5).

---

## 6. Prioritized gaps

Scored by user impact × business impact ÷ rough effort. P0 must be done before
any broader launch. P1 is next. P2 comes after validation.

| P | Gap | Why it matters | Rough effort |
| --- | --- | --- | --- |
| P0 | Closed gateway with no access path; wrong Homebrew caveat | Top-of-funnel is effectively zero | S (copy, error code, waitlist) → M (runtime admission) |
| P0 | No daemon-owned attention states; notifications misfire | Breaks J2, the core promise | M |
| P0 | Status isn't ground truth (Review is self-declared; blocked looks like working; interrupted looks idle) | The board can't be trusted | M |
| P0 | Full-auto and fleet-wide trust not disclosed; no privacy policy or terms | Informed consent, legal exposure | S |
| P0 | Release process strands clients (floor drift, iOS 0.1.0, 2 releases kept, no changelog) | Lockouts, no rollback | S–M |
| P0 | Replication stalls invisible; no support channel | Silent data divergence with nowhere to report it | S–M |
| P1 | No push; iOS has no alerts or inbox | "Pick up from your phone" false on iOS; Android battery cost | L (and needs an invariant change) |
| P1 | No harness/agent-login preflight; private model defaults | First task fails at runtime | S–M |
| P1 | Project-mode attribution; worktree ergonomics; Validate without checks | Unsafe shipping with parallel agents | M |
| P1 | One host = all hosts; no device revoke | Security objection #1 | M |
| P1 | Relay not end-to-end encrypted | Privacy claim not credible against Paseo and Happy | L |
| P1 | Questions and approvals not first-class; no actionable notifications | J3 unserved | M |
| P1 | Mac Archive unreachable; permission gate on every launch; stale docs | Perceived data loss, early drop-off | S |
| P2 | Background work can't wake an agent | CI/build loops need a human | M |
| P2 | Quota-aware dispatch and wait-until-reset | Unique to multi-subscription users | M |
| P2 | Accessibility pass | Compliance, inclusivity | M |
| P2 | Conversation re-homing and export | Dead-laptop recovery | L |
| P2 | Integrations (issue → card, webhook, GitLab) | Workflow fit | M each |

---

## 7. Recommended product principles

1. **The daemon is the source of truth for state.** Clients render daemon-owned
   states (finished, failed, interrupted, needs input, unread, blocked). They
   don't infer state from lanes or strings. One attention model feeds every
   surface.
2. **Never make the user wonder.** Every turn ends in an explicit, explainable
   state, with a next action (Continue, Retry, Answer, Review).
3. **Honest trust boundaries.** Say what an agent can do, what each enrolled
   host can do to the others, and what the gateway operator can see, at the
   moment of consent. Don't market privacy the architecture doesn't provide.
4. **Progressive power.** Core flows (Inbox → conversation → review → ship)
   come first. Terminals, screens, machine control, peer internals and
   retirement semantics are opt-in or one level down. Protocol mechanics
   (revisions, operation IDs, vector clocks) never appear in UI copy or default
   CLI flows.
5. **Activation before expansion.** No new surface area until a new user can
   reach a first successful turn without help.
6. **Neutral by design.** Treat every harness equally. Ship defaults any user
   can run. Detect readiness instead of assuming it.
7. **Stable by default, fast by choice.** Give users a stable channel. Raise
   compatibility floors only at real breaking cutovers, never faster than every
   client can update (App Store and TestFlight included).
8. **Privacy through local measurement.** Measure reliability and activation
   with local counters and opt-in, content-free reports, never third-party
   SDKs.

---

## 8. Roadmap

### Now (0–6 weeks): "Make the promise true for one user"

| Item | Contents | Depends on |
| --- | --- | --- |
| N1 Open activation | Machine-readable "not admitted" error with request-access/self-host guidance in CLI and apps; public waitlist; fix the Homebrew caveat; `setup --skip-screen` and treat screen permissions as optional; remember the Mac permission skip and request per feature; guided "no machines yet" state with copyable commands and live detection | D1 |
| N2 Doctor 2.0 | Enrollment, gateway reachability, compatibility floor, service health, per-agent installed/authenticated, sleep settings (macOS) and linger (Linux); `harness list` readiness column; remove private model defaults | — |
| N3 Daemon-owned attention states | Add `interrupted`, `needs_input` (map the question pause) and a derived "blocked" (idle in Running beyond a threshold) to the runtime vocabulary; one attention model shared by Mac, Android and iOS | — |
| N4 Honest notifications | Mac: notify on completion (unread reply), real toggles, click opens the conversation, readable body text. Android: notify on any card turn end by default. iOS: `MarkConversationRead`, persist drafts and outbox | N3 |
| N5 Trust disclosure | Full-auto and fleet-scope disclosure at enrollment and first task; threat-model table in `security.md` (stolen phone, compromised host, compromised gateway, shared Linux host); privacy policy and terms for the hosted gateway | — |
| N6 Release discipline | Stable channel plus continuous channel; keep ≥10 releases; human changelog; floors only at breaking cutovers; derive iOS version from the canonical release; align production floors with policy | D2 |
| N7 Visible sync health and support | Surface `GetPeerStoreStatus` in the apps ("sync with X blocked since …"); `dieter support bundle` (versions, route, doctor, peer status, redacted log tail); re-enable Issues and private vulnerability reporting; demote the noisy WARN | — |
| N8 Small fixes | Reachable Mac Archive and retired boards; Validate warns when nothing is configured; update stale docs and screenshots; README back to a short introduction | — |

### Next (6 weeks – 3 months): "Close the loop away from the desk"

| Item | Contents | Depends on |
| --- | --- | --- |
| X1 Content-free push | APNs, FCM and UnifiedPush relay carrying only an opaque card reference; the client fetches over its authenticated route; Android defaults to "App only + push" | D3 (amend the gateway storage invariant to allow device tokens), N3 |
| X2 Actionable notifications | Inline reply, Continue, Retry, Mark done, open review | X1, N3 |
| X3 First-class questions | Answer RPC plus UI for structured questions; clients show them as "Needs you" | N3 |
| X4 Safe parallelism | Worktree default for board cards with a per-project setup script and auto-cleanup; per-card change attribution; "send review comments to agent" on Mac; PR check/review polling that queues a follow-up | — |
| X5 Blast-radius controls | Gateway principal kinds (daemon principals get peer sync, not exec, on siblings); per-host local capability policy (inbound exec, terminal, screen; allowed harnesses); session/device list with revoke and "sign out everywhere" | D4 |
| X6 End-to-end encrypted relay | Carry daemon TLS through the relay, as the WebRTC route already does | — |
| X7 Hosted-gateway admission | Runtime allowlist and invite codes; the first job for the gateway admin plan; lift the 1,000-record and per-proxy rate-limit ceilings | N1 |
| X8 Store distribution | Play flavour without the self-updater; iOS App Store submission (privacy policy, reviewer environment) | N5, N6 |
| X9 Accessibility pass | Labels, selected state, custom actions for swipe/drag, minimum text size, Increase Contrast, automated audits in e2e | — |

### Later (3–9 months): "Earn the right to charge"

| Item | Contents | Depends on |
| --- | --- | --- |
| L1 Hosted gateway paid tier | Managed relay and TURN, push, store apps, zero-config enrollment; self-hosting stays free | X1, X6, X7, N5, R5 |
| L2 Quota-aware work | Hold turns and schedules until quota resets; choose account or machine by remaining quota | N3 |
| L3 Process-exit wakeups | A process finishing can queue a system follow-up | — |
| L4 Integrations | GitHub issue → card; outbound webhook or Slack on attention; MCP server over the existing API; GitLab | R1 |
| L5 Re-home and export conversations | Move a card to another checkout or host; export transcripts | Peer-store design |
| L6 Optional approvals | Per-board "ask" mode routed to the phone (Claude only; Codex lacks approvals) | X2, R3 |
| L7 Audit log | Append-only operator/device/route/method/argv log with export | X5 |
| L8 Team tier (only if validated) | Shared projects across accounts, roles | R1, D4 |
| L9 Replication simplification review | Evaluate a home-daemon authority for shared records (the 2026-09-20 reassessment's recommendation) | Incident data from N7 |

**Critical dependency chain.** N3 → N4 → X1 → X2 is the core-promise chain.
X6 + X7 + N5 → L1 is the monetization chain. N6 must precede X8.

---

## 9. Competitive position

Sources were web-verified on 2026-09-28. Figures marked "2°" come from
secondary aggregators.

| Alternative | Model | Threat to Dieter |
| --- | --- | --- |
| **Claude Code** — cloud sessions, [Remote Control](https://code.claude.com/docs/en/remote-control), Routines, self-hosted environments | Anthropic cloud, or your machine controlled from Anthropic's apps; bundled in Pro/Max | High for Claude-only users: zero setup, "keep running after closing the laptop". Transcripts on Anthropic's servers. |
| **OpenAI Codex** — app, cloud, [remote hosts](https://learn.chatgpt.com/docs/remote-connections) | OpenAI containers, or paired Mac/Windows/SSH hosts steered from ChatGPT mobile | High for Codex-only users. Same "host must stay awake" constraint as Dieter. |
| **Cursor** — cloud agents, [My Machines](https://cursor.com/blog/self-hosted-machines) | Your worker; the agent loop and transcripts stay in Cursor's cloud | Medium: multi-model but cloud-controlled. |
| **GitHub Copilot** agent / Agent HQ | Actions sandboxes, multi-vendor, PR-native | Medium for GitHub-centric teams. |
| **[Paseo](https://github.com/getpaseo/paseo)** | Own-hardware daemon; encrypted relay; iOS, Android, web, desktop, CLI; voice; many agents; Apache-2.0; ≈18.8k★; paid Hub | **Highest.** Near drop-in substitute for Dieter's user, with better distribution and end-to-end encryption. |
| **[Happy](https://github.com/slopus/happy) / [Happier](https://github.com/happier-dev/happier)** | Own-hardware, end-to-end encrypted self-hostable relay, mobile, voice; MIT; ≈23.9k★ | High on the mobile remote-control job. |
| **[Conductor](https://www.conductor.build/pricing), [Superset](https://github.com/superset-sh/superset), Nimbalyst** | Local worktree orchestrators, now adding cloud and mobile; $20–60 per seat | Medium: desktop parallelism and review UX benchmarks. |
| Vibe Kanban, Terragon | Backing companies [shut down](https://www.vibekanban.com/blog/shutdown) in 2026 | A warning: free-user-heavy agent orchestrators struggled to monetize. |

**Where Dieter is differentiated** (the first point is from docs review, not
exhaustive):

- Shared projects and boards replicated across a user's machines with no central
  store.
- Every card is one durable conversation, plus authoritative schedule
  occurrences.
- Native Mac and Android as first-class clients, plus remote screens with
  explicit control handoff.
- Headless Linux hosts.
- Normalized multi-account quota.

**At parity:** worktrees, diff review, schedules, mobile steering.

**Behind:**

- distribution (no stores, 5★);
- end-to-end encrypted relay;
- push notifications;
- voice;
- web or Windows clients;
- issue/Slack triggers;
- setup effort compared with one `claude remote-control` command.

**Durability** (H5):

- "Keep running with the laptop closed" and mobile steering are already
  commoditized.
- Vendor neutrality and "no third-party control plane" hold up against vendors
  but not against open-source peers.
- Against peers, Dieter can only win on *execution quality* of the board and
  durable-record model, and on multi-machine continuity.

**Platform risk** (H6, unverified): vendors could restrict third-party
orchestration of consumer-subscription CLIs.

---

## 10. Success metrics

Dieter has no analytics. Principle 8 means counting activation and reliability
**locally on the daemon** (surfaced through `dieter status` and the apps), with
optional content-free aggregate reports. The gateway can already count
admissions and enrollments without content.

| Area | Metric | Initial target (to calibrate) |
| --- | --- | --- |
| Activation | Share of admitted accounts reaching a first successful turn within 24 h | ≥60% |
| Activation | Median time from install to first successful turn (Mac, agent already logged in) | ≤15 min |
| Activation | Setup/doctor failure reasons, by category | Tracked; top reason <20% |
| Core loop | Turns ending in an explicit daemon state (finished/failed/interrupted/needs input) | 100% |
| Core loop | Running-lane cards that are actually running | ≥90% |
| Core loop | Median delay from attention event to the user opening it (push era) | ≤10 min |
| Reliability | Turn failure rate by cause (auth, rate limit, stall, restart, harness) | Trend down release over release |
| Reliability | Restart-suspended turns successfully resumed | ≥99% |
| Reliability | Replication stalls longer than 1 h, and p95 stall duration | 0 undetected; p95 ≤15 min |
| Trust | Users with notifications enabled; share of hosts with inbound exec/screen disabled (after X5) | Tracked |
| Retention | Weekly active operators (≥1 turn per week); turns per active operator per week | Establish a baseline |
| Retention | 4-week retention of activated accounts | ≥40% (hypothesis) |
| Retention | Successful schedule occurrences per week, split by *task outcome*, not just "turn ended" | Tracked |
| Business | Waitlist sign-ups; conversion from waitlist to activated; stated willingness to pay (R5) | Tracked before L1 |

---

## 11. Decisions: owner-level and research-level

**Owner decisions** (strategy or invariant changes; not researchable):

- **D1.** Is `gateway.getdieter.com` a private beta or a public service?
  - A private beta needs only honest messaging and a waitlist.
  - A public service needs terms, privacy policy, admission management, capacity
    and on-call.
- **D2.** Release policy: stable channel, retention count, and when floors may
  rise.
- **D3.** Amend the gateway storage invariant to allow opaque push tokens.
  Required for X1.
- **D4.** Revisit "binary full access, no scopes" in `AGENTS.md` enough to
  allow:
  - principal kinds (daemon vs user);
  - host-local capability policies;
  - possibly read-only mobile sessions.

  Required for X5 and L8.
- **D5.** IP diligence and contributor agreements before any commercial
  offering.
- **D6.** Scope freeze: pause new screen-sharing, theme and harness work until
  the P0 items ship.

**User research needed:**

- **R1 — ICP and team demand.** Is the buyer a solo multi-vendor power user, or
  a small team? Do teams need shared boards and roles, or just shared
  visibility?
- **R2 — Where agents run.** Mostly always-on hosts, or laptops (which makes
  sleep the leading cause of stuck work)? What share would enroll CI or shared
  boxes (which raises the stakes of G1)?
- **R3 — Autonomy.** Do users accept full-auto by default? Do they want phone
  approvals for push, deploys and destructive commands?
- **R4 — Mobile.** Glance-and-triage or act-and-ship? iPhone share of the ICP?
  Tolerance for Android's persistent notification?
- **R5 — Willingness to pay.** Hosted gateway vs self-hosting vs free end-to-end
  encrypted peers (Paseo, Happy) — price sensitivity at $5–10 per user per
  month.
- **R6 — Multi-machine boards.** How much do users value boards shared across
  machines, versus per-machine boards? This decides whether leaderless
  replication earns its complexity.
- **R7 — Workspace mode.** Would users accept worktree-by-default for board
  cards? What setup does each project need?
- **R8 — Feature usage.** Usage share of Terminals, Screens and remote exec,
  which decides whether to demote them.
- **R9 — Notification granularity.** Notify on every completion, or only on
  needs-you and failures?

---

## 12. What not to build

- **A hosted agent runtime or cloud sandboxes.** Vendors own that market and
  bundle it into subscriptions. Dieter's edge is *your* hardware.
- **A web UI.** It stays out of scope under the invariants and would add an
  attack surface. Mobile and native clients cover the job.
- **More screen-sharing performance work** (codecs, FEC, latency tuning) before
  P0 is done. It already takes a disproportionate share of effort and code
  relative to its likely usage (R8).
- **New harnesses** before harness readiness detection and a conformance suite
  exist. Each harness carries its own resilience shims and upstream-churn risk.
- **Team, enterprise, SSO, SCIM, SOC 2 or seat billing** before solo activation
  works and R1 shows demand.
- **Custom lanes or a general project-management tool** (sprints, estimates,
  board comments). Fixed lanes plus labels are right; board comments were
  correctly removed.
- **Token resale, a model proxy or LLM routing billing.** It adds liability and
  conflicts with "your credentials, your providers".
- **Third-party analytics or crash SDKs.** Use local counters and opt-in
  content-free reports (principle 8).
- **More replicated record types or peer-store features** until sync health is
  visible and L9 decides the replication model.
- **More visual designs, themes and launcher-icon variants** (8 already exist).
- **iOS remote-screen parity work** before iOS has an inbox, notifications and
  read receipts.
- **A Linux desktop client.** Headless Linux hosts plus Mac and Android clients
  cover the job.

---

## 13. Method and limits

- **Sources.** Eight parallel read-only reviews (onboarding/packaging, core
  workflow, projects/collaboration, reliability/notifications, macOS UX,
  mobile UX, security/privacy, competitive web research), followed by direct
  verification of every High finding cited above against `HEAD`. Live commands
  were read-only (`--help`, `list`, `show`, `status`, `peer status`, `quota list`,
  `healthz`).
- **Not done.**
  - No app was launched, so UI findings come from source, screenshots and
    tests, not observed runtime behaviour.
  - No setup was timed.
  - No user interviews.
  - No emulator or device runs.
  - Uncommitted in-flight fixes weren't evaluated.
- **Bias.** Live usage data comes from the maintainer's own account, the
  heaviest possible user. Competitive facts change monthly; recheck before any
  pricing decision.
