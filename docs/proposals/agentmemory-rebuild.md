# agentmemory, feature by feature: what a Dieter rebuild needs

Status: investigation, 2026-11-27 · source `rohitg00/agentmemory` main at
`5c9e2e6` (2026-11-18), plus the live npm 0.9.33 runs from
[agentmemory.md](agentmemory.md) · companion to
[agent-memory.md](agent-memory.md), which chooses a built-in memory layer;
this document fixes its scope

## TL;DR

agentmemory is about **58,000 lines of TypeScript**:

- 83 function modules, 147 REST endpoints and 54 MCP tools;
- 17 skills and 12 Claude Code hooks;
- a live viewer, and a CLI that wires 22 agent hosts;
- 18 background timers.

Read end to end, it falls into five layers. Only the first one, plus parts of
the second, is what a user actually gets without an LLM.

| Layer                                                                                                          | Code     | Default without an LLM                          | Rebuild in Dieter?                                                                      |
| -------------------------------------------------------------------------------------------------------------- | -------- | ----------------------------------------------- | --------------------------------------------------------------------------------------- |
| **1. Capture and recall**: hooks → idempotent inbox → stored observation; BM25 (+ vectors); recall, budgets    | ~9k LOC  | works                                           | **Yes, the core of v1**, mostly simpler, because Dieter already owns the transcript     |
| **2. Explicit memory and hygiene**: save with supersession, lessons, TTL, forget, scrubbing, export            | ~4k LOC  | works                                           | **Yes, the useful half**                                                                |
| **3. LLM knowledge layer**: compression, summaries, consolidation, insights, crystals, skills, LLM graph       | ~6k LOC  | **does nothing** (`no_provider`, noop, skipped) | Later, and differently: as a scheduled Dieter harness turn on the user's account        |
| **4. Coordination and team**: actions, leases, signals, routines, checkpoints, sentinels, sketches, mesh, team | ~4k LOC  | works                                           | **No**: Dieter already has cards, leases, channels, schedules and replication           |
| **5. Surfaces and operations**: MCP, REST, viewer, CLI `connect` for 22 hosts, skills, status, health          | ~20k LOC | works                                           | Replaced by 2 host tools, a CLI group, a small `MemoryService` and an instruction block |

**A notable share of what the README advertises isn't live code:**

- Retention scoring and eviction have no caller.
- The temporal graph has no entry point, and query expansion is never called.
- Episodic memory strength never decays.
- No timer expires leases, signals, checkpoints or sentinels.
- `mem::search` always runs the hybrid ranker, despite the README's
  "BM25 when no vectors".

The rebuild should copy behaviour that is live and measured, not the feature
list.

**Recommended scope** (details in §5):

- **Dieter Memory v1:** 12 capabilities, about 2–3k lines of Go plus tests.
- **v2:** 6 more.
- **Later:** an LLM "memory curator" that runs as a scheduled Dieter turn.
- **Skip:** about 30 capabilities, each with a stated Dieter equivalent or
  reason.

## 1. Shape of the codebase

| Area             | LOC    | Contents                                                                                                            |
| ---------------- | ------ | ------------------------------------------------------------------------------------------------------------------- |
| `src/functions/` | 25,093 | 83 `mem::*` functions: everything below                                                                             |
| `src/cli/`       | 6,789  | start/stop/status/doctor, `connect` for 22 hosts, onboarding, iii engine install and launch                         |
| `src/state/`     | 5,336  | KV wrapper over the iii engine, BM25, vector index, hybrid fusion, reranker, graph retrieval index                  |
| `src/triggers/`  | 5,001  | 147 REST endpoints, viewer SSE streams, session-stopped event chain                                                 |
| `src/mcp/`       | 4,612  | 54-tool registry, REST-to-MCP bridge, standalone shim with a local 7-tool fallback                                  |
| `src/hooks/`     | 3,009  | hook clients (bundled as `plugin/scripts/*.mjs`)                                                                    |
| `src/providers/` | 1,684  | LLM providers, fallback chain, circuit breaker, embedding providers                                                 |
| other            | ~2,700 | capture spool, viewer server, prompts, replay, eval, health, telemetry                                              |
| outside `src/`   | n/a    | 17 skills, native integrations (Pi, OMP, Hermes, OpenClaw, OpenCode, Cursor, Orca, fs-watcher), website, benchmarks |

