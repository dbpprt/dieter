# Proposal: native agentmemory support

Status: spike record, 2026-11-27. Superseded by
[agent-memory.md](agent-memory.md), which compares agentmemory, OpenViking and
a built-in index for a memory layer that runs inside Dieter and chooses the
built-in index. The measurements below are still the agentmemory evidence.

## TL;DR

[agentmemory](https://github.com/rohitg00/agentmemory) (Apache-2.0, npm
`@agentmemory/agentmemory` 0.9.33, 2026-11-18) is a local memory server for
coding agents. It captures session events, indexes them (BM25, optionally
local embeddings and a knowledge graph) and serves recall over REST and MCP.
It normally integrates per host: a Claude Code plugin with 12 hooks, Codex and
Cursor plugins, MCP for the rest.

The recommendation is a **Dieter-native integration that uses agentmemory as
an external memory provider** and installs none of its per-host plugins:

- **The daemon captures, not the harness.** After each turn, the conversation's
  owner daemon maps the turn's stored UI message parts onto agentmemory
  observations and posts them through a bounded, durable outbox. Those parts
  have already gone through vault redaction. The mapping is the same for
  Claude Code, Codex, OMP, Pi and DSH. Nothing is written into `~/.claude`,
  `~/.codex` or any other agent config. This matters because agentmemory's
  stock hooks deliberately skip Agent SDK sessions (`entrypoint === "sdk-ts"`),
  which is how Dieter runs Claude Code. With the plugin installed, Dieter's
  Claude turns would still never be captured.
- **Agents recall through two Dieter host tools**, `memory_recall` and
  `memory_save`, plus a `dieter memory search` CLI fallback. They do not get
  agentmemory's MCP server: in proxy mode that adds 48 tools (~5.9k tokens of
  definitions) to every turn, including delete, export, team-share and
  mesh-sync. Each hit names the **card** it came from, so an agent can read the
  full story with `dieter card transcript CARD`. In the live turn, the agent
  did exactly that without being told to.
- **The spike confirms that this works**, on this repository's real history
  (45 cards, 24,276 observations, three harnesses):
  - Keyword-only recall put the right card in the top 3 for 18/18 paraphrased
    questions (14 at rank 1, ~20 ms median).
  - Local embeddings put it at rank 1 for 17/18, with one miss (~40 ms median).
  - A live Claude Code turn in an empty project answered a question about
    earlier work correctly, using only memory.
- **Three limits shape the design:**
  1. agentmemory refuses observations past 500 per session. Refused events
     pile up as dead letters that are pruned only hourly. In the spike, about
     10k refusals filled the 10,000-entry capture inbox, and **all** capture
     then failed with 503. Dieter must keep its own per-card budget.
  2. Without an LLM provider, turn-start context injection returns the most
     recent session's raw snippets, unrelated to the new task. Recall must be
     driven by a query, not injected blindly.
  3. A managed, Dieter-supervised agentmemory isn't practical yet. It writes
     `~/.agentmemory` through 24 hard-coded paths that `--data-dir` doesn't
     move, and its CLI starts a detached six-process iii runtime that downloads
     worker binaries from `api.workers.iii.dev` on first start. Phase 1 connects
     to an agentmemory the user runs.

Phase 1 (capture sink, host tools, CLI, project opt-in) is about 1.5–2 weeks.
Phase 2 adds client settings and status, history backfill and a measured
first-turn pre-recall experiment. Phase 3 (managed runtime, a shared server
across machines) depends on upstream changes.

## 1. What agentmemory is (verified in source `5c9e2e6` and a live install)

