# Implementation plan: Dieter Memory in one PR

Status: implemented 2026-11-27 ([ADR 0007](../adr/0007-agent-memory.md); live
test in [tools/spikes/memory-live](../../tools/spikes/memory-live/results/2026-11-27.md)).
Planned the same day, then extended with cross-machine memory, a per-task
switch, and dreaming · base `origin/main` `557184df`, which already
contains the code-reviewer PR #239; this PR follows its patterns (host tool,
switchable card field, account-wide reviewer setting, hidden reviewer
session) · design: [agent-memory.md](agent-memory.md) · scope:
[agentmemory-rebuild.md](agentmemory-rebuild.md) §5 · dreaming research:
[agent-memory.md §9](agent-memory.md)

**Assumed decisions** (confirm before starting):

- the built-in index;
- project memory off by default;
- a per-task switch whose default comes from the project;
- recall scoped to the conversation's project, across all of the account's
  machines;
- dreaming off by default and opt-in in settings. When on, it applies changes
  automatically, with validation and undo.

## 0. Acceptance criteria

1. **Project memory.** Switching "Project memory" on (CLI or any client)
   starts a bounded backfill on every daemon that owns conversations of that
   project. From then on, each finished turn of a memory-enabled task is
   indexed on its owner daemon within seconds.
2. **Per-task switch.**
   - A task (card or chat) has a Memory switch. It defaults to the project's
     setting at creation, can be changed at any time, and takes effect from
     the next turn.
   - Off means: no memory tools, no memory instructions, and the task's
     turns are not indexed.
   - Agents can't flip it.
3. **Across machines.**
   - Recall from any machine searches the indexes of every daemon that owns
     tasks in the project and merges the results.
   - Saved memories (lessons, decisions, facts, patterns) replicate to every
     daemon of the account, so curated knowledge also works offline.
   - Transcripts never move.
   - An unreachable machine gives a partial result that names it, never an
     error.
4. **Tools.** Memory-enabled turns on every harness except Strix get
   `memory_recall`, `memory_save` and a short instruction block. The CLI
   fallback `dieter memory search` covers harnesses that load host tools on
   demand.
5. **Dreaming.**
   - With dreaming switched on in Settings → Memory, a project's memory is
     reconciled by an agent session using the harness, model, effort and
     provider account configured there.
   - It runs as a visible task carrying the project board's **Memory** label,
     on one designated machine. It starts at most once per 24 hours and only
     after at least 5 new memory-enabled tasks have finished.
   - The dream merges duplicates, supersedes stale memories, retires
     contradicted ones and adds new ones, each citing source tasks. The
     result is validated before it is applied, recorded with prior versions,
     and can be undone.
6. **CLI parity.** `dieter memory …`, `dieter card memory`, `dieter project
update --memory` and `dieter memory settings|dream` work over local,
   direct TLS and relay routes. Every mutation that a person owns refuses a
   turn token.
7. **Projects with memory off** cost nothing: no database file, no indexing,
   no tools, no dreams.
8. **Evals.** E1 and E2 (§3) pass in CI. The E3 runs are recorded in the PR
   description.

## 1. Bounds and defaults