**Runtime:**

- The worker registers functions with the iii engine over a WebSocket. The
  engine's `state` worker holds every record in an in-memory KV store, saved
  to `state_store.db` every 2 s.
- All locks are in-process promise chains. Two workers sharing one store are
  not coordinated.

## 2. Capability inventory

Legend:

- **Default:** on, off, or "manual" (only when called).
- **LLM:** whether the capability needs a model; "opt" means optional.
- **Dieter today:** what already exists.
- **Rebuild:** v1, v2, later, or skip.

### 2.1 Capture and sessions

| #   | Capability                                     | What it does                                                                                                                                                                                                                                                                                                                                                                          | Default | LLM | LOC   | Dieter today                                                  | Rebuild                                                                                                         |
| --- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | --- | ----- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 1   | Hook capture client + offline spool            | Short-lived hook processes filter tools (a deny-list includes `memory_*`), derive event ids (from the host's id, or a content hash with the timestamp), POST with a 3 s cap, spool to a 5 MiB JSONL file on failure, keep sent events until the server's `durableAfterMs` and replay them if `bootId` changes                                                                         | on      | no  | 1,100 | The daemon receives every chunk of every turn                 | **skip**: no hooks needed                                                                                       |
| 2   | Durable capture inbox                          | Server-side idempotency via `cap_` keys over 256 completed-event shards; `pending → retrying` (10 s×2ⁿ, 5 tries) `→ dead`; 503 when 10k unprocessed; tombstones stop deleted events from being replayed back                                                                                                                                                                          | on      | no  | 650   | Transcripts are durable in `DIETER_HOME`                      | **skip**: an "indexed through message N" cursor per card gives idempotency                                      |
| 3   | Observation ingest + **synthetic compression** | Each event becomes a stored row. **title** = tool or hook name; **subtitle** = input, 120 chars; **type** inferred from hook and tool name (`file_read/edit/write`, `command_run`, `search`, `web_fetch`, `conversation`, `error`, `subagent` …); **narrative** = prompt / input / output / response, 400 chars; **files** from `file_path/path/…` keys; importance 5, confidence 0.3 | on      | no  | 750   | UI parts hold tool name, input, output, error state           | **v1**: keep type inference and file extraction as columns; index more than 400 chars                           |
| 4   | Per-session cap                                | 500 observations per session. 0.9.33 **refuses** extras, which poisoned the inbox in the spike; main **evicts** the lowest importance (unreleased fix `acbc7ce`)                                                                                                                                                                                                                      | on      | no  | —     | —                                                             | **v1** as per-daemon index bounds (§5)                                                                          |
| 5   | Privacy scrubbing                              | Removes `<private>…</private>` blocks; regexes for PEM, URL credentials and 14 token formats (`sk-`, `sk-ant-`, `ghp_`, `AKIA`, `AIza`, JWT, `xoxb-`, `npm_`, `glpat-`, Bearer, `key=` with long values). Secret-named keys are redacted only on oversized hook payloads                                                                                                              | on      | no  | 141   | Vault-secret redaction before storage                         | **v1**: apply the token regexes and `<private>` to indexed text, because hits travel into other agents' prompts |
| 6   | Source retention budget                        | Raw source ≤16 KiB per observation, 8 MiB per session                                                                                                                                                                                                                                                                                                                                 | on      | no  | 120   | The full payload stays in the transcript (`card tool-output`) | **skip**: index text points back at the transcript                                                              |
| 7   | LLM compression                                | Prompt → `<observation>` with type, title, facts, 2–3-sentence narrative, concepts, files, importance 1–10; strict XML parse, one "stricter" retry, quality score                                                                                                                                                                                                                     | off     | yes | 600   | —                                                             | **later** (§6)                                                                                                  |
| 8   | Session lifecycle                              | `session/start` upsert (resets `startedAt` on resume); per-turn Stop → `end{final:false}`; finalize after 120 s idle (30 s tick); hourly sweep abandons sessions idle 24 h; SessionEnd backfills the first 50 prompts from the transcript; git post-commit hook links commits                                                                                                         | on      | no  | 700   | Cards, turns, runtime state, lanes                            | **skip**: one card is the session                                                                               |
| 9   | Session summaries                              | LLM `<summary>` with title, narrative, decisions, files, concepts. Incremental via a coverage fingerprint, map-reduce over 400-observation chunks, repair queue with backoff. **No LLM: no summary at all**                                                                                                                                                                           | off     | yes | 900   | Card title, brief, lane, final answer                         | **v1**: a deterministic _card digest_ instead (§5); LLM summary later                                           |
| 10  | Images                                         | Base64 images stored by hash with reference counts; 500 MB soft quota; CLIP vision search (opt-in)                                                                                                                                                                                                                                                                                    | on      | opt | 400   | Attachments in transcripts                                    | **skip**                                                                                                        |
| 11  | Export / import / migrate                      | Paged JSON export (60 MiB cap), import with merge/skip/replace, legacy SQLite migration                                                                                                                                                                                                                                                                                               | manual  | no  | 830   | —                                                             | **v2**: export of saved memories only (the index is derived)                                                    |
| 12  | Replay + `import-jsonl`                        | Session timeline player; imports Claude Code transcripts from `~/.claude/projects` (bypasses the cap, no tool names)                                                                                                                                                                                                                                                                  | manual  | no  | 950   | Clients already render transcripts                            | **skip**: maybe later, importing non-Dieter Claude sessions                                                     |
| 13  | Commit links                                   | `mem:commits[sha]` ↔ sessions; `memory_commit_lookup`, `memory_commits`                                                                                                                                                                                                                                                                                                               | on      | no  | 150   | Dieter records git operations and PRs per card                | **v2**: index commit SHAs and PR numbers per card ("which card made commit X")                                  |

### 2.2 Retrieval

| #   | Capability                                  | What it does                                                                                                                                                                                                                                                                                      | Default             | LLM | LOC | Dieter today                                    | Rebuild                                                                                                            |
| --- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | --- | --- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| 14  | BM25 index                                  | In-memory, rebuilt from KV at every boot. k1 1.2, b 0.75. Hand-written Porter stemmer; 42 synonym groups at weight 0.7; **prefix fallback** at 0.5×IDF (moved their LongMemEval strict R@5 from 65.7% to 84.7%). No field weights; a hyphen quirk splits words; whole file paths become one token | on                  | no  | 750 | —                                               | **v1** via FTS5 (porter, persistent, incremental): title weighting, prefix terms, a small synonym table            |
| 15  | Vector index                                | Brute-force cosine; MiniLM 384-d local, or Gemini, OpenAI, Voyage, Cohere, OpenRouter; buckets saved every 10 min plus a pending log                                                                                                                                                              | off                 | emb | 820 | —                                               | **later**, optional (agent-memory.md §5.6)                                                                         |
| 16  | Hybrid fusion                               | Weighted RRF (k 60; BM25 0.4, vector 0.6, graph 0.3), +5% per agreeing stream, graph stream with a 500 ms budget, **at most 3 per session** (reorders, doesn't drop), optional rerank                                                                                                             | on                  | opt | 424 | —                                               | **v1**: per-card grouping; RRF only once vectors exist                                                             |
| 17  | Cross-encoder rerank                        | ms-marco-MiniLM over the top 20                                                                                                                                                                                                                                                                   | off                 | loc | 97  | —                                               | **skip**                                                                                                           |
| 18  | Recall response                             | `compact`, `narrative` or `full` formats; tokens ≈ chars/3; greedy packing in rank order; clips the top hit if it alone overflows; reports `truncated`, `excluded_by_budget`, `minimum_budget`                                                                                                    | on                  | no  | 202 | —                                               | **v1**: bounded output with truncation metadata                                                                    |
| 19  | Smart-search                                | Compact hits plus lessons; `expandIds` returns full records (progressive disclosure)                                                                                                                                                                                                              | on                  | no  | 474 | `card transcript`, `card tool-output`           | **v1**: hits carry card id + message id; expansion goes through the existing transcript and tool-output commands   |
| 20  | Session-start context                       | **Recency-ordered, not query-driven**: pinned slots, cached profile, top 10 lessons, last 10 sessions (summary, or top 5 observations), packed to 2,000 tokens. Spike: noise without an LLM                                                                                                       | off (inject opt-in) | no  | 299 | Instruction blocks                              | **skip** (evidence); maybe a query-driven first-turn pre-recall later                                              |
| 21  | Enrich (PreToolUse)                         | Before Edit/Write/Read/Glob/Grep: file history (top 5, last 15 sessions), 5 search hits, up to 3 `bug` memories for those files; 4,000-char cap                                                                                                                                                   | off                 | no  | 260 | —                                               | **v2** as an explicit query: `memory_recall` with a `files` filter, and `dieter memory files PATH`                 |
| 22  | Lesson recall                               | Separate BM25; score = confidence × normalized BM25 × 1/(1+0.01·days since reinforced)                                                                                                                                                                                                            | on                  | no  | 120 | —                                               | **v1**, merged into saved memories (kind `lesson`)                                                                 |
| 23  | Graph retrieval                             | Entity postings, Dijkstra depth ≤2, chunk expansion from vector hits; capped reads                                                                                                                                                                                                                | on if data          | no  | 900 | Card ↔ file ↔ commit relations exist implicitly | **skip**                                                                                                           |
| 24  | Timeline, profile, patterns, verify, vision | Timeline: ±N around an anchor (full scan). Profile: top concepts, files, errors (1 h cache). Patterns: co-changed files (≥3 sessions), repeated errors (≥2), generated rules. Verify: memory → source observations. Vision: CLIP                                                                  | manual              | no  | 800 | Transcripts, card metadata                      | **v2**: profile and patterns computed from the index; verify comes free (hits are cards); skip timeline and vision |
| 25  | Access tracking                             | `count`, `lastAt`, last 20 timestamps per id, written on **every** returned hit; feeds only the unwired retention code                                                                                                                                                                            | on                  | no  | 104 | —                                               | **v2**: a read counter on saved memories for ranking, written in batches                                           |

### 2.3 Explicit memory, knowledge and lifecycle

| #   | Capability                                | What it does                                                                                                                                                                                                                                                                                                          | Default             | LLM | LOC    | Dieter today                                | Rebuild                                                                                                                 |
| --- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | --- | ------ | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 26  | Remember / supersede / evolve / forget    | Save with type (pattern, preference, architecture, bug, workflow, fact), concepts, files, TTL. Token Jaccard against the top 50 BM25 hits: >0.7 supersedes (version+1, old leaves the index), 0.4–0.7 returns a `similarTo` hint. First match wins, lexical only. Evolve is an explicit edit; forget is a hard delete | on                  | no  | 710    | —                                           | **v1**: save with kind, files and TTL; `similarTo` hint; supersede only on near-identical text (or explicit `replaces`) |
| 27  | Relations, cascade                        | Typed relations (supersedes, extends, derives, contradicts, related), BFS, staleness cascade into the graph                                                                                                                                                                                                           | on                  | no  | 500    | —                                           | **skip**                                                                                                                |
| 28  | Concept consolidation and 4-tier pipeline | Every 2 h and on session stop (5 min debounce). LLM merges the last 20 summaries into semantic facts (**exact-string dedupe → grows without bound**) and procedures from patterns; reflect; decay. **Search and context never read semantic or procedural records**                                                   | on only with an LLM | yes | 830    | —                                           | **later**, as a curator turn (§6)                                                                                       |
| 29  | Decay and retention                       | Pipeline decay `strength×0.9^(days/30)` on semantic and procedural records only. Retention score `salience·e^(−0.01·age) + 0.3·Σ1/daysSinceAccess` with hot/warm/cold tiers — **no caller**                                                                                                                           | partly              | no  | 630    | —                                           | **v2**: a mild recency factor in ranking; no tiers                                                                      |
| 30  | Lessons                                   | Fingerprinted rule strings; re-saving reinforces (`c += 0.1(1−c)`); weekly decay −0.05, soft-deleted at ≤0.1 if never reinforced; top 10 injected into context                                                                                                                                                        | on                  | no  | 416    | —                                           | **v1**: kind `lesson` with reinforcement on identical re-save; decay in v2                                              |
| 31  | Crystals, reflection insights             | LLM digests of finished action chains; insights over graph clusters with cited evidence (2–20 citations, re-verified); daily decay. Without an LLM, crystallize saves **empty** crystals                                                                                                                              | with LLM            | yes | 1,085  | —                                           | **later** (curator)                                                                                                     |
| 32  | Skill extraction                          | Per finished session, LLM `<skill>` with trigger and ≤10 steps → procedural record                                                                                                                                                                                                                                    | with LLM            | yes | 290    | Repo skills, project and label instructions | **skip**                                                                                                                |
| 33  | Slots                                     | Pinned, size-limited text blocks (persona, project context, pending items…); heuristic slot-reflect. "Project" scope is **one global key**                                                                                                                                                                            | off                 | no  | 486    | Project instructions, label instructions    | **skip**                                                                                                                |
| 34  | Auto-forget                               | **Hourly by default**: hard-deletes expired TTLs; a "contradiction" pass that is really a destructive near-duplicate pass (Jaccard >0.9, older one demoted); deletes observations older than 180 days with importance ≤2                                                                                              | **on**              | no  | 228    | —                                           | **v1**: TTL expiry only; never auto-demote by similarity                                                                |
| 35  | Evict                                     | Manual: stale sessions, old low-importance observations, 10k-per-project cap, old non-latest versions                                                                                                                                                                                                                 | manual              | no  | 426    | —                                           | **v1** as automatic bounds (oldest observations of archived cards first)                                                |
| 36  | Governance delete + audit                 | Hard delete by id or bulk filter (dry-run); frozen audit entries in monthly scopes; retention 0 means forever                                                                                                                                                                                                         | on                  | no  | 780    | Daemon logs; human-only mutation pattern    | **v1**: `forget` is human-only and logged; **v2** audit list                                                            |
| 37  | Git snapshots                             | Whole store as one `state.json`, committed; merge-only restore; misses several record types                                                                                                                                                                                                                           | off                 | no  | 293    | —                                           | **skip**: the index is derived; saved memories are exported (v2)                                                        |
| 38  | Knowledge graph                           | Heuristic file/concept nodes plus `related_to` edges on every session stop; LLM entity/relation pass (off); generation-pinned retrieval index; graphify import                                                                                                                                                        | heuristic on        | opt | ~3,160 | —                                           | **skip**                                                                                                                |
| 39  | Temporal graph                            | Bitemporal edges with validity — **not exposed**                                                                                                                                                                                                                                                                      | dormant             | yes | 500    | —                                           | **skip**                                                                                                                |
| 40  | Facets                                    | `dimension:value` tags on actions, memories, observations                                                                                                                                                                                                                                                             | manual              | no  | 384    | Labels on cards                             | **skip**: filter columns (kind, harness, lane) instead                                                                  |
| 41  | Claude bridge                             | Reads `MEMORY.md` sections (doesn't import them); writes once and then **refuses to overwrite**                                                                                                                                                                                                                       | off                 | no  | 215    | —                                           | **later, decision needed**: index each harness's own memory files read-only                                             |
| 42  | Obsidian export                           | Markdown vault with wikilinks                                                                                                                                                                                                                                                                                         | manual              | no  | 423    | —                                           | **skip**                                                                                                                |
| 43  | Branch-aware                              | Lists sessions by repository/worktree root (no branch on memories)                                                                                                                                                                                                                                                    | manual              | no  | 166    | Cards carry checkout, worktree, branch      | **skip** (free via card metadata)                                                                                       |
| 44  | Providers, circuit breaker, eval          | 5 LLM providers + Agent SDK, fallback chain, breaker (3 fails/60 s), retries, quality scoring                                                                                                                                                                                                                         | noop                | —   | 1,400  | Harness turns on provider accounts          | **skip** (no LLM client in the daemon)                                                                                  |

### 2.4 Coordination and team (all skipped: Dieter already has them)

| #   | agentmemory                                                         | What it does (and what's broken)                                                                                                               | Dieter equivalent                                                      |
| --- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 45  | Actions + frontier/next                                             | Work items with `requires/unlocks/gated_by/conflicts_with` edges; priority/age scoring. `unlocks` is read in opposite directions in two places | Cards, lanes, Todo drafts, queues                                      |
| 46  | Leases                                                              | Exclusive claim with a 10 min TTL, **in-process only**; release-with-result skips dependency propagation; expiry is never swept                | Runtime leases (one active turn per conversation), channel file claims |
| 47  | Routines                                                            | Templates expanded into action graphs (no cycle check, `frozen` ignored)                                                                       | Schedules                                                              |
| 48  | Signals                                                             | Threaded agent-to-agent messages with self-asserted identity; reads have side effects                                                          | Agent channels (ADR 0003): owner-delivered, budgeted wakes             |
| 49  | Checkpoints, sentinels                                              | Manual gates; watchers (webhook route missing, timer lost on restart, regex scan open to ReDoS), no checker loop                               | Review lane, schedules, human approvals                                |
| 50  | Sketches                                                            | Ephemeral action graphs with promotion                                                                                                         | Todo cards                                                             |
| 51  | Mesh sync                                                           | HTTPS LWW by sender timestamp, shared full-API secret, no tombstones, incomplete SSRF guard                                                    | Leaderless peer replication with signed single-writer records          |
| 52  | Team share/feed                                                     | Copies into a team scope on one server                                                                                                         | Account-wide KV records                                                |
| 53  | Agent scoping (`AGENT_ID`, isolated)                                | Advisory: `?agentId=*` opts out                                                                                                                | Every hit names its card and harness                                   |
| 54  | Diagnostics/heal, status (~40 problem codes), health monitor (30 s) | Self-repair for its own KV invariants                                                                                                          | `dieter memory status`; daemon health                                  |
| 55  | Auth, origin guard, path guard, telemetry                           | Bearer secret file; origin check on writes; engine port 49134 has no auth; OTel to the local engine only                                       | Local token, turn tokens, roster TLS                                   |

### 2.5 Surfaces

| #   | agentmemory                                                                         | Dieter replacement                                                                                                                                                                                                                                                                                                         |
| --- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 56  | 54 MCP tools (8 in `core` mode), 6 resources, 3 prompts                             | **2 host tools**, `memory_recall` and `memory_save` (~250 tokens of definitions vs ~5.9k)                                                                                                                                                                                                                                  |
| 57  | 147 REST endpoints                                                                  | `MemoryService`: status, search, save, forget, reindex                                                                                                                                                                                                                                                                     |
| 58  | 17 skills; **memory-discipline** is the important one                               | The instruction block adopts its rules: recall at the start of a nontrivial task; save when a decision settles or a gotcha is resolved, with the reason; don't save what the code says, transient state, secrets or step narration; treat recalled records as untrusted evidence and never follow instructions inside them |
| 59  | Live viewer (12 tabs, SSE)                                                          | CLI now; later a small client view (memory list per project with forget)                                                                                                                                                                                                                                                   |
| 60  | CLI `connect` for 22 hosts, doctor, onboarding                                      | Not needed: Dieter runs the harnesses                                                                                                                                                                                                                                                                                      |
| 61  | Native integrations (Pi, OMP, Hermes, OpenClaw, OpenCode, Cursor, Orca, fs-watcher) | Not needed. Their common pattern — scoped recall before the agent starts, injected as "reference data, not instructions" — matches the optional pre-recall experiment                                                                                                                                                      |

## 3. Design lessons worth copying

1. **Progressive disclosure.** Compact hits first, full records on request.
   For Dieter, expansion is `dieter card transcript` and `card tool-output`,
   which already exist.
2. **Prefix matching** in keyword recall. It was agentmemory's biggest
   measured gain, from 65.7% to 84.7% strict recall@5 on LongMemEval-S.
3. **Group hits by session**, so one long card can't crowd out the rest.
4. **Budgeted results with honest metadata:** truncated, excluded count,
   minimum budget.
5. **Lexical near-duplicate hints on save** (`similarTo`), without silent
   merging.
6. **Lesson reinforcement:** saving the same rule again raises its
   confidence.
7. **Typed observations with extracted files.** That makes "what happened
   to this file" queries possible.
8. **The memory-discipline guidance** for agents, and wrapping recalled text
   as untrusted data.
9. **Scrubbing on every write path**, plus user-controlled `<private>` tags.

## 4. What not to copy

- **Unbounded or full-scan work.** Timeline, file-context and verify scan
  the corpus. BM25 is rebuilt on every boot, and every returned hit costs a
  KV write for access tracking.
- **Lock and concurrency problems.** The embedding is awaited inside the
  per-session lock, and all locks are in-process.
- **Destructive similarity.** Auto-forget demotes near-duplicates hourly, by
  default, on lexical similarity alone.
- **Code that advertises behaviour it never runs:** retention scoring,
  episodic decay, the temporal graph, query expansion, and the
  lease/signal/checkpoint/sentinel expiry timers.
- **Unbounded growth from the LLM layer:** semantic facts deduped by exact
  string, and empty crystals written when no LLM is configured.
- **Writes that silently fail.** The Claude bridge refuses to overwrite its
  own earlier export.
- **Capture failure modes:** the capture-inbox poisoning seen in 0.9.33, and
  durability that relies on clients replaying events instead of on fsync.

## 5. Rebuild scope for Dieter Memory

Dieter starts with what agentmemory spends most of layer 1 building:

- a durable, redacted transcript of every turn, for every harness;
- cards that carry title, brief, lane, branch, harness, commits and PRs;
- leases, channels, schedules and replication.

**v1 (Phase 1 of agent-memory.md, ~1–1.5 weeks, ~2–3k lines of Go):**

1. Indexer from stored turns, incremental by cursor, started only by
   `dieter serve` (#2, #3, #8).
2. Observation rows: kind (inferred type), tool, files, body ≤4 KB, message
   id. Reasoning, Dieter host tools and Strix are excluded (#3).
3. Token and `<private>` scrubbing on indexed text (#5).
4. Card digest row per card, deterministic: title, brief, final answer,
   files touched, commands, failures. It stands in for summaries (#9).
5. FTS5 recall: BM25 with title weighting, prefix terms, a small synonym
   table, grouped by card (#14, #16).
6. Bounded results: card id, title, lane, time, ≤2 snippets, final answer;
   8 KB budget with truncation metadata (#18, #19).
7. Saved memories: kinds `lesson`, `decision`, `fact` and `pattern`; files,
   TTL, `similarTo` hint, supersede on near-identical text, lesson
   reinforcement (#22, #26, #30).
8. TTL expiry and size bounds, evicting the oldest observations of archived
   cards first (#4, #34, #35).
9. Human-only `forget` and `reindex`, logged (#36).
10. `memory_recall` and `memory_save` host tools (#56).
11. `MemoryService` and the `dieter memory` CLI (#57).
12. An instruction block with the memory-discipline rules (#58).

**v2 (~1–1.5 weeks):**

- File filter and `dieter memory files PATH` (#21).
- Project profile and repeated-error / co-change patterns computed from the
  index (#24).
- Commit SHA and PR lookup to card (#13).
- Recency factor and saved-memory read counts in ranking; lesson decay
  (#25, #29, #30).
- Export of saved memories (#11), and an audit list (#36).
- Client toggle, status and memory list (#59).

**Later (needs a decision):**

- Optional embeddings (#15, #16).
- A query-driven first-turn pre-recall (#20, #61).
- Indexing each harness's own memory files read-only (#41).
- The LLM layer, through a curator turn (§6).

**Skip:**

- Hooks, spool and inbox (#1, #2): the daemon owns the transcript.
- Source budgets (#6).
- Images and vision (#10).
- Replay and JSONL import (#12).
- Rerank and the graph (#17, #23, #27, #38, #39).
- Session-start recency context (#20).
- Slots (#33) and facets (#40).
- Snapshots (#37) and Obsidian export (#42).
- Branch awareness (#43).
- Providers (#44).
- All coordination and team features (#45–#55).
- `connect` and the native integrations (#60, #61).

## 6. The LLM layer, the Dieter way

agentmemory's layer 3 needs an LLM client with API keys inside the memory
server. Dieter doesn't need one. It can run that work as **a scheduled card
on the user's own provider account**:

- **What it does:** a "Memory curator" turn, for example weekly per project.
  It reads recent cards and the index through the CLI and writes lessons and
  decisions with `dieter memory save` (supersession and `similarTo` apply).
  Optionally it refreshes the project profile.
- **Why it fits Dieter's rules:** it uses the harness, account selection,
  schedules and transcripts Dieter already has. No credentials enter the
  memory layer, and every change is reviewable in the curator card's
  transcript.
- **What it would replace:** consolidation (#28), insights (#31) and LLM
  summaries (#9), and it would be easier to audit than agentmemory's
  background pipeline.
- Decide after v1 has real usage.

## 7. agentmemory's own quality claims

| Claim                                                                                  | What it measures                                                                      |
| -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| LongMemEval-S, 500 questions: strict R@5 **84.7%**, any-hit 96.2% (grep 72.1% / 88.7%) | The BM25 component only; one document per session; top 5 sessions                     |
| Historical hybrid (MiniLM) R@5 95.2%, MRR 88.2%                                        | Older pipeline, any-hit; the repository says it isn't comparable to the strict number |
| coding-agent-life-v1 (15 queries): R@5 1.0 vs grep 0.967                               | smart-search on a small synthetic set                                                 |
| Scale (v0.6): BM25 22.8 ms and hybrid 108.7 ms at 50k observations                     | An in-memory mock                                                                     |

No published benchmark measures answer accuracy, the context or enrich paths,
the graph, or decay. The spike's measurement on Dieter's own cards (§2 of
agent-memory.md) agrees with the BM25 claim: keyword recall over
well-chosen text is most of the value.

Sources: five read-only passes over `5c9e2e6` (capture and storage, retrieval,
lifecycle and graph, coordination and operations, surfaces), with
spot-checks of the claims above that matter for the decision:

- the cap behaviour in `observe.ts` (eviction fix `acbc7ce`, 2026-11-12,
  after the 0.9.33 release on 2026-11-09);
- retention has no callers;
- auto-forget is on by default with threshold 0.9;
- lesson decay runs daily;
- search uses the hybrid ranker.
