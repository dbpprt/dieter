# ADR 0007: Agent memory (per-project recall, saved memories and dreams)

- Status: accepted, implemented 2026-11
- Proposals: [agent-memory.md](../proposals/agent-memory.md) (choice and
  spikes), [agentmemory-rebuild.md](../proposals/agentmemory-rebuild.md)
  (scope); build plan:
  [agent-memory-implementation.md](../proposals/agent-memory-implementation.md);
  live test: [tools/spikes/memory-live](../../tools/spikes/memory-live/results/2026-11-27.md)

## Context

Every conversation starts from nothing. Agents repeat investigations other
conversations already finished, on the same or another machine, and rules a
person stated once are forgotten by the next task. Users asked for memory
"which I don't run but runs in Dieter", across their machines, switched on per
project and per task, with a way to keep it tidy.

Three spikes on 24,227 real observations compared an external memory server
(agentmemory), OpenViking and a built-in SQLite FTS5 index. The built-in index
matched the external server's keyword recall, needs no extra process,
language runtime or model key, and keeps all project data on the user's
machines.

## Decision

Memory is built into the daemon and off until a person turns it on for a
project.

- **Index per machine, never replicated.** Each daemon indexes the finished
  turns of the memory-enabled conversations it owns into
  `DIETER_HOME/memory/memory.db` (SQLite FTS5, `internal/store/memory`): the
  prompt, tool inputs and results, errors and the final answer, scrubbed of
  secrets and `<private>` blocks, bounded per observation and in total. It is
  derived data: deleting it loses nothing that a reindex cannot rebuild.
- **Recall across machines.** A search answers from the local index and asks
  the other daemons that own conversations of the project (at most 8, 3 s,
  over the roster-pinned peer carriers) with `local_only`; ranks are fused, not
  scores. Machines that do not answer are named in the result.
- **Saved memories replicate.** Curated memories (lesson, decision, fact,
  pattern) are replicated KV records in the daemon-only namespace `memory`.
  Only daemons write them; raw KV writes and generic peer writes are refused.
  Saving an identical lesson again reinforces it with per-daemon counters, so
  concurrent saves merge; a near-identical memory supersedes the old one.
  Retiring and superseding change a status, so history stays.
- **Switches.** `Project.memory_enabled` (replicated) is the default for new
  conversations; `Card.memory` switches one conversation (owner-local). A
  conversation uses memory when both are on and it is not a Strix scan.
- **Agent scope.** Agent turns get `memory_recall` and `memory_save`, bound
  to their own conversation's project, over the worker's private stdio; the
  CLI fallback `dieter memory search` is scoped the same way. Forget, reindex,
  switches, settings and dreams belong to people.
- **Dreams.** A dream reconciles a project's saved memories. It is an ordinary,
  visible conversation on the project's first board, labelled **Memory** (the
  label carries the procedure and grants nothing), with the fixed role
  `dreamer`, on the harness, model and account of the account-wide memory
  setting (one daemon-written KV record). Only a dreamer turn gets
  `memory_apply`: one batch of add, merge, supersede, retire and verify,
  validated all or nothing (at most N changes, a bounded share retired, every
  new memory cites cards of the project). It is applied at once (undo restores
  the prior versions) or staged for review. Dreams start on a schedule (gates:
  hours since the last dream, finished conversations, a time window) on one
  machine that every daemon computes the same way, or by hand.

## Consequences

- No new process, port, runtime or credential. The index adds a SQLite file
  per machine (about 0.75 KiB per observation).
- Recall was keyword search: paraphrases with no shared words could miss
  (eval E1: hit@3 0.95, hit@1 0.80). [ADR 0008](0008-memory-embeddings.md)
  adds local embeddings to the same index.
- Recalled text is untrusted input written by agents. The tools and the
  instructions present it as possibly outdated notes, never as instructions.
- A machine that is off is missing from recall until it is back; saved
  memories are always complete because they replicate.
- Dreams cost provider usage. They are off by default, bounded, visible as
  cards, and every change is attributable and undoable.