| Item                        | Value                                                                                                                                                                                                       |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local index                 | `DIETER_HOME/memory/memory.db` (SQLite FTS5, WAL), created when the first project is switched on                                                                                                            |
| Indexed fields              | Body ≤4 KB; final answer ≤8 KB; title ≤200 B                                                                                                                                                                |
| Never indexed               | Reasoning, `data-*` parts (including agent channel notices), Dieter host tools (`present_content`, background processes, `request_code_review`, `memory_*`), Strix tasks, tasks or projects with memory off |
| Per-daemon index cap        | 2M observations or 1 GiB. The oldest observations of archived tasks are evicted first. Digests and saved memories are never evicted by this cap                                                             |
| Saved memories (replicated) | ≤4 KB content; ≤20 files; ≤8 source tasks; ≤2,000 active and ≤10,000 total per project; TTL ≤3,650 days                                                                                                     |
| Search                      | Query ≤500 B; ≤10 tasks; ≤20 files; result ≤8 KB with truncation metadata                                                                                                                                   |
| Federation                  | ≤8 peer daemons per query; 2.5 s per peer and 3 s overall; ≤8 KB per peer answer; peers answer from their own index only (no onward fan-out)                                                                |
| Host-call frames            | Arguments ≤8 KiB (≤32 KiB for `memory_apply`); result ≤16 KiB; ≤4 in flight; 10 s timeout                                                                                                                   |
| Indexer                     | Coalescing queue of ≤1,024 task ids; one writer; newest-first backfill in batches of 500; hourly TTL and bounds sweep                                                                                       |
| Dreaming gates              | ≥24 h since the last dream, **and** ≥5 memory-enabled tasks finished since, **and** no dream of the project running or awaiting review; checked hourly on the designated machine                            |
| Dream limits                | ≤50 new tasks summarized in its brief; ≤200 active memories listed; ≤40 operations; retired plus superseded ≤25% of active memories; every add and merge cites ≥1 existing task of the project              |
| Defaults                    | Project memory off; the task switch follows the project; dreaming off; dream model = reviewer default (Claude Code, Opus); apply mode `auto`                                                                |

## 2. Changes by layer

### 2.1 Rules and docs first

- **`docs/adr/0007-agent-memory.md`:**
  - the index is derived and machine-local;
  - transcripts never move; saved memories replicate as validated KV
    records;
  - federated recall over roster-authenticated peer carriers;
  - project switch plus task switch;
  - what is never indexed;
  - person-owned mutations (forget, reindex, switches, settings, dream
    apply/undo);
  - dreaming runs as a labelled task with a fixed role;
  - bounds.
- **`docs/invariants.md`:** an "Agent memory" section that enforces the ADR,
  naming its tests.
- **`docs/threat-model.md`:**
  - memory poisoning;
  - secrets carried across tasks and providers;
  - cross-project leakage;
  - a peer daemon answering searches;
  - a dream as an autonomous writer;
  - mitigations: scrubbing, daemon-fixed scope, labelled untrusted results,
    validation gates, undo, a human-only apply in review mode.
- **`docs/architecture.md`:** add `internal/store/memory`,
  `internal/host/memory` and `internal/engine/memory_dream.go` to the
  package map.

### 2.2 Protocol (`just generate`)

`api/proto/dieter/v1/memory.proto` defines `MemoryService`:

| RPC                                          | Purpose                                                                                                                                                                                                                          | Turn token                                    |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `GetMemoryStatus`                            | Per project: enabled, tasks, observations, saved, last indexed, backlog, last dream, next dream eligibility; per daemon: database size, last error                                                                               | allowed                                       |
| `SearchMemory`                               | `{project_id, query, limit, files[], kinds[], local_only}` → `{memories[], hits[MemoryHit{card_id, machine, title, lane, harness, last_activity_at, message_id, snippets[], final_answer}], unreachable[], truncated, excluded}` | allowed; project forced to the turn's project |
| `SaveMemory`                                 | `{project_id, content, kind, files[], sources[], ttl_days?, replaces_id?}` → `{memory, similar_to?, superseded_id?, reinforced}`                                                                                                 | allowed; project forced; origin recorded      |
| `ForgetMemory`                               | Hard-delete one saved memory, or a task's index rows, or a project's rows                                                                                                                                                        | refused                                       |
| `ReindexMemory`                              | Rebuild this daemon's rows for a project                                                                                                                                                                                         | refused                                       |
| `GetMemorySettings` / `UpdateMemorySettings` | The account-wide memory and dreaming setting (§2.10)                                                                                                                                                                             | get allowed; update refused                   |
| `StartMemoryDream`                           | "Dream now" for a project, subject to the running/review lock but not the 24 h / 5-task gates                                                                                                                                    | refused                                       |
| `ApplyMemoryDream` / `DiscardMemoryDream`    | Approve or discard a dream's staged operations (review mode)                                                                                                                                                                     | refused                                       |
| `UndoMemoryDream`                            | Restore the prior versions a dream changed                                                                                                                                                                                       | refused                                       |
| `ListMemoryDreams`                           | Dream history per project: card, time, counts, status                                                                                                                                                                            | allowed                                       |

Other proto changes:

