# Proposal: agent memory that runs inside Dieter

Status: accepted and implemented 2026-11-27 ([ADR 0007](../adr/0007-agent-memory.md));
decision proposal with three spikes · replaces the
external-provider recommendation in [agentmemory.md](agentmemory.md) · scope:
daemon (memory index, indexing from stored transcripts, new `MemoryService`),
harness runtime host tools, turn instructions, CLI; later the clients'
project settings; no gateway changes

## TL;DR

The requirement: a memory layer **that the user does not run** and that
**runs in Dieter**. Dieter installs, starts, upgrades and supervises it on
every daemon, with no separate setup, no model keys and no edits to agent
configs.

I spiked three options on the same data: this repository's 44 local cards,
24,227 observations from Codex, Claude Code and OMP. Each was scored on the
same 18 recall questions. agentmemory and the built-in index also got a live
Claude Code turn; OpenViking's tool would be identical, so I didn't repeat it.

**Choice: Dieter Memory, an index built into the daemon.** Not agentmemory,
not OpenViking.

- **Recall is as good as the external servers without a model.**
  - Built-in SQLite FTS5 (BM25): right card at rank 1 for 14/18 and in the
    top 3 for 17/18 (MRR 0.859, 4.7 ms median).
  - agentmemory keyword-only: 14/18 and 18/18 (MRR 0.889, 20 ms).
  - OpenViking with its built-in embedder took over 35 minutes and had still
    embedded only ~16k of the 24k observations when I stopped. On the 8 cases
    it could answer by then, it scored 5/8 at rank 1 and 5/8 in the top 3
    (MRR 0.713). On the same 8: built-in 5/8 and 7/8 (MRR 0.747);
    agentmemory keyword-only 6/8 and 8/8 (MRR 0.875).
  - Only agentmemory with local embeddings was clearly better at rank 1
    (17/18), and it costs 634 MB of RAM.
- **It costs almost nothing to run.**
  - Built-in: no extra process. Indexing takes 0.43 ms per observation, the
    index is 18.5 MB, and the whole indexer peaked at 51 MB.
  - agentmemory: 6 processes, ~276 MB, native workers downloaded at first
    start.
  - OpenViking: a 761 MB Python environment, 485–673 MB of RAM, and 72–217 ms
    per observation, getting slower as the index grows.
- **It needs nothing Dieter doesn't already have.** `modernc.org/sqlite` (pure
  Go) is already a dependency, behind `schedules.db`. The index lives under
  `DIETER_HOME` next to the transcripts it is derived from. No new data flow
  leaves Dieter, no runtime downloads, nothing for Linux daemons or the test
  kit to provision.
- **The live turn behaved like the agentmemory one.**
  - Claude found the deferred `memory_recall` tool by itself, made three
    queries (20–38 ms each) and named the right card and PR.
  - It hedged on the root cause, because the snippets didn't contain it.
    Hits should therefore also carry the card's final answer (§5.4).
- **Why not the others, briefly:**
  - **agentmemory** works, but supervising it means generating its internal
    `iii compose` file. Dieter would also have to pin and verify native worker
    binaries from `api.workers.iii.dev`, run it with an overridden `HOME`, and
    work around its capture-inbox bug. Its weekly releases would move all of
    that.
  - **OpenViking** has a different licence: AGPL-3.0 plus a clause against
    rewriting or translating it, inside an MIT product. It is a Python stack.
    Without an LLM, its session and memory pipeline fails; only file indexing
    works. Its LLM option imports the user's Codex login, which breaks
    Dieter's one-refresher rule.

Phase 1 (index, indexing, host tools, CLI, project opt-in) is about 1–1.5
weeks, less than the external-provider plan because there is no outbox,
provider client or supervision.

## 1. Requirement and options

