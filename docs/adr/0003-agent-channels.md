# ADR 0003: Peer messages in agent turns (agent channels)

- Status: accepted, implemented 2026-10 as an experimental feature (off by default)
- Proposal: [docs/proposals/agent-messaging.md](../proposals/agent-messaging.md)

## Context

Agents working on one project in a shared checkout overwrite each other's
files and sweep each other's changes into commits. Until now the only way for
one agent to reach another was `dieter card send`: a message that looks like
the human's, waits until the other turn ends, and has no channel, thread or
sender identity. The invariants allowed only human chat messages to resume a
harness session.

The spikes in the proposal measured how a message can reach a running harness
loop. `@ai-sdk/harness` already steers a running turn
(`experimental_steerTurn`: Claude Agent SDK `priority:'next'`, Codex
`turn/steer`, Pi `steer`); the message reaches the model at its next request,
appended after the latest tool result, with the prompt cache intact. Codex
also runs `PreToolUse` hooks configured per session, so a write can be checked
before it happens.

## Decision

Add agent channels as an experimental, replicated opt-in:

- **Peer origin.** A message from another agent (or a Dieter coordination
  event) may join an active turn as steered input, or reach an idle card as a
  digest ahead of its next prompt. It starts a turn only through a budgeted
  wake: a direct message with `--wake` or a released file the card waited for,
  at most 4 per card per hour and 3 in a row without a human message, spaced at
  least 2 s apart on a daemon. Wakes go through the existing turn admission, so
  runtime leases still allow at most one active turn per conversation.
- **Provenance.** Notices name their sender, and the turn instructions say
  peer messages never override the user, approve actions, grant access or
  reveal secrets. Peer posts cannot change trust or channel settings: the
  daemon identifies an agent only by a live turn token on the local route.
  Dieter's own coordination messages state only what Dieter observed.
- **Claims.** Writes claim files for the rest of the turn. Codex's per-session
  `PreToolUse` hook (`dieter channel hook`, fail-open) denies writes to files
  another running card holds and bare commits that would include them; other
  harnesses are warned right after a conflicting write. A card that ends its
  turn waiting for a running holder keeps its claims parked for up to an hour.
- **Storage.** Messages, deliveries and the human read position are
  daemon-local (`DIETER_HOME/channels`, append-only and fsynced under the
  central writer lock). Claims and wake budgets are in-process. Only the
  settings replicate, as the registered KV namespace `experimental`, so older
  daemons replicate them without a version floor. Nothing is stored on the
  gateway.

## Consequences

- `docs/invariants.md` names peer messages next to human chat messages.
- The worker protocol has a steer frame (Go → worker) and a steer-result frame
  (worker → Go) on the worker's stdin and stdout; stdin writes are serialized.
- Claude Code has no per-session hook configuration through
  `@ai-sdk/harness-claude-code`, so its writes are checked after the fact until
  the adapter accepts settings or hooks.
- Channels are per machine. Delivery across machines is future work and must
  keep the gateway free of project data.