- **Project:** `Project.memory_enabled` and
  `UpdateProjectRequest.memory_enabled`.
- **Card:** `Card.memory` (owner-local, switchable, effective from the next
  turn) and `Card.memory_role` (`""` | `dreamer`, fixed at creation, set
  only by the dream scheduler or `StartMemoryDream`).
- **Creation:** `CreateCardRequest.memory` (optional; the default comes from
  the project).
- **`CardService.SetCardMemory`:** refuses a turn token. The pattern is
  #239's card-level reviewer switch.
- **`client.proto`:** mirrors the client-facing fields.

### 2.3 Local index: `internal/store/memory`

Unchanged from the first plan, plus federation and replication support.

| File          | Contents                                                                                                                                                                                                                                |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `db.go`       | Opened with `home.OpenSQLite`. Tables: `observations` (FTS5), `digests` (one per task), `memories` (FTS5 mirror of replicated saved memories), `memory_meta`, `cursors`, `recall_counts` (task id → times recalled; written in batches) |
| `mapping.go`  | Parts to rows, as in the spike: synthetic kind, tool, files; exclusions                                                                                                                                                                 |
| `scrub.go`    | `<private>` plus token regexes                                                                                                                                                                                                          |
| `query.go`    | OR query plus prefix terms plus a small synonym table; `bm25(title 2.0, body 1.0)`; saved memories first; tasks grouped with ≤2 snippets plus the digest's final answer; 8 KB packing                                                   |
| `merge.go`    | Merges local and peer answers by reciprocal rank (k 60) over each daemon's ranked task list, because BM25 scores aren't comparable between indexes. Ties go to the more recent task. Each hit keeps its machine                         |
| `memories.go` | Save rules (similar_to at Jaccard 0.5–0.9; supersede above 0.9 or with `replaces_id`; identical lesson = reinforce), applied to the replicated record (§2.5), then mirrored locally                                                     |
| `bounds.go`   | Caps and eviction                                                                                                                                                                                                                       |

### 2.4 Across machines

- **Who indexes what.** Each daemon indexes only the conversations it owns.
  The project switch replicates in the project record and the task switch
  lives with the task, so every owner daemon reaches the same decision on
  its own.
- **Federated recall** (`internal/host/memory/federation.go`):
  1. The daemon serving `SearchMemory` searches its own index.
  2. In parallel, it calls `SearchMemory{local_only:true}` on the other
     daemons that own tasks in the project. It learns them from the
     replicated card records' owner daemon, and limits the fan-out to 8.
  3. Calls go through `peersync.DialPeer`, the roster-pinned direct, WebRTC
     or relay carriers that synced folders use (`internal/daemon/folders.go`).
  4. Peers authorize daemon-identity callers from the account roster for
     `local_only` searches only. A turn token never travels.
  5. Answers are merged as in `merge.go`. Peers that time out are listed in
     `unreachable`.
  6. The relay stays an opaque tunnel, and the gateway stores nothing.
- **Replicated saved memories** (`internal/replication/schema/memory.go`):
  - KV namespace `memory`, daemon-only (the public KV API refuses it),
    validated on write and on ingest, like `reviewer-settings`.
  - Key: the memory id. Value: `{project, kind, content, files, sources,
status: active|superseded|retired, superseded_by, verified, confidence,
reinforcements{daemon: n}, expires_at, created_by{daemon, card,
harness, dream?}, updated_at}`.
  - Merge rules:
    - `reinforcements` is a per-daemon counter map, so concurrent
      reinforcements add up;
    - retire and supersede are status changes, so the history survives
      CRDT "deletion wins";
    - only a person's `ForgetMemory` deletes.
  - Every daemon mirrors the active memories of memory-enabled projects into
    its local `memories` table on ingest, so recall of curated knowledge
    works offline.
- **CLI:** `dieter memory search --machine X` asks X to run the federated
  search. `--local` restricts it to one daemon's index.

### 2.5 Per-task switch

- **Field:** `Card.Memory`, owner-local and switchable, like #239's
  `CodeReview`.
