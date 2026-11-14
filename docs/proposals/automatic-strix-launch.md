# Plan: remove human-only Strix launch restrictions

Status: implemented. The inventory below records the original gates at the
source revision; the implementation removes their human-only decisions.

Agent-created cards and chats, draft starts, follow-ups and budgeted direct
channel wakes are enabled. Supplied local turn tokens are still validated.
Strix wake delivery is recorded after successful admission or queueing, and
concurrent wakes for one recipient are serialized. Its wake instruction includes
only addressed messages and preserves peer attribution. Headless live steering
remains unsupported. API, engine, scheduler and CLI route regression tests cover
the behavior. General trust, vault administration and mail rules remain intact.

The sequence below is retained as the design record; Changes 1 and 2 ship in
the same PR.
Source revision: `f5eeb246` (`origin/main` when inspected, 2026-11-14).

## Recommendation

Let an agent create, start and continue a Strix conversation through the
existing CLI and RPCs. Remove the provider-specific human requirement without
adding a replacement approval prompt, `allow_agent` flag or catalog setting.
The execution host must already have Docker and a configured Strix credentials
item, exactly as it does for an operator-started scan.

Ship explicit launches first, then remove the channel-wake veto with the
delivery handling described below. These are separate changes because a
headless Strix process has no live steering interface. Scheduled launches
already reach the engine without the human-only API check; cover that path
with a regression test rather than building another launch mechanism.

## 1. Exact inventory

There is **one `requireHuman*` helper, four call sites covering five RPCs,
and two additional Strix-specific wake vetoes**. There is no `requireHuman`
boolean in the protobuf schema, harness catalog, settings or clients.

| Gate                         | Location at the source revision                                                                                            | Current effect                                                                                                                                               | Planned change                                                                                                       |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `requireHumanForStrix`       | [internal/api/vault.go](../../internal/api/vault.go), line 215                                                             | Resolves the provider's adapter; a valid local agent turn gets `PermissionDenied` for Strix.                                                                 | Delete the human-only decision and helper; preserve supplied-token validation independently of provider.             |
| Create and start             | [internal/api/conversation_snapshots.go](../../internal/api/conversation_snapshots.go), line 136, `idempotentConversation` | Guards both `CreateCard` and `CreateChat` when `!defer_start` and either the card lane is Running or the scope is chat. Drafts are permitted.                | Allow immediate creation from an agent, including custom provider IDs backed by the Strix adapter.                   |
| Move draft to Running        | [internal/api/cards.go](../../internal/api/cards.go), line 94, `MoveCard`                                                  | Guards only the transition that dispatches the initial prompt (`InitialPromptSentAt == ""`). Moving an already-started card does not itself dispatch a turn. | Remove the human restriction; preserve local ownership, placement revision, admission and rollback on start failure. |
| Start draft                  | [internal/api/cards.go](../../internal/api/cards.go), line 132, `StartCard`                                                | Guards first-turn admission after receipt replay and card resolution.                                                                                        | Allow agent starts; preserve receipt replay, already-running behavior and the one-turn lease.                        |
| Start or continue by message | [internal/api/conversations.go](../../internal/api/conversations.go), line 83, `SendMessage`                               | Resolves the explicit provider or the stored card provider, then rejects an agent's Strix message.                                                           | Allow first messages, follow-ups and queued messages under the existing provider-selection rules.                    |
| Dispatch channel wake        | [internal/engine/channels.go](../../internal/engine/channels.go), line 260, `dispatchChannelMessage`                       | Excludes Strix from idle direct-recipient wake requests.                                                                                                     | Remove the provider veto when channel delivery is ready.                                                             |
| Execute delayed channel wake | [internal/engine/channels.go](../../internal/engine/channels.go), line 462, `wakeCard`                                     | Excludes Strix again when the delayed wake executes.                                                                                                         | Remove the second veto in the same change; retain ownership, archive, activity and wake-budget checks.               |

`IsStrixProvider` resolves the adapter runtime, rather than comparing the
provider ID to the literal `strix`. Tests must exercise an alias provider too.

The existing denial tests are in
[internal/api/strix_test.go](../../internal/api/strix_test.go),
`TestStrixTurnsFollowTheirSafetyRules`, and
[internal/engine/channels_replication_test.go](../../internal/engine/channels_replication_test.go),
`TestAWakeNeverStartsAStrixScan`. Replace their human-only assertions with
positive automation assertions while retaining the other checks.

## 2. Paths that already work, and requirements to retain

- **Scheduled execution is already an engine path.**
  [scheduler.go](../../internal/engine/scheduler/scheduler.go), lines 281 and
  299, creates a deferred card and calls `app.StartCard` directly. Neither
  [schedule API](../../internal/api/schedules.go) nor that engine path calls
  `requireHumanForStrix`. Worktree, model and credential checks still apply.
  The original integration proposal lists recurring scans as follow-up work,
  so this is a source-level finding, not evidence of a qualified live schedule.
- **Worktree-only execution:**
  [conversation_creation.go](../../internal/engine/conversation_creation.go)
  and [strix.go](../../internal/engine/strix.go), `requireStrixWorktree` and
  `prepareStrixTurn`, enforce it at creation and admission. Keep both checks.