| Option                | What "runs in Dieter" would take                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| agentmemory, managed  | Install the npm package (`--omit=optional`, 98 MB) and the pinned `iii` (26 MB) into the harness runtime. Generate agentmemory's internal `worker-compose.yaml` and run `iii compose --up` as a supervised foreground child, the way its Docker entrypoint does, with `HOME` pointed into `DIETER_HOME` (24 hard-coded `~/.agentmemory` paths). Pre-fetch and verify the `state` and `http` worker binaries. Then add the capture outbox and per-card budget from [agentmemory.md](agentmemory.md). |
| OpenViking, managed   | Provision Python 3.10+ (uv), a 761 MB virtualenv and llama-cpp-python (compiled from source in the spike: cmake, 52 s, 247 s CPU) or a prebuilt wheel. Run `openviking-server` in the foreground with a generated `ov.conf`. To get sessions and memories at all, add a model provider (API key) for its VLM. Comply with AGPL-3.0 when distributing it.                                                                                                                                            |
| **Built-in (chosen)** | A `memory.db` SQLite FTS5 index per daemon under `DIETER_HOME`, fed from Dieter's own stored transcripts after each turn, plus two host tools and a CLI group.                                                                                                                                                                                                                                                                                                                                      |

## 2. Measurements (2026-11-27, Apple Silicon, macOS 27, same 44 cards)

| Measurement                            | agentmemory keyless  | agentmemory + MiniLM  | OpenViking keyless (bge-small-zh)                  | **Built-in FTS5**           |
| -------------------------------------- | -------------------- | --------------------- | -------------------------------------------------- | --------------------------- |
| Processes added                        | 6                    | 6                     | 1 (Python)                                         | **0**                       |
| Install                                | 98 MB + 49 MB native | 957 MB + 49 MB native | 761 MB + 46 MB model + llama.cpp build             | **0** (existing dependency) |
| Runtime downloads at first start       | iii workers          | iii workers + model   | GGUF model (Hugging Face)                          | **none**                    |
| RSS after ingest                       | 276 MB               | 634 MB                | 485 MB idle, 543–673 MB ingesting                  | **51 MB peak (indexer)**    |
| Disk for 24k observations              | 106 MB               | 154 MB                | 228 MB at ~16k (incomplete)                        | **18.5 MB**                 |
| Ingest per observation                 | 5 ms                 | ~16 ms                | 72–217 ms, slowing; unfinished after 35 min        | **0.43 ms**                 |
| hit@1 / hit@3 (18 cases)               | 14 / 18              | 17 / 17               | not measurable (store incomplete)                  | 14 / 17                     |
| hit@1 / hit@3 (8 cases OV had indexed) | 6 / 8                | 7 / 7                 | 5 / 5                                              | 5 / 7                       |
| MRR (18 cases) · p50 latency           | 0.889 · 20 ms        | 0.944 · 40 ms         | 0.713 on 8 cases · 18–28 ms idle, 522 ms ingesting | 0.859 · 4.7 ms              |
| Needs a model for its core loop        | no                   | no                    | **yes** (sessions, memories, summaries)            | no                          |
| Licence                                | Apache-2.0           | Apache-2.0            | AGPL-3.0 + no-rewrite clause                       | Dieter's (MIT)              |

The queries are paraphrases I wrote knowing the cards: illustrative, not a
benchmark. Agents compensate for misses by asking again: the built-in live turn
issued three queries. Raw numbers are in
`tools/spikes/{agentmemory,openviking,memory-index}` and their `results/`.

## 3. OpenViking spike (0.5.6, verified in source `26dbce3` and a live install)

**What it is.** A "context database": a virtual filesystem under `viking://`
holding resources, memories and skills.

- Generated L0 abstracts and L1 overviews per directory let agents read
  summaries before full content.
- Sessions record messages. `commit` archives them, then a background task
  writes summaries and extracts typed memories (profile, preferences,
  entities, events, cases) **with an LLM (VLM)**.
- Search is vector search, plus optional LLM intent planning and rerank.
- Python server with a Rust file layer (RAGFS), FastAPI on `127.0.0.1:1933`.
  Auth modes `dev`, `api_key` and `trusted`.
- Default local embedder: `bge-small-zh-v1.5` (GGUF, a Chinese BGE model,
  512 dimensions) via llama-cpp-python. API embedders include OpenAI,
  Volcengine and Ollama.
- VLM providers include API keys, Ollama and `openai-codex`, which imports or
  creates a Codex login.