- **At creation** it takes the project's `memory_enabled`:
  - clients prefill a Memory toggle in the new-task and new-chat sheets
    when project memory is on;
  - the CLI takes `card create … --memory on|off` and `chat create …
--memory on|off`.
- **Effective rule,** in one function used by admission, recovery and the
  indexer: project memory on **and** task memory on **and** adapter not
  Strix.
- **Switching off** stops tools and indexing from the next turn. It does
  not delete rows; forgetting is a separate person-owned action.
- **Commands:** `dieter card memory CARD on|off` and the same for chats.
  Clients show the switch in the task's settings menu.

### 2.6 Indexer, recall hooks and engine wiring

- **`internal/host/memory`:** started only by `dieter serve`. It owns:
  - the indexer and backfill;
  - the hourly sweep;
  - the federation client;
  - the KV mirror;
  - the dream scheduler (§2.10).
- **`internal/engine` turn hooks:**
  - **Turn finished:** after `finish(...)` on every terminal path except
    suspension, call `Memory.TurnFinished(cardID)` when the effective rule
    holds.
  - **Admission and recovery:** set `MemoryEnabled`, `MemoryCommand` and a
    handler bound to the task's project.
  - **Dreamer tasks** also get the curation tool.
- **Deleting a task** deletes its rows. Archiving keeps them.

### 2.7 Harness bridge and runtime module

This mirrors `code_review.go` and `code-review.mjs`.

- **`internal/harness/memory.go`:**
  - `MemoryHandler` and `replyMemory`;
  - frame types `memory` and `memory-result`;
  - the `Request.MemoryEnabled`, `MemoryCommand`, `MemoryRole` and `Memory`
    fields, and `Output.MemoryCall`.
- **`internal/harness/runtime/memory.mjs`:**
  - **Tools:**
    - `memory_recall {query, limit?, files?}`;
    - `memory_save {content, kind, files?, sources?, ttlDays?}`;
    - for dreamer tasks only: `memory_apply {operations[]}`, where each
      operation is `add|merge|supersede|retire|verify`, each with sources
      and a reason (§2.10).
  - **Instructions:** the memory-discipline rules, plus the dream procedure
    pointer for dreamers.
  - **Mock turns** for E2: `mock-memory-recall`, `mock-memory-save`, and
    `mock-memory-dream <ops-json>`.
- **`runner.mjs`:** wires these the same way the code reviewer is wired.

### 2.8 API

- **`internal/api/memory.go`:** the `MemoryService` handler.
  - A turn token resolves to its task's project.
  - Person-owned RPCs refuse turn tokens.
  - `local_only` searches accept roster daemon identities.
- **Other handlers:** `projects.go` (`memory_enabled`) and `cards.go`
  (`memory` at creation, `SetCardMemory`).
- **Replication schemas:**
  - the project field `memoryEnabled`;
  - `memory` and `memory-settings` namespace validators;
  - the card field for `memory`, if it replicates. `CodeReview` is
    owner-local; keep the same.

### 2.9 CLI

- **`rpc_memory.go`:**
  - `status`, `search` (`--local`), `save`, `forget`, `reindex`;
  - `settings` (show, and set with
    `--dreaming on|off --harness --model --effort --account --run-on MACHINE --apply auto|review`);
  - `dream PROJECT` (start now), `dreams PROJECT` (list),
    `dream apply|discard|undo CARD`.
- **Card and project commands:**
  - `rpc_cards.go`: `card memory`, and `--memory` on card and chat create;
  - `rpc_projects.go`: `project update --memory`.
- **Turn refusals:** every person-owned command refuses inside a turn
  before it contacts any daemon.
- **Contracts and reference:**
  - `commands.go`;
  - `rpcCommand` in `help_contract_test.go`;
  - `instructions_contract_test.go` covers the memory and dreamer
    instructions;
  - the CLI reference regenerated.

### 2.10 Settings, the Memory label, and dreaming

**Settings.** `memory-settings` is one account-wide KV record, daemon-only
and validated, following `reviewer-settings` (`internal/replication/schema/memory_settings.go`,
`internal/store/kv/memory_settings.go`).