- **Credential preparation:** `strixCredentials` reads the named vault item
  and audits it before admission; `strixTurn.apply` registers transcript
  redaction. This is harness credential access and currently does **not**
  require the initiating or scan conversation to have `VaultAccess`. Keep that
  model explicit: automation can invoke the configured provider without
  revealing its key or granting general vault access to the child. Preserve
  the allowlist, private HOME, per-turn config cleanup and no turn token in
  the Strix child environment.
- **Scan instructions and steering:**
  [turn_admission.go](../../internal/engine/turn_admission.go), line 228,
  passes the submitted message directly as the scan instruction and skips the
  coding-agent channel digest, channel hook and steering setup. Change the
  comments from “person's message” to “submitted instruction”; keep the
  headless capability restriction. Recovery in
  [turn_recovery.go](../../internal/engine/turn_recovery.go) must preserve it.
- **Completion and resume:**
  [turn_execution.go](../../internal/engine/turn_execution.go), line 333,
  moves a successful board scan to Review after its message queue drains.
  Keep queue ordering, cancellation cleanup, resumable session identity,
  runtime affinity and the one-active-turn invariant.

The API gate currently identifies callers through a local turn token. Remote
CLI calls do not carry that token, and
[DirectServer](../../internal/link/direct.go) constructs trusted remote
operator/device metadata instead of forwarding caller-supplied metadata.
Consequently this check is an inconsistent automation guardrail, not a proof
that a human initiated a scan. Remove the restriction through the supported
surface; do not implement token stripping or environment manipulation as a
workaround. Keep remote authentication and metadata handling intact.

## 3. Other human/operator restrictions

These are the related role checks found in the same search. They are not
additional Strix flags, and removing them is unnecessary for automatic scans.