**Results without a model provider** (`tools/spikes/openviking`):

- **Install:** `uv pip install 'openviking[local-embed]'` took 11 s for the
  base package (761 MB), plus 52 s to compile llama-cpp-python. The first
  start downloaded the 46 MB model.
- **Runtime:** one foreground process, loopback only, healthy in about 2 s.
  RSS was 485 MB idle and 589–673 MB during ingest. It writes
  `~/.cache/openviking/models` unless configured otherwise.
- **Session path fails.** Creating a session, adding messages and
  committing all succeeded. The background `session_commit` task then failed
  after 26 s with "Missing credentials … `OPENAI_API_KEY`", and the archive
  stayed unindexed (`failedArchives: 1`). Memory extraction, summaries and
  session context all need a VLM. A second commit was still accepted.
- **Resource path works.** `content/write` took 1.5 s with `wait`. `find` hit
  for an exact term and for a paraphrase (18–28 ms). `search` falls back to
  plain vector search (no query plan), and `grep` works.
- **Replay:** one Markdown file per observation (the same mapping as
  agentmemory) under `viking://resources/dieter/cards/<card>/`.
  - With `wait`, `batch-write` took 72–267 ms per observation, and the
    server sat at 12–47% CPU.
  - Without `wait`, the remaining 18,365 observations were accepted in
    318 s. The embedding queue then drained at 8–9 per second, falling to
    about 4.6 per second (≈217 ms each).
  - After 35 minutes, ~16k of 24k observations were embedded, so I stopped
    measuring.
  - 32 directory-summary tasks stayed "in progress" the whole time; they need
    the missing VLM.
- **Recall:** only 8 of the 18 cases had their card embedded by then, and
  the other cards weren't competing yet, which makes this easier for
  OpenViking. It still scored hit@1 5/8, hit@3 5/8, hit@5 8/8 (MRR 0.713).
  The built-in index scored 5/8, 7/8, 7/8 (MRR 0.747) on the same 8. Search
  took 18–28 ms on a small idle store and a 522 ms median while ingesting.

**Why not OpenViking for Dieter:**

- **Its value depends on a model.** Without one, Dieter would be shipping a
  761 MB Python vector store.
- **The model options don't fit Dieter's rules.** Importing the Codex login
  means a second refresher for one login, which ADR 0006 and the invariants
  forbid. API keys are a new secret for the user to manage.
- **The licence:** AGPL-3.0, and the README forbids "wholesale rewriting"
  and translation without permission.
- **The default embedder is Chinese-optimized.**

## 4. Built-in prototype (`tools/spikes/memory-index`)

- **Index:** an FTS5 table (`card`, `kind` unindexed; `title`, `body` with
  the `porter unicode61` tokenizer). It holds the same observations as the
  other spikes: prompts, tool calls with clipped input and output, failures,
  and the last answer of each reply. Reasoning is never indexed.
- **Query:** free text becomes an OR of quoted terms without stopwords, ranked
  with `bm25(observations, 2.0, 1.0)` (the title weighted ×2), grouped by
  card. No tuning beyond that, to avoid fitting the 18 cases.
- **Results:** 24,227 observations from 44 cards indexed in 10.5 s, including
  reading the transcript files. The index is 18.5 MB and the process peaked at
  51 MB. Recall was hit@1 14, hit@3 17, MRR 0.859, with a 4.7 ms median and
  53 ms maximum. The worst case, "why are builds and emulator tests so slow",
  ranked 7th; BM25 favors the many cards that mention builds.
- **Live Claude Code turn** (Sonnet, low effort, empty project, same prompt
  as the agentmemory turn):
  - `ToolSearch`, then `memory_recall` three times (27, 38 and 20 ms), then
    the answer, in 13.3 s.
  - Correct card, PR #144, the commit and the related diagnosis note.
  - It said the snippets didn't state the root cause, and offered to read the
    transcript. The agentmemory turn did read it.

## 5. Design: Dieter Memory