| Field                                                   | Default                                                                                                             |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `dreaming.enabled`                                      | `false`                                                                                                             |
| `dreaming.harness / model / effort / account`           | Claude Code, Opus, the model's default effort, unset (the harness's default account on the run-on machine)          |
| `dreaming.runOn`                                        | Unset, meaning the daemon that owns most of the project's memory-enabled tasks. One machine runs a project's dreams |
| `dreaming.minHours` / `dreaming.minNewTasks`            | 24 / 5                                                                                                              |
| `dreaming.window`                                       | `02:00–06:00` local time on the run-on machine                                                                      |
| `dreaming.apply`                                        | `auto` (or `review`)                                                                                                |
| `dreaming.maxOperations` / `dreaming.maxRetireFraction` | 40 / 0.25                                                                                                           |

**The Memory label.**

- When dreaming is first switched on for a project, Dieter adds a board
  label named **Memory** to the project's first board (or reuses one with
  that name). Its label instructions are the dream procedure below, and a
  person can edit them to steer dreaming.
- The label marks dream tasks and lets people filter them.
- **The label grants nothing.** Agents can set labels on their own cards,
  so the curation tool goes only to tasks whose fixed `memory_role` is
  `dreamer`.

**Scheduler** (`internal/host/memory/dreams.go`, under `dieter serve` only):

- Every hour, on each daemon, for each memory-enabled project whose dream
  machine is this daemon, it checks the gates in §1.
- When they pass, it creates the dream task:
  - on that board, lane Running, labelled Memory, with `memory_role:
dreamer`;
  - in an isolated **worktree**, so it can't change the project's checkout;
  - with the configured harness, model, effort and account;
  - titled "Memory dream · <date>".
- **Prompt:** a generated brief that is bounded and scrubbed. It contains:
  - the last dream's summary;
  - the new memory-enabled tasks since then (id, title, machine, lane,
    finish time, digest answer ≤300 chars), most-recalled first;
  - the active memories (id, kind, content ≤300 chars, sources, verified,
    reinforcements).
- **One dream per project at a time.** A dream state record in the
  `memory-settings` namespace (`dream/<project>`), written only by the dream
  machine, holds the running task and a review lock.

**Dream procedure** (default label instructions). It draws on Claude Code
Auto Dream's phases, Anthropic's "test notes against transcripts", and
OpenClaw's operation-based promotion:

1. **Orient:** read the brief and recall what exists.
2. **Gather:** for each new task, read what matters with
   `dieter card transcript ID --machine M`: decisions, corrections, fixes,
   failed approaches.
3. **Consolidate:**
   - one memory per topic or entity;
   - merge duplicates;
   - supersede outdated memories with the corrected text;
   - convert relative dates to absolute ones;
   - leave out what the code or git history already says, and transient
     state;
   - don't invent blanket rules.
4. **Verify:** check a sample of existing memories against their source
   transcripts. Mark each memory `verified` or unconfirmed, and retire what
   newer tasks contradict.
5. **Apply and report:**
   - one `memory_apply` batch;
   - a short final answer listing added, merged, superseded and retired
     memories with task links;
   - no code changes.

**Validation of `memory_apply`** (daemon side, all or nothing):

- At most 40 operations.
- Every add and merge cites at least one existing task of the project.
- Targets exist and are active.
- Retired plus superseded is at most 25% of active memories.
- Content within bounds, scrubbed, and free of instruction-like text aimed
  at agents (heuristic warning, not a filter).
- Rejected batches return the reasons, so the dreamer can fix and resubmit
  once.

**Apply, review and undo:**

- In **`auto`** mode, the validated batch is written as KV updates, and the
  dream record keeps every prior version.
- In **`review`** mode, the batch is staged on the dream task, which moves
  to Review. A person applies or discards it with `dieter memory dream
apply|discard CARD` or the task's **Apply memory changes** and
  **Discard** buttons.
- Either way, `dieter memory dream undo CARD` restores the prior versions.
  The dream task's transcript is the dream diary.

### 2.11 Clients

- **Kotlin core:**
  - the project `memoryEnabled`;
  - the task `memory` (creation default from the project, a switch command);
  - memory settings (form and validation, as `ReviewerForm`);
  - dream actions (apply, discard, undo, dream now).