| Restriction                                     | Code                                                                                                                                                                            | Disposition                                                                                                                                                                                                                |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Device trust mutations                          | [trustAPI.admit](../../internal/api/trust.go), line 38; [CLI.deviceMutation](../../internal/cli/rpc_device.go), line 61                                                         | Retain for initialize, sync, approve, revoke and recover. “Agent turns never change device trust” is binding in [invariants.md](../invariants.md#network-and-identity); changing it would first require a superseding ADR. |
| Daemon unenrollment                             | [daemonUnenroll](../../internal/cli/cli.go), line 489                                                                                                                           | Retain; it changes enrollment and device trust, outside scan dispatch.                                                                                                                                                     |
| Vault operator operations                       | [vaultOperatorOnly](../../internal/api/vault.go), line 75, checked in `vaultAdmit`                                                                                              | Retain for init, join, approve-member, remove-member, rotate and audit. These do not block Strix's daemon-mediated model credentials.                                                                                      |
| Mail read/organization and sender attribution   | [mailOperator / SendMail](../../internal/api/mail.go), lines 47 and 88                                                                                                          | Retain list/get/mark/delete denial and agent `--from` denial. One-way agent mail is a binding execution invariant; it is not a scan-launch requirement.                                                                    |
| Granting mail access to a child or schedule     | [capabilityCaller.grantMail](../../internal/api/vault.go), line 231; [schedules.go](../../internal/api/schedules.go)                                                            | Retain the existing capability rule. A Strix child needs no mail access to run.                                                                                                                                            |
| Agent `@here`, own project/inbox/claims         | [engine/channels.go](../../internal/engine/channels.go), [schema/channel.go](../../internal/replication/schema/channel.go)                                                      | Retain the attribution and recipient/ownership rules. A direct `--to CARD --wake` is sufficient for scan orchestration.                                                                                                    |
| Agent vault/mail/channel calls with `--machine` | [rpc_vault.go](../../internal/cli/rpc_vault.go), line 84; [rpc_mail.go](../../internal/cli/rpc_mail.go), line 49; [rpc_channel.go](../../internal/cli/rpc_channel.go), line 111 | Retain; these protect caller identity semantics when turn tokens are local. They do not prohibit remote card creation or starting a remote scan.                                                                           |

This proposal removes the Strix human-only launch decisions. A broader change
to trust, mailbox access or vault administration would need its own product
policy and, for binding rules, an ADR before implementation.

## 4. Implementation sequence

### Change 1: agent-created and agent-started scans

1. Remove `requireHumanForStrix` and the four decisions listed above. Preserve
   validation of a supplied local turn token through neutral caller validation
   on these entry points; removing a provider policy must not turn an expired
   or forged token into an accepted operator call. Reuse `turnCaller` /
   `VerifyTurn` rather than introducing a new permission system. Keep command
   receipt replay semantics explicit in the tests.
2. Replace the API test's three denial cases with successful creation,
   admission and continuation tests. Add the missing `StartCard`, `CreateChat`,
   deferred creation and provider-alias cases. Use a controlled runner and
   disposable vault credentials; verify failed prerequisites leave no active
   turn or unintended placement change.
3. Add CLI E2E coverage over local, direct TLS and relay routes. A real live
   parent-turn token must be present on the local CLI path; retain it in the
   test process for remote commands too, while using the existing remote
   metadata contract. Prove automatic creation and draft start, follow-up
   queueing, idempotent replay and one worker per admitted turn. Cover both
   card and chat creation. No real provider or external target is needed.
4. Add a Strix schedule regression using the existing scheduler test fixture:
   worktree, fake credentials and fake runner; one occurrence admits once and
   recovery does not replay an uncertain dispatch. No scheduler feature flag
   or new RPC is needed.

CLI usage (substitute the project and board IDs):

```sh
dieter card create --project PROJECT --board BOARD \
  --workspace worktree --provider strix --lane running \
  --provider-option credentials=strix \
  --provider-option max_budget_usd=5 \
  --title "Security review" \
  --prompt "Review this worktree for injection and access-control defects" \
  --format id
```

Use `--base-branch CODING_BRANCH` when reviewing committed work from a coding
card; a default new worktree does not inherit another card's branch or dirty
files. Use the default full scope for that seeded worktree: its recorded base
may already be the coding branch tip, making a changes-only scan empty. Test
the intended diff base separately before offering automated changes-only
reviews. Add `--machine MACHINE_ID` before `card` when selecting an execution
host and use a branch available in that host's checkout. Continue an existing
scan with `card send`; the Strix provider's scan mode, scope and targets remain
fixed after its first turn.

### Change 2: explicit budgeted channel wakes

1. Remove both Strix provider vetoes from `dispatchChannelMessage` and
   `wakeCard`. A direct message with `--wake` may start or resume an idle scan;
   ordinary project broadcasts and messages without a wake request must not
   become a new automatic-start mechanism.
2. Build a Strix wake instruction from the bounded, addressed peer messages,
   retaining their author/card identity and the existing “not from the user”
   treatment. Avoid the generic coding-agent “continue your task” suffix in
   `wakeCard`. Keep these messages out of live steering: Strix has no such
   transport. A message arriving during a running scan remains pending; do
   not invent automatic replay after every completion.
3. Handle delivery only after successful admission or durable queueing. The
   current `wakeCard` marks messages delivered **before** submission; a missing
   vault item or admission failure can otherwise consume the wake without a
   scan. Account for concurrent wakes and the already-active race through the
   existing message identity, queue and lease behavior. This prerequisite
   belongs with removing the veto, not in an unrelated channel refactor.
4. Replace `TestAWakeNeverStartsAStrixScan` with local and replicated-message
   assertions for one admitted wake, its instruction and attribution, failed
   admission retention, no duplicate after repeated sync, no live steering,
   and no wake for archived or foreign-owned cards. Keep hourly, chain and
   spacing bounds. Channel notices must never approve an action or speak for
   the user, as required by the execution invariant.

### Change 3: documentation and verification in each behavior change

Update the Strix section in [the CLI skill](../../.agents/skills/dieter-cli/SKILL.md),
[the harness guide](../../site/content/docs/harnesses.md#strix),
[the threat model](../threat-model.md#strix-security-scans), the comments in
`engine/strix.go` and `turn_admission.go`, and mark the old human-only design
in [strix-integration.md](strix-integration.md) as superseded. Describe
automated launches, the separate no-steering limitation, and which channel
wake behavior is actually shipped. Update the changelog. If command help
changes, regenerate the CLI reference.

Start verification with `mise exec -- just check-changed --dry-run`. During
implementation, use focused API, engine, scheduler and CLI route tests; run
the selected integration checks once at the end, plus `just fmt` and the
required lint checks. Runtime tests need rerunning only if runtime code is
affected. No schema or native UI change is expected, so code generation and
device flows are not expected for this removal.

Use temporary Dieter homes and fixture gateways throughout. For a final
headless smoke test, use the pinned Strix runtime, Docker, the scripted local
model in `tools/spikes/strix`, and a disposable local target. Verify start,
resume, cancellation and container/config cleanup; record unavailable
integration prerequisites as a failed gate. Never qualify this by scanning an
operator service or restarting the operator daemon.

Implementation verification on 2026-11-14 covers the API, channel wakes,
scheduler recovery and local/direct-TLS/relay CLI paths with isolated homes,
fixture credentials and fake runners. The real Docker smoke test is
unavailable on this host: `docker info` cannot connect because
`/var/run/docker.sock` is absent. No real-container start/resume/cancellation
or cleanup result is claimed by this change.

## Acceptance criteria

- A coding agent can create a running Strix card or chat, start a draft, and
  continue a scan using the supported CLI without a human-only error.
- Local, direct-TLS and relay routes admit the same operations and retain their
  authentication and replay contracts.
- An explicit channel wake can start an idle scan after Change 2; it preserves
  peer attribution, wake bounds and delivery on failure without live steering.
- A scheduled occurrence dispatches once, using the same Strix prerequisites.
- Worktree enforcement, model/credential validation, secret redaction,
  environment isolation, cancellation, resume and turn leases still pass.
- The implementation contains no Strix human-only helper, launch rejection or
  provider-specific wake veto, and the user guide and skill match the shipped
  behavior. Other identity and access rules remain explicit in the inventory.