The scope comes from a full feature inventory of agentmemory,
[agentmemory-rebuild.md](agentmemory-rebuild.md). Of its 61 capabilities,
v1 rebuilds 12 core ones, v2 adds 6, and the rest is skipped. Most skipped
items are things Dieter already has: transcripts, cards, leases, channels,
schedules and replication.

### 5.1 Shape

```text
turn finished ─▶ indexer (dieter serve) ─▶ DIETER_HOME/memory/memory.db (FTS5)
                                                 ▲
harness worker ──memory_recall / memory_save──▶ MemoryService ◀── dieter memory … (CLI, --machine)
```

### 5.2 Storage

- **One machine-local SQLite database per daemon,**
  `DIETER_HOME/memory/memory.db`, opened through the existing helpers
  (`internal/store/home/sqlite.go`), like `schedules.db`.
- **Tables:**
  - `observations`: FTS5, holding card, project, kind, title, body, time and
    message id.
  - `memories`: explicit saves, also FTS5.
  - `indexed`: card, last indexed message and revision, so indexing is
    incremental and idempotent.
- **The index is derived data:** deleting it and running
  `dieter memory reindex` rebuilds it from the transcripts. It is never
  replicated.
- **Bounds:**
  - Fields are clipped to 4 KB, and answers to 8 KB.
  - Per daemon, at most 1 GiB or 2 million observations. Past that, the
    oldest observations of archived cards go first.
  - Explicit memories are limited to 4 KB each and 10,000 per project.

### 5.3 Indexing

- **Trigger:** the engine signals "turn finished" (card, turn), and an
  indexer started only by `dieter serve` indexes that turn's stored messages.
  Those messages have already gone through vault redaction.
- **Backfill:** turning a project on starts a bounded background backfill of
  the project's existing conversations on that daemon (newest first,
  batches of 500).
- **What a row holds:**
  - an inferred kind (`file_read`, `file_edit`, `command_run`, `search`,
    `error`, `conversation` and so on, following agentmemory's synthetic
    typing);
  - the tool name and the files it touched;
  - a body of at most 4 KB.
- **One digest row per card,** built deterministically: title, brief, final
  answer, files touched, commands and failures. It stands in for
  agentmemory's LLM session summaries, which don't exist without a model.
- **Scrubbing:** indexed text gets agentmemory's token regexes (PEM, URL
  credentials, `sk-`, `ghp_`, `AKIA`, JWT and others) and honours
  `<private>…</private>`. Hits are injected into other agents' prompts,
  which may run on other providers.
- **What is never indexed:** reasoning parts, `data-*` parts, Dieter's own
  host-tool calls, Strix cards, and conversations of projects with memory
  off.
- **Deletion:** deleting a card removes its rows in the same operation. An
  archived card stays searchable, with its lane shown in hits.

### 5.4 Recall

- **Host tools** in `runner.mjs`, offered when the project has memory on:
  - `memory_recall {query, limit≤10}`
  - `memory_save {content, kind: lesson|decision|fact|pattern, files?, ttlDays?}`.
    It returns a `similarTo` hint when a saved memory is close. Text that is
    near-identical supersedes the old memory. Saving the same lesson again
    raises its confidence instead of duplicating it.
- They reach the daemon through a host-call bridge, a generalization of the
  background-process bridge. The daemon fixes the scope to the conversation's
  project, so the worker never chooses it.
- **A hit is a card:** id, title, lane, last activity, up to two FTS5
  snippets of at most 500 characters, and the **card's final answer**
  (at most 600 characters). The live turn showed snippets alone can miss the
  conclusion. Explicit memories come first. The result is at most 8 KB and
  is labelled as earlier work that may be out of date.
- **CLI:** `dieter memory search|save` for agents (the fallback when a harness
  defers host tools, as Claude Code does) and for people.
  `dieter memory status|forget|reindex` are human-only and refuse a turn
  token.
- **Instructions:** a block of at most 1 KB (`prompt.MemoryInstructions(cli)`)
  next to the vault and folder blocks.
- **No automatic injection,** because the evidence shows recency-based
  injection is noise. A query-driven first-turn pre-recall can be tried later
  behind a flag.

### 5.5 API, CLI and clients