- **Compose:**
  - a project toggle in `ProjectAdministration.kt`;
  - a Memory toggle in the creation sheets and the task settings menu;
  - Settings → Memory (dreaming switch, harness, model, account, run-on
    machine, apply mode);
  - Apply/Discard buttons on dream tasks awaiting review.
- **Mac:** the same controls in `ProjectContextSheet`, `NewConversationSheet`,
  `DieterSettingsView`, and the dream task's header.
- **Tests:** model and form tests in the core, JVM UI tests, Mac unit
  tests.
- **Visuals:** no new visual system. The controls reuse existing toggle,
  form and button components, to keep the UI change small and revertable.

### 2.12 User docs

- **`site/content/docs/memory.md`:**
  - project and task switches;
  - across machines;
  - privacy;
  - dreaming (settings, the Memory label, review and undo);
  - the CLI.
- **The skill and the proposal status lines.**

## 3. Evals

### E1. Deterministic unit evals (CI, `just test`)

- **Recall regression:** `tests/fixtures/memory/corpus.json` (about 30
  synthetic tasks in Codex, Claude Code and OMP shapes) and `queries.json`
  (about 25 paraphrases). Gates: hit@3 ≥ 0.9 and MRR ≥ 0.75, calibrated on
  the first green run.
- **Safety cases:**
  - secrets are scrubbed;
  - reasoning is not indexed;
  - no hits cross projects;
  - Dieter tool outputs are not indexed;
  - expired and superseded memories are not returned;
  - lessons are reinforced, not duplicated.
- **Switch gating:** project on with task off means nothing is indexed and
  no tools are offered; project off with task on means the same; Strix is
  excluded.
- **Federation merge:** fake peers (one slow, one failing) give a partial
  result with `unreachable` filled in. The reciprocal-rank order is stable,
  and the per-peer and total limits hold.
- **Replicated memories:**
  - KV validation;
  - concurrent reinforcements on two daemons add up;
  - a supersede concurrent with an edit resolves deterministically;
  - forget deletes;
  - the mirror ignores projects with memory off.
- **Dream gates and validation:**
  - with a fake clock: no dream before 24 h or before 5 new tasks, and none
    while one is running or in review;
  - `memory_apply` rejects a missing source, an unknown target, more than
    25% retired, more than 40 operations, and oversized content;
  - undo restores the exact prior versions.

### E2. End to end with the mock harness (CI, `just test-e2e`)

Built on `internal/testkit/topology`, with **two daemons** of one account:

1. Project P has memory on. Task A runs on daemon 1 and task B on daemon 2.
   A mock turn on B produces a tool output naming
   `TranscriptScrollController`.
2. Task C on daemon 1 runs `mock-memory-recall transcript scroll`. Its
   transcript contains a hit for task B with machine = daemon 2. This is
   federation over a peer carrier.
3. With daemon 2 stopped, the same recall returns daemon 1's hits and names
   daemon 2 as unreachable.
4. `mock-memory-save` on daemon 1. After replication, `dieter memory search
--machine daemon2 --local` finds the saved memory. This is the KV mirror.
5. A task created with `--memory off` is not indexed and gets no tools.
   `dieter card memory … on` enables both from the next turn. Agents can't
   switch it.
6. **Dreaming:**
   1. Enable dreaming with harness `mock`, minHours 0, minNewTasks 2, and
      daemon 1 as the run-on machine.
   2. After two tasks finish, the scheduler on daemon 1 creates exactly one
      dream task labelled Memory with role dreamer. Daemon 2 creates none.
   3. Its `mock-memory-dream` turn applies a valid batch (one merge, one
      supersede, one add). `dieter memory dream undo` restores the prior
      state.
   4. An invalid batch (retiring 50% of memories) is rejected with reasons.
   5. In review mode, the batch is staged until `dieter memory dream apply`,
      which refuses a turn token.
7. **CLI parity:** `dieter memory search`, `settings` and `dreams` return the
   same results over the local, direct TLS and relay routes.

### E3. Local evals (opt-in, results in the PR description)

The scripts are in `tools/evals/memory/`.

- **`recall.mjs`:**
  - The 18 spike questions against the owner's real history, after
    switching memory on for project dieter.
  - Run from two machines, to show federation: the dieter cards live on
    several daemons.
  - Target: at least the prototype's hit@3 of 17/18 and MRR 0.859.