| Aspect       | Facts                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Runtime      | Node ≥ 20 worker on the [iii engine](https://github.com/iii-hq/iii) 0.25.1 (Rust). The CLI downloads `iii` from GitHub (SHA-256 pinned) into `~/.agentmemory/bin`, then starts a detached `iii compose` daemon. That daemon downloads the `state` and `http` worker binaries from `api.workers.iii.dev` (content-hash directories) and runs: compose, reaper, engine, http, state and the node worker. |
| Listeners    | REST `3111` (the iii http worker), viewer `3113` (node), engine WebSocket `49134`. All three bind `127.0.0.1`. `--port N` moves them to N, N+2 and N+46023.                                                                                                                                                                                                                                            |
| Auth         | Bearer secret, generated into `~/.agentmemory/secret` (0600) unless `AGENTMEMORY_SECRET` is set. Its own clients send the stored secret only to loopback URLs. `livez` is public; `health` is not.                                                                                                                                                                                                     |
| Storage      | File-backed KV (`state_store.db` under the data directory), held in memory and saved every 2 s. An acknowledged write can be lost on a crash; capture clients keep events for the save window plus a margin. Redis is optional.                                                                                                                                                                        |
| Capture      | `POST /agentmemory/observe` `{hookType, sessionId, project, cwd, timestamp, data, eventId}`. Answers 201 accepted, 200 duplicate (same `eventId`), 503 inbox full (retryable). Hook types: `prompt_submit`, `post_tool_use`, `post_tool_failure`, `stop`, `session_start/end`, and others. `MAX_OBS_PER_SESSION` defaults to 500.                                                                      |
| Recall       | `smart-search` (BM25; hybrid with vectors and graph), compact results with `expandIds` expansion; `context` (budgeted block); `remember` (explicit memories, versioned). With `AGENT_ID` and `AGENTMEMORY_AGENT_SCOPE`, results can be scoped per agent.                                                                                                                                               |
| LLM features | Off unless a provider is selected (`AGENTMEMORY_LLM_PROVIDER`, API keys, or the opt-in Claude Agent SDK fallback). Without one: synthetic compression, no session summaries, no consolidation or graph extraction. Local embeddings (`EMBEDDING_PROVIDER=local`, MiniLM-L6, 384 dimensions) need the optional `@huggingface/transformers`.                                                             |
| Privacy      | Scrubs API keys, bearer tokens, PEM blocks, URL credentials and `<private>` tags on every write path (verified below). Engine telemetry is off unless enabled.                                                                                                                                                                                                                                         |
| Surface      | 147 REST endpoints, 48 MCP tools through the `@agentmemory/mcp` shim in proxy mode (7 without a server), 17 skills, a live viewer.                                                                                                                                                                                                                                                                     |

## 2. Options

| Option                                        | Capture                                                                                                                                                                                                                     | Recall                                                                                                                                                           | Verdict               |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| A. Document `agentmemory connect` per harness | Claude: none. The hooks skip `sdk-ts` sessions, and Dieter's per-account config dirs mirror only `mcpServers`. Codex: plugin hooks may fire, but under Codex's thread id, not the card. OMP, DSH, Pi: each its own install. | 48 MCP tools where the config is mirrored                                                                                                                        | Inconsistent; no      |
| B. Pass agentmemory's MCP server to turns     | None                                                                                                                                                                                                                        | Every adapter (Claude Code, Codex, ACP, Pi) accepts `mcpServers`, but it costs ~5.9k tokens per turn and exposes destructive tools; the agent picks the project. | Expensive, no capture |
| C. Native: daemon sink + host tools (this)    | Every harness, from Dieter's own redacted transcript; idempotent; no third-party config edits                                                                                                                               | Two curated tools (~250 tokens), project-scoped by the daemon, CLI fallback                                                                                      | **Recommended**       |
| D. Built-in Dieter index (no agentmemory)     | Same sink, into a Go FTS index                                                                                                                                                                                              | Same tools                                                                                                                                                       | Fallback, see §7      |

## 3. Spike results (2026-11-27, Apple Silicon, macOS 27)

Scripts and the redacted outcome are in
[`tools/spikes/agentmemory`](../../tools/spikes/agentmemory/README.md). All runs
used an isolated `HOME`, a temporary data directory and non-default ports
(13111, 14111). The operator's daemon, apps and agent configs were not
touched, and Dieter transcripts were only read through the CLI.

### 3.1 Install and runtime

| Measurement                              | Result                                                                                                                                     |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `npm install` (full / `--omit=optional`) | 957 MB / **98 MB** (the full install adds the Claude Code binary, ONNX runtime and transformers); 6.6 s                                    |
| Runtime downloads on first start         | `iii` 26 MB (GitHub); worker packages 23 MB **per data directory** (`api.workers.iii.dev`)                                                 |
| Processes                                | 6; the compose daemon is reparented to `launchd`, and the CLI exits after ~6 s                                                             |
| Listeners                                | REST, viewer and engine all on `127.0.0.1` only (checked with `lsof`)                                                                      |
| RSS after 24k observations               | 276 MB keyless; 634 MB with local embeddings                                                                                               |
| Disk after 24k observations              | 106 MB keyless; 154 MB with local embeddings                                                                                               |
| Files outside `--data-dir`               | `~/.agentmemory/{bin,.env,preferences.json,engine-state.json,compose-*.log}` and `~/Library/Application Support/agentmemory/capture-spool` |

### 3.2 REST contract (`probe.mjs`)

- Unauthenticated `health` returns 401; `livez` returns 200.
- `session/start` is an idempotent upsert, but it resets `startedAt` on each
  call.
- Five observations of different hook types were each accepted (201).
- Replaying an `eventId` returned **200 duplicate** with nothing stored.
- `remember` returned 201.
- `smart-search` took 3–7 ms on a small store.
- The same query under another project returned **0** hits.
- `context` took 4 ms.

### 3.3 Capture from Dieter transcripts (`replay.mjs`)

The prototype mapping, ported to Go in Phase 1:

| Dieter UI part (any harness)              | agentmemory observation                                        |
| ----------------------------------------- | -------------------------------------------------------------- |
| user `text`                               | `prompt_submit {prompt}`                                       |
| tool part, `output-available`             | `post_tool_use {tool_name, tool_input, tool_output}` (clipped) |
| tool part, `output-error`                 | `post_tool_failure {tool_name, tool_input, error}`             |
| last assistant `text` of a reply          | `stop {last_assistant_message}`                                |
| `reasoning`, `data-*`, Dieter's own tools | never sent                                                     |

One card is one session (`sessionId` = card id), and `agentId` is the harness.
Event ids hash card, message id and part index. Harness call ids are not
unique on their own: Codex reuses `item_2` across turns.

- **45 cards** (Codex, Claude Code, OMP) produced **24,276 observations**.
  Without a session cap, all were accepted: 5 ms per observation alone, ~20 ms
  while a second instance was also ingesting, ~16 ms with local embeddings.
- **Resume is safe:** re-sending a partially ingested card returned 217
  duplicates and no double writes.
- **Cap poisoning:** with the default `MAX_OBS_PER_SESSION=500`, 14,541
  observations were refused. The refusals became dead letters. Dead letters
  count toward `AGENTMEMORY_CAPTURE_INBOX_MAX` (10,000) and are pruned only
  hourly or at boot (`src/functions/capture.ts`). Once the inbox held 10,000
  dead letters, **every** session's capture returned
  `503 capture inbox is full`, including small, healthy sessions. Upstream
  main changed the cap to evict the lowest-value observations instead
  (`acbc7ce`, 2026-11-12). That fix is not in any release yet; 0.9.33
  shipped on 2026-11-09.

### 3.4 Recall quality (`eval.mjs`)

18 paraphrased problem statements, written the way a later agent would ask
(for example, "card snaps back to its old lane after dragging until sync
finishes"). Each one is scored against the card where the work happened.

| Store                                           | hit@1 | hit@3 | hit@5 | MRR   | p50   |
| ----------------------------------------------- | ----- | ----- | ----- | ----- | ----- |
| Keyless BM25, capped at 500 (31 cards ingested) | 9     | 11    | 11    | 0.556 | 13 ms |
| **Keyless BM25, all cards**                     | 14    | 18    | 18    | 0.889 | 20 ms |
| **Local MiniLM hybrid, all cards**              | 17    | 17    | 17    | 0.944 | 40 ms |

All seven misses in the capped run were cards whose capture was refused (§3.3).
Hybrid search fixed three of BM25's rank-2 answers but lost one query that BM25
had at rank 2. Keyless BM25 is a good default. Embeddings are an opt-in that
costs ~360 MB more RAM. Caveat: I wrote the queries knowing the cards'
prompts. The set is small and illustrative, not a benchmark.

### 3.5 Live turn with host tools (`turn.mjs`)

**Claude Code** (Sonnet, low effort):

- The turn ran in an empty git project, so the code couldn't answer.
- The instructions described the memory tools in two sentences.
- The prompt didn't mention memory: "Dieter stays offline for minutes after my
  MacBook wakes from sleep. What causes it, and what was done about it?"
- Sequence:
  1. `ToolSearch` (Claude defers host tools)
  2. `memory_recall` (40 ms, 5 hits)
  3. `bash dieter card transcript c_2c968e…` twice
  4. The answer
- It gave the correct cause (no gRPC keepalive or deadlines, stall detection
  missing a stream that was dead from the start) and the fix (PR #144) in
  14.8 s.
- It reported the PR as unmerged, because the source transcript ended before
  the merge. Recalled history can be stale, so hits must carry timestamps and
  card ids.

**Codex** was not run. The default `~/.codex` login's refresh returned 401,
and I did not retry it, because Dieter refreshes Codex logins through provider
accounts. Host tools already reach every adapter (`present_content` and the
background-process tools use the same path).

### 3.6 Other checks

- **Secret scrubbing:** fake GitHub, AWS and Anthropic keys, URL credentials
  and a `<private>` block were redacted in API output and absent from
  `state_store.db`.
- **Turn-start context** (`/context`, keyless): the most recent session's raw
  snippets, chosen by recency rather than relevance and HTML-escaped. That was
  1.8 kB at budget 600 and 5.6 kB at budget 2000. Injecting it into every turn
  would be noise.
- **MCP passthrough** (`mcp-surface.mjs`): 48 tools, 23.6 kB of definitions.
  `AGENTMEMORY_TOOLS=core` has no effect on the shim (documented upstream).

## 4. Design

### 4.1 Shape

```text
harness worker ──host tools──▶ daemon MemoryService ──HTTP (loopback, bearer)──▶ agentmemory
      ▲                               ▲    ▲
      │ instructions block            │    └── capture sink (turn finished → outbox → /observe)
dieter memory search (CLI) ───────────┘
```

A small provider interface (`internal/memory`) hides agentmemory behind
`Status`, `BeginSession`, `Observe`, `EndSession`, `Search`, `Expand`, `Save`
and `Forget`, so §7's built-in index could replace it.

### 4.2 Connection (per daemon, not replicated)

- Machine-local setting: provider `off | agentmemory` and URL, default
  `http://127.0.0.1:3111`.
- Phase 1 accepts only loopback `http` URLs. The bearer comes from
  `AGENTMEMORY_SECRET` in the daemon environment, or is read on demand from
  `~/.agentmemory/secret` for loopback URLs, the same as agentmemory's own
  clients. Dieter never copies it.
- `dieter memory status` reports the URL, reachability (`livez`), auth, version,
  index mode (BM25 or hybrid), the outbox backlog and the last error.

### 4.3 Project opt-in (replicated)

- A portable project setting, "Project memory", off by default.
- When it is on, a project's conversations are captured on their owner daemon
  and their turns get the memory tools, if that daemon's provider is
  connected.
- Project key sent to agentmemory: the basename of the checkout's repository
  root, the same key agentmemory's own hooks derive (worktrees resolve to the
  main repository). Dieter turns and standalone agent sessions in the same
  repository then share one memory. See decision 2.

### 4.4 Capture sink (`internal/host/memory`, started only by `dieter serve`)

- **Trigger:** the engine signals "turn finished" (card, turn) after `finish`.
  The sink reads that turn's stored messages, which are already
  vault-redacted, applies the §3.3 mapping and appends records to an outbox
  under `DIETER_HOME/memory/` (atomic writes under the central lock).
- **Drain:** a bounded loop that never blocks or fails a turn.
  - `session/start` once per card and boot.
  - `observe` with the hashed event ids, at most 4 in flight.
  - `session/end {final:false}` after each turn.
  - 503 pauses all draining with exponential backoff up to 5 min. 4xx drops
    the record and counts it. 2xx records are kept for agentmemory's
    `durableAfterMs` window, then deleted. A changed `bootId` means resend.
- **Bounds:**
  - Per-card budget of 400, below the server's 500. Prompts, final replies and
    failures always count; tool calls fill what remains. When the budget runs
    out, tool calls are summarized as one `stop`-style note per turn.
  - Fields clipped to 4 KB.
  - Outbox capped at 8 MiB and 7 days.
  - Never send `reasoning`, Dieter host-tool calls (`present_content`,
    background processes), Strix cards, or forked seeds that were already
    captured.
- **No double capture:** set `AGENTMEMORY_SDK_CHILD=1` in the worker
  environment.
  - Every capture script in agentmemory's plugin (`plugin/scripts`, used by
    the Claude Code, Codex, Cursor, Devin and Copilot hooks) checks it and
    no-ops, so those plugins stay silent inside Dieter turns.
  - The native OMP and Pi extensions (`integrations/omp`, `integrations/pi`)
    do not check it. Dieter's OMP launch forwards `HOME` and
    `PI_CODING_AGENT_DIR`, so an `agentmemory connect omp` install may load
    inside Dieter's OMP turns. Phase 1 must check this. If it does load,
    exclude the extension in Dieter's OMP runtime config.
  - Also leave an `agentmemory` entry out of the `mcpServers` that
    `internal/engine/accounts/homes.go` mirrors into account config dirs when
    project memory is on, so the turn doesn't see both surfaces.

### 4.5 Recall

- **Host tools** in `runner.mjs`, offered only when the request enables
  memory:
  - `memory_recall {query, limit≤10}`
  - `memory_save {content, kind: lesson|decision|fact|pattern, concepts}`
- They call the daemon through a host-call bridge, a generalization of the
  background-process bridge (`processCall` frames). The worker never holds the
  secret or chooses the project.
- The daemon runs `smart-search` and then `expandIds`, and returns at most 10
  hits of at most 600 characters (8 KB total). Each hit carries the card id,
  card title and timestamp. The result is labelled as historical notes that
  may be stale.
- **CLI:** `dieter memory search|save` work inside turns (the fallback for
  harnesses that defer host tools, as Claude did) and for people.
  `dieter memory forget` and `dieter memory backfill` are human-only and
  refuse a turn token, like the folder and trust mutations.
- **Instructions:** `prompt.MemoryInstructions(cli)` is a block of at most 1 KB
  next to the vault and folder blocks. It names the tools and the CLI fallback,
  and tells the agent to recall before investigating from scratch and to save
  only durable lessons.
- **No automatic injection** in Phase 1 (§3.6). Phase 2 tests a query-driven
  pre-recall on a conversation's first turn: the top 3 hits as pointers,
  at most 1 KB, behind a flag, measured on a fixture.

### 4.6 API and CLI parity

`api/proto/dieter/v1/memory.proto` adds `MemoryService` with these RPCs:

- `GetMemoryStatus`
- `SearchMemory`
- `SaveMemory`
- `ForgetMemory` (refuses a turn token)
- `BackfillMemory` (refuses a turn token; Phase 2)

The CLI group is `dieter memory`. The usual parity steps apply: the
`rpcCommand` map, offline help, the generated CLI reference, and end-to-end
tests over local, direct TLS and relay against a fake provider.
`--machine` searches another daemon's memory through the tunnel. Responses are
bounded and nothing is stored on the gateway.

### 4.7 Clients (Phase 2)

- A project settings toggle and a per-machine status row (connected, not
  running, BM25 or hybrid, backlog, last error).
- The rules live in the Kotlin core (`apps/kotlin/core`).
- No memory browser: agentmemory's viewer already exists at `127.0.0.1:3113`,
  and Dieter has no web UI.

### 4.8 Multi-machine

- Memory is per machine: a conversation is captured on its owner daemon, and
  recall searches that daemon's provider.
- Phase 3 could point several daemons at one user-run agentmemory over `https`
  (secret in the vault) or use agentmemory's mesh sync.
- Memory never goes through gateway storage.

## 5. Safety and invariants

| Invariant or risk                        | Handling                                                                                                                                                                                      |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dieter owns transcripts; new data egress | Copies of redacted turn content go to a local, user-run process, opt-in per project. This is a product-level data flow, so it gets **ADR 0007** before Phase 1 code.                          |
| `DIETER_HOME` storage, atomic writes     | The outbox and status live under `DIETER_HOME/memory`, written with `fsx.WriteFile` under `LockHome`. agentmemory's store is its own (outside repositories).                                  |
| Loopback-only raw API                    | Unchanged. Dieter calls a loopback-bound agentmemory with a bearer; non-loopback URLs are refused until Phase 3 (`https` only).                                                               |
| Gateway stores no project data           | Memory never touches the gateway; `--machine` calls ride the opaque tunnel.                                                                                                                   |
| Background work only in `serve`          | The sink starts in `internal/daemon`; handler construction in tests starts nothing.                                                                                                           |
| Secrets                                  | Two layers: vault redaction before storage, then agentmemory's scrubbing (§3.6). `reasoning` is never sent. The bearer is never logged, copied or put on a request line.                      |
| Cross-project leakage                    | The daemon sets `project`; tools take no project argument. Verified as 0 cross-project hits (§3.2).                                                                                           |
| Memory poisoning, staleness              | Recall is labelled historical and untrusted, with timestamps and card ids, and is never put into system instructions. Agents can only add memories; forget, import and export are human-only. |
| Resource bounds                          | Per-card budget, outbox size and age, in-flight limit, response size limits (§4.4, §4.5).                                                                                                     |
| Strix                                    | Excluded from capture and from memory tools.                                                                                                                                                  |

## 6. Plan

1. **ADR 0007 (agent memory)**: the data flow, the opt-in, the human-only
   mutations, the provider interface.
2. **Phase 1 (~1.5–2 weeks):**
   - `internal/memory` (interface and agentmemory client) and
     `internal/host/memory` (sink, outbox, budget, backoff).
   - Mapping golden tests from fixture transcripts covering Codex, Claude
     Code, OMP and Pi parts.
   - A fake agentmemory in `internal/testkit` that simulates 503, duplicates
     and the cap.
   - `MemoryService` and the CLI.
   - Host tools and the bridge in `runner.mjs`, with `node --test` coverage.
   - `prompt.MemoryInstructions`, the `AGENTMEMORY_SDK_CHILD` environment and
     the MCP mirror exclusion.
   - The project setting.
   - Docs: `site/content/docs`, `.agents/skills/dieter-cli/SKILL.md`, and an
     update to `docs/threat-model.md`.
3. **Phase 2 (~1 week):**
   - Client toggle and status.
   - `dieter memory backfill --project` (§3.3 replay in Go, budgeted).
   - The first-turn pre-recall experiment, with a fixture A/B.
4. **Phase 3 (needs upstream):** a managed runtime (pinned install with
   `--omit=optional`, data under `DIETER_HOME`, supervised lifecycle) and a
   shared server across machines.

Upstream issues worth filing (with your OK):

- Cap refusals poison the capture inbox (§3.3).
- No way to move `~/.agentmemory` (needed for supervision and isolation).
- Compose has no foreground mode for supervisors.
- `session/start` resets `startedAt`.
- `/context` output is HTML-escaped.

## 7. Decisions needed

1. **agentmemory as an external provider (recommended) or a built-in index.**
   Dieter already stores every transcript. A Go full-text index would give
   §3.4's keyword recall without six extra processes and ~280 MB. agentmemory
   adds memory shared with agent sessions outside Dieter, local embeddings, a
   viewer, consolidation and the graph. The provider interface keeps both open.
2. **Project key:** repository basename (recommended; shared with agentmemory's
   own hooks, same collision risk as their default) or the Dieter project id
   (stable across renames and machines, but not shared).
3. **Default:** opt-in per project (recommended) or on for every project when a
   provider is connected.
4. **Managed mode:** defer to Phase 3 (recommended) or start it now despite
   the `~/.agentmemory` writes and the detached runtime.

## 8. Reproducing the spike

See [`tools/spikes/agentmemory/README.md`](../../tools/spikes/agentmemory/README.md).
The outcome without transcript content is in `results/2026-11-27.json`.