- `MemoryService` RPCs: `GetMemoryStatus`, `SearchMemory`, `SaveMemory`,
  `ForgetMemory` (human-only) and `ReindexMemory` (human-only). They follow
  the usual parity steps and end-to-end tests over local, direct TLS and
  relay.
- `--machine` searches another daemon's memory through the tunnel.
- Phase 2 adds a project settings toggle ("Project memory", portable, off by
  default) and a per-machine status row. The rules live in the Kotlin core.

### 5.6 Later, if wanted

- **Account-wide lessons:** replicate explicit `memory_save` entries between
  daemons as bounded single-writer KV records. Observations stay local.
- **Semantic recall:** an optional embedding column, for example through a
  model the user already runs. Not needed for Phase 1, given §2.
- **Memory curator:** agentmemory's LLM layer (consolidation, insights,
  summaries) done as a scheduled Dieter card on the user's own provider
  account. It reads recent cards and saves lessons and decisions through
  `dieter memory save`. No credentials enter the memory layer, and every
  change is reviewable in the curator's transcript
  ([agentmemory-rebuild.md §6](agentmemory-rebuild.md)).

## 6. Safety and invariants

| Topic                   | Handling                                                                                                                                              |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Data stays in Dieter    | The index is derived from transcripts on the same machine, under `DIETER_HOME`, by the same user. No third-party process, network flow or new secret. |
| Storage                 | SQLite with its own transactions, like `schedules.db`. The indexer writes only its own database. Normal operation goes through the daemon API.        |
| Background work         | The indexer starts in `internal/daemon` under `dieter serve` only; handlers built in tests start nothing.                                             |
| Secrets                 | Indexing reads stored transcripts, which are already vault-redacted. Reasoning is never indexed.                                                      |
| Cross-project leakage   | The daemon sets the project; tools take no project argument.                                                                                          |
| Agent turns             | They may search and save. Forget and reindex refuse a turn token, like the folder and trust mutations.                                                |
| Staleness and poisoning | Hits carry time, lane and card id and are labelled as historical. They are never written into system instructions; agents verify by reading the card. |
| Gateway                 | Untouched; `--machine` calls ride the opaque tunnel.                                                                                                  |
| Bounds                  | §5.2 and §5.4.                                                                                                                                        |

The memory feature still gets a short **ADR 0007**: what is indexed, the opt-in,
the human-only mutations and the bounds. No third-party data flow is involved.

## 7. Plan

The PR-level plan, with files, protocol, bounds, evals and verification, is
in [agent-memory-implementation.md](agent-memory-implementation.md). It ships
Phase 1 and the client toggle as one PR.

1. **ADR 0007.**
2. **Phase 1 (~1–1.5 weeks):**
   - `internal/store/memory` (schema, incremental indexing, query, bounds)
     and `internal/host/memory` (the turn-finished indexer and backfill).
   - Mapping golden tests from fixture transcripts (Codex, Claude Code, OMP
     and Pi parts), and a recall regression fixture that checks hit@k on a
     small synthetic corpus.
   - `MemoryService`, the CLI and the host-call bridge with the two tools.
   - `prompt.MemoryInstructions` and the project setting.
   - Docs: `site/content/docs` and `.agents/skills/dieter-cli/SKILL.md`.
3. **Phase 2 (~1 week):** client toggle and status, and the first-turn
   pre-recall experiment behind a flag.
4. **Later:** account-wide lessons, optional embeddings and the memory curator (§5.6).

## 8. Decisions needed

1. **The choice above.** I recommend the built-in index. If you want
   agentmemory anyway, its managed mode is feasible (§1); estimate an extra
   week, plus upkeep on every upstream release.
2. **Defaults:** project memory off; the per-task switch defaults to the
   project's setting (recommended).
3. **Scope of recall:** the task's project, across all of the account's
   machines (recommended). Standalone chats belong to a project too.
4. **Dreaming:**
   - off by default;
   - when on, `auto` apply with validation and undo (recommended) or
     `review`;
   - dream model defaults to the reviewer's (Claude Code, Opus);
   - one designated machine per project runs the dreams.