- **`live.mjs`:** five real Claude Code turns with memory tools and five
  without, in an empty project. Pass: at least 4 of 5 cite the right task
  and key fact with tools.
- **`dream.mjs`** (dream quality, live):
  - It seeds an isolated daemon with a fixture project: about 12 tasks plus
    about 20 saved memories with **planted problems**:
    - 3 duplicate pairs;
    - 2 stale facts that newer tasks contradict;
    - 2 relative dates;
    - 2 facts derivable from the code;
    - 1 memory with no source;
    - 10 valid memories that must survive.
  - It runs one real dream with the configured model.
  - Scoring:
    - duplicates merged (≥2/3);
    - stale facts superseded or retired (≥1/2);
    - dates made absolute (2/2);
    - derivable facts dropped (≥1/2);
    - valid memories preserved (≥9/10);
    - every operation cites sources (100%);
    - no code changes in the worktree;
    - the recall eval afterwards is no worse.
  - Record the token cost and duration.
- **Performance:**
  - `BenchmarkMemoryIndexAndSearch` on 50k observations;
  - a federation latency check with two peers on one network and one over
    the relay.

## 4. Order of work inside the PR

1. ADR, invariants, threat model.
2. Proto plus `just generate`.
3. **Milestone A, memory core:**
   - `internal/store/memory` and the E1 recall and safety evals;
   - the indexer and backfill, turn hooks;
   - harness bridge and runtime module (recall and save);
   - `MemoryService` (status, search, save, forget, reindex) and the
     project switch;
   - CLI.
4. **Milestone B, per-task switch:**
   - `Card.Memory`, the creation default, `SetCardMemory`;
   - the effective rule everywhere, gating tests.
5. **Milestone C, across machines:**
   - the `memory` KV namespace and the local mirror;
   - federation client and peer authorization, merge;
   - E1 federation and replication evals.
6. **Milestone D, dreaming:**
   - `memory-settings`, the Memory label, the scheduler and its gates;
   - the dreamer role, `memory_apply` validation, apply, review and undo;
   - E1 dream evals.
7. E2 two-daemon end-to-end test.
8. Clients, then docs and the skill.
9. E3 runs.

**Split point if review gets heavy:** A+B as one PR, then C+D.

## 5. Verification (once at the end; then rerun only what fails)

```sh
mise exec -- just check-changed --dry-run
mise exec -- just generate
mise exec -- just test
mise exec -- just test-e2e
(cd internal/harness/runtime && node --test memory.test.mjs code-review.test.mjs)
mise exec -- just kotlin :core:runtime:jvmTest :ui:jvmTest
mise exec -- just mac test_unit
mise exec -- just site-check
mise exec -- just lint
```

- **Device flows:** rerun the project-settings and settings smoke flows on
  the warm Android emulator and on the Mac (`profile:ios-iphone` for iOS if
  touched).
- **Before merging:** run a dev build on two isolated `DIETER_HOME`s with the
  fixture gateway, with real Claude Code and Codex turns on provider
  accounts, and one real dream. Confirm tools, federation and the dream
  task end to end.

## 6. Risks

- **Overlap with #239:** start from `origin/main` and reuse its shapes. A
  shared host-call refactor of the three bridges is a follow-up.
- **Peer authorization surface.** `local_only` search is a new
  daemon-to-daemon read. It is limited to roster members, project-scoped,
  bounded, and never forwarded. Covered by E1 and E2 and the threat-model
  entry.
- **An autonomous writer.** Dreams can only touch saved memories, never code
  (isolated worktree), never transcripts, never other projects. Validation
  gates, a 25% loss cap, required sources, full prior versions and undo
  apply. Review mode is one setting away.
- **Cost.** Defaults of at most one dream per project per day, only after 5
  new tasks, inside a night window. Usage is attributed to the dream task
  and shows under the configured provider account.
- **Clock and machine changes.** Gates use the run-on machine's clock. If
  `runOn` changes or that machine is offline for more than 48 h, the next
  owner takes over after the lock record's lease expires.
- **Size.** About 12–15k lines including about 4k generated, and about 3–4
  weeks of work. That is comparable to #239.