## 9. Dreaming in other systems (research, 2026-11-27)

The extended plan ([agent-memory-implementation.md](agent-memory-implementation.md)
§2.10) borrows from these designs:

| System                                                                                                                                                                                                                                                                                       | How it consolidates                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | What Dieter takes                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **OpenClaw** "Dreaming" ([docs](https://docs.openclaw.ai/concepts/dreaming))                                                                                                                                                                                                                 | Opt-in, managed cron (`0 3 * * *`). Light → REM → deep phases. Deep promotion into `MEMORY.md` is gated (`minScore` 0.75, `minRecallCount` 3, `minUniqueQueries` 3, `recencyHalfLifeDays` 14). The model returns **operations, not prose**. A rewrite is rejected if it loses more than `maxPriorEntryLossFraction` 0.25 of prior entries or drops `Source:` references. Preimages are kept for undo. A `DREAMS.md` diary records each run. Untrusted provenance is removed before the prompt | Operation-based `memory_apply`; the 25% loss cap; required sources; prior versions plus undo; recall counts as a promotion signal; the night window; the task transcript as the diary       |
| **Hermes Agent** ([memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory), [curator](https://hermes-agent.nousresearch.com/docs/user-guide/features/curator), [providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers))          | Small curated `MEMORY.md`/`USER.md` (2,200/1,375 chars) injected as a frozen snapshot. Session search is SQLite FTS5 with no LLM. A forked **background review** after turns, with its own model (`auxiliary.background_review.provider/model`, default the main model) and a narrow tool whitelist. A weekly **curator** (`interval_hours` 168, `min_idle_hours` 2) with backups, a ledger, and no auto-delete. Optional write approval                                                      | A separately configured agent session in settings (like `auxiliary.*`); a narrow tool set for the dreamer; archive/retire instead of delete; a ledger (dream records); optional review mode |
| **Claude Code** auto memory and Auto Dream ([official memory docs](https://code.claude.com/docs/en/memory); Auto Dream from secondary sources such as [finisky](https://finisky.github.io/en/claude-code-auto-dream) and [claudefa.st](https://claudefa.st/blog/guide/mechanics/auto-dream)) | Loads the first 200 lines or 25 KB of `MEMORY.md`. Auto Dream (not in the official docs) is a sub-agent that runs once **≥24 h and ≥5 sessions** have passed, holds a lock file, and may edit only the memory directory. Phases: orient, gather signal, consolidate (absolute dates, remove contradicted facts, merge), prune and index                                                                                                                                                       | The 24 h + 5 task gates; one dream at a time per project; the four-step procedure; writes confined to saved memories                                                                        |
| **Letta** ([memory and dreaming](https://docs.letta.com/guides/agents/sleep-time-agents), [sleep-time compute](https://letta.com/blog/sleep-time-compute))                                                                                                                                   | A sleep-time agent holds the memory-edit tools for the primary agent, with an independent (stronger) model. It triggers after N steps or on compaction. "Agent reviews before applying." Memory is a git repository; it backs up before restructuring and uses worktrees for concurrent memory agents                                                                                                                                                                                         | A separate model for the curator; the dream runs in an isolated worktree; review before apply as an option                                                                                  |
| **Anthropic**, "The components of agent memory" ([post](https://www.anthropic.com/engineering/components-of-agent-memory))                                                                                                                                                                   | Layers: transcripts (ground truth), notes, representations, injected context. Dreaming tests notes against transcripts. Pitfalls: wrong-from-start notes carried into every session, staleness, overgrowth (a wiki 1.77× its source), cost. Patterns: one page per entity (a shared page lost 16 of 57 facts), marking verified vs unconfirmed, no blanket "record only failures" rules                                                                                                       | The verify step against transcripts; `verified` status; one memory per topic; no injection of curated memory into instructions; bounded memory counts                                       |

What Dieter does differently from all of them:

- The dream is an ordinary, visible Dieter task: the Memory label, an
  isolated worktree, the user's own provider account, the normal review
  lane. There is no hidden background process with its own credentials.
- Recall stays query-driven over transcripts that never leave their machine.
  Only curated memories replicate.
