# Sync and UI coherence assessment — 29 September 2026

Card `c_e0deebade8aa42afae023f81`. This is a read-only analysis. No code, client,
daemon, gateway, or central store was changed. Evidence comes from source at the
current working tree and from read-only inspection of this Mac mini's live
daemon (`d_PakO2VZ49MQ8to2U`, release 0.4.326).

## Verdict

Yes, the architecture needs to change. The change is targeted, not a rewrite.
The daemon already has a durable, cursor-based `WatchSync`. The system around it
behaves like "one machine's world at a time, plus polling":

1. **Each client holds exactly one live feed, to one "active" machine.** Opening,
   starting, or moving a card owned by another machine tears the session down and
   reconnects the whole app to that card's owner. That reconnect is why a click
   "reveals" the true state.
2. **Cards owned by other machines reach the feed only through slow, eventual
   paths.** Peer replication runs in 15 s rounds that reach at most 2 peers, and
   clients poll every 15 s over fresh connections. Both paths are degraded today
   (see live evidence), and their failures are silent.
3. **The feed invalidates and recomputes; it is not a changefeed.** Events carry
   no entity keys and no command IDs. A client cannot tell when its own write has
   landed. Every commit rebuilds the entire workspace once per subscriber.
4. **Each client merges several machines' partial views itself.** Mac holds
   about 12 copies of card state and has roughly 15 write paths that bypass its
   reducer. Android holds 19 copies with at least 6 writers. Most previous flicker
   and bounce fixes patched this layer (see the 09-23 board-flicker, 09-25 causal
   `state_fields`, and 09-28 board-lifecycle fixes).

"Sync and UI are two concepts" is an accurate description. The UI can see a
fresh state only by reconnecting, and it can confirm a mutation only by guessing
whether a later snapshot contains it.

**Target:** each client attaches to one daemon and receives one account-wide,
entity-keyed feed from it. Owners push runtime and summary changes to that daemon
in real time over daemon-to-daemon streams. RPC routing is separate from the
feed. Each client has a single reducer that confirms optimistic changes by
`command_id` and commit cursor.

## Symptom → cause

| Symptom | Primary cause | Contributing causes |
|---|---|---|
| Inbox card says Running and jumps to Done when clicked | The card is owned by another machine. Clicking moves the only live feed to the owner. | Peer replication is failing or lagging. Turn end writes `idle` late. Android never folds fresh `detail.card` back into its lists. |
| Starting or moving a card feels disconnected | For a card on a non-active machine, the whole app reconnects before the action runs. Android waits up to 20 s for the route before it shows the optimistic card. | One action becomes several separately published commits, so intermediate states are visible. Confirmation is guesswork because `command_id` is never populated. |
| Archiving lags, or the card comes back | Archive is not optimistic on either client. The Mac replica's upsert re-adds cards, and Mac `BoardProjection` has no archived filter. | On Android, a lagging replica's `archived=false` can win because merge order decides. |
| Flicker | Frequent resets (full snapshots) and stale cached snapshots applied on machine switches | Per-frame `lastSyncedAt` / `lastConnectedAtMs` invalidation. Four sources with different window sizes feed the open transcript. Mac's Changes tab writes back a stale card every 5 s. |
| "Sync happening frequently" | 300–575 `store_changed` events per minute under agent load, many of them no-ops. Each one forces a whole-workspace rebuild and a frame. | The "Syncing" indicator is driven by `projection_pending` heartbeats. Conversation-stream hiccups raise app-wide reconnect banners. |

## Live evidence (read-only)

- **Sync journal, 13:00–13:24 UTC.** 14,441 events: 7,602 `store_changed` and
  6,839 `conversation_changed`. Under agent load there were 300–575
  `store_changed` per minute; quieter minutes had 33–75. No event carries a
  command ID.
- **Journal compaction rotated the sync epoch at 13:07 UTC**
  (`internal/store/sync.go:244`). Every connected client gets a full reset when
  this happens. At this event rate, a 16 MiB journal compacts every few hours of
  active use.
- **Gateway ingress.** `gateway.getdieter.com:443` refused about half of new TCP
  connections while probing. At 1 s spacing the pattern was
  `R ok ok ok R R ok R R ok` (R = refused). Port 3478 accepted 5/5. The daemon's
  established tunnel stayed connected, and `/healthz` returned 200 when a
  connection got through. `dieter machine list` failed repeatedly with
  `connection refused`.
- **Daemon log, today.** 178 "peer store synchronization pending" warnings. 163
  of them are connection-refused dials to `91.132.146.140:443`. Each peer round
  and each client poll opens a new connection, so every freshness path is exposed
  to this.
- **Peer status: 4 peers.**
  - `d_N9TV9pa9QBVGlfBU` (WebRTC/TURN) and `d_er6e1D_iJlop7H92` (relay) are
    complete.
  - `d_jg-8jSKHuxu9ucTa` is failing with `DeadlineExceeded`. At 13:35 local time
    it also rejected a push with `unknown shared object field: commentCount`,
    the same schema skew as the 09-25 incident in
    `board-lookup-investigation-2026-09-28.md`.
  - `d_H5yBBqECIxCzQSTG` last succeeded at 2026-09-28 15:34 UTC.
  - Result: on this daemon's feed, cards owned by the two failing machines become
    fresh only when a client navigates to them.
- **Caveat on the rate numbers.** The running 0.4.326 daemon predates the working
  tree's conditional `UpdateCardCache` change
  (`assessment-remediation-2026-09-29.md`, step 3a). Today's rate therefore
  overstates what that change will leave. The other no-op publishers below remain
  in the working tree.

## How it works today

```
Mutation ─► beginWrite(): pending sync event prepared BEFORE domain comparison
         ─► domain write ─► commit: events.ndjson += {seq, kind} (no entity keys, no command_id)
                             metadata-highwater advances unless kind == conversation_changed
         ─► notifyChanges() + fsnotify

Each WatchSync subscriber (internal/server/sync.go):
  wake (notify | 2 s tick, ≥25 ms apart) ─► GlobalStateContext(): re-read every card,
  archived included, with peer overlay (cached only if all new events are conversation_changed)
  ─► hydrate ≤32 local conversations ─► proto.Equal diff vs last frame ─► SHA-256 projection id
  (in-memory resume cache: 64 entries / 32 MiB) ─► delta | cursor-only | reset | heartbeat

Other machines ─► PeerSync: every 15 s + jitter (1 s after local change), ≤2 peers per round,
  new gateway connection per round, backoff to 2 min ─► MergePeerRecords ─► store_changed

Mac / Android:
  one WatchSync to the "active" machine (conversation_limit 30, recent 8, heartbeat 5 s)
  + GetState(all_projects) poll of every other machine every 15 s over fresh connections
  + GetConversation/WatchConversation for the open card
  + mutation responses, tab polls, disk cache ─► many independent writers into the UI state
  open/start/move a foreign card ─► connect(to: owner) / restart() ─► whole session re-bootstraps
```

## Root causes

### 1. The live feed is scoped to one daemon, and navigation moves it (confirmed)

**Contract vs. behaviour.** The proto calls `WatchSync` "the daemon-wide durable
change stream". An account has N daemons (this one has 5). Neither client runs
`WatchSync` against more than one of them.

**What moves the feed:**

- **Mac.** Opening a card (`DieterStore+Conversation.swift:133`) and starting one
  (`:687`) call `ensureConversationConnection`. That function calls
  `connect(to: target)` (`DieterStore+SharedProjects.swift:34-43`), which
  re-bootstraps GetState and WatchSync on the owner.
- **Android.** Opening, sending, starting, and moving to Running
  (`DieterViewModel.kt:1786, 1873, 1921, 1952, 2009`) call
  `ensureConversationRoute` → `ensureMachineRoute`. That sets the preferred
  endpoint, calls `restart()` (`DieterConnectionManager.kt:470-486, 896-913`), and
  waits up to 20 s. `restart()` shuts down both channels, which kills the
  conversation, KV, presence, and quota streams, and sets the phase to
  CONNECTING.

**Polls of other machines are silent when they fail.** Mac uses `try?`
(`DieterStore+Connection.swift` around 967/976). Android uses `runCatching`
(`DieterConnectionManager.kt:1348`). The UI keeps showing "LIVE" for data that is
up to minutes old.

### 2. Runtime status travels on the eventually consistent peer store (confirmed)

`runtime` is stored with the card and is not computed at read time. For a card
owned by another machine, it reaches the attached daemon only through the
owner-signed `summary` register (`internal/store/shared.go` around 505-522). That
register is replicated by `PeerSync` (`internal/daemon/peer.go` around 259-305
and 362):

- a 1 s coalesce after a local change, otherwise 15 s rounds;
- at most 2 peers per round, taken round-robin;
- backoff up to 2 minutes on errors;
- up to 15 s of WebRTC attempt before falling back to relay.

`peer-store.md` describes replication as "eventual, not a promise". That suits
durable shared metadata. It does not suit an interactive "is this agent still
running" signal. Owner-only fields (workspace, token usage, prompt, `updatedAt`)
are never replicated at all.

### 3. The feed carries invalidations, not changes (confirmed)

- **No identity on events.** Events carry only `{sequence, kind, createdAt}`
  (`internal/store/sync.go:146`). `SyncEvent.command_id` exists in the proto and
  is never filled. Mutation RPCs return an entity but no commit cursor. Neither
  client reads `events`, `command_id`, `reset`, or `observed_cursor`.
- **Rebuild cost.** Every `store_changed` rematerializes all cards, archived ones
  included, while holding the central writer lock. The resulting full projections
  are then diffed with `proto.Equal`. The cost scales with total cards and
  subscribers, not with what changed.
- **Resume depends on memory.** A cursor resumes only while its content-hash
  projection is still in the in-memory cache (`internal/server/sync_resume.go`).
  That cache holds 64 entries / 32 MiB and is shared by all subscribers.
  Identical content at a newer cursor overwrites the older entry (`:40-43`), so
  frequent no-op publishes make older cursors unresumable. Cache misses, daemon
  restarts, and epoch rotation at compaction all force full resets.
- **No-op writes publish.** `beginWrite()` prepares a `store_changed` event
  before the caller decides whether anything changed (`internal/store/store.go:192`,
  finish at `:242`):
  - `MergePeerRecords` returns early when nothing merged (`internal/store/peer.go:216`),
    but its publish was prepared at `:184`. It runs for every pull page,
    including empty ones (`internal/daemon/peer.go:475`).
  - `MarkConversationRead` has the same pattern for an already-seen response
    (`internal/store/conversation.go:937, 952`).
  - Lease acquire and release, and workspace saves (reported by the daemon trace).
  - Each one triggers a full rebuild on every subscriber and a cursor-only frame.
    It also defeats `GetState if_not_modified`, which both clients poll with.
- **Stale cards on text-only commits.** A text-only batch rewrites the card
  (`lastActivityAt`, `updatedAt`) under `conversation_changed`. That kind does not
  advance metadata-highwater (`internal/store/sync.go:183`), so
  `GlobalStateContext` keeps serving the cached card
  (`internal/store/materialized_state.go:97-111`).

**Resets from the transport:**

- Direct-TLS streams are cut at token expiry plus 10 s
  (`internal/daemon/direct.go:101`). Tokens last 5 minutes.
- Android tears down the connection for each credential refresh, about every
  4.5 minutes.
- The gateway ends a slow stream with `ResourceExhausted` when its 64-frame
  queue fills, instead of superseding queued frames.

### 4. State transitions are late and split across commits (confirmed)

- **Turn end.** After the `finish` chunk, the conversation is idle, but the card
  is deliberately kept `running` (`internal/app/turn_execution.go:126`). The
  `idle` write happens only after the worker exits, provider cleanup runs, a git
  workspace refresh completes (timeout 15 s, `:82-84`), and the lease is released
  (`:85`).
  - The open transcript shows the finished reply while the Inbox still says
    Running.
  - Mac's Inbox checks "active" before "unread"
    (`apps/mac/Sources/DieterMac/Model/InboxActivity.swift:65-70`).
- **Stop.** `CancelCard` writes no state. The card stays `running` through
  cleanup.
- **`waiting_for_user`.** No server path sets it, so the client's "Answer" state
  can't come from a real turn.
- **Split actions.** Each of these publishes several separate commits, so
  clients render the intermediate states:
  - Turn start: lease → user message → turn start → card cache →
    prompt-sent/move.
  - Move to Running: lane running + runtime idle, then start (or roll back).
  - Move to Done: move, then auto-archive. `ArchiveDoneCards` commits without an
    in-process notify (`internal/store/cards.go:645-674`); watchers wake on
    fsnotify or the 2 s tick.

### 5. Client state has many copies and many writers (confirmed)

**Mac** (paths under `apps/mac/Sources/`):

- Views read different subsets. Board reads `state.cards`. Inbox unions
  `navigationCards`, `chats`, `state`, `syncSnapshot.conversations`, and
  `conversation`, choosing the "freshest" copy by timestamp. Sidebar counts read
  `navigationCards`.
- Writers that bypass the reducer:
  - The Changes tab upserts a stale card copy every 5 s
    (`WorktreeChangesModel.swift` → `DieterStore+Workspace.swift:213-225`).
  - `acceptState` never removes cards and can move fields backwards.
  - Label changes write only `state.cards`.
- Archive can resurrect a card, because upsert re-adds it and `BoardProjection`
  has no archived filter.
- On a machine switch, the stale cached snapshot is applied first as the owner's
  complete list.

**Android:**

- Fresh `detail.card` from every conversation source updates only
  `activeConversations`. It never reaches the `cards` or `chats` lists that the
  Inbox reads.
- `SharedDirectory.sharedItems` keeps fields from the last list element, so a
  lagging replica's title, archived, pinned, or labels can win. Only placement and
  runtime are merged causally.
- The view model's `replacingCard` writes a second, separately patched copy.
- `globalSnapshot` and the cursor are mutated from the IO collector, the main
  thread, and the outbox drain without synchronization.

**Both clients:**

- `lastSyncedAt` / `lastConnectedAtMs` changes on every data frame, which
  redraws or recomposes the whole app.
- The open transcript is fed by WatchSync (30 messages) and by
  GetConversation/WatchConversation (60 messages). The top of the transcript
  therefore drops and returns during a turn.

## Architecture decision

| Option | Assessment |
|---|---|
| **A. Client fan-in.** One `WatchSync` per online machine, merged in each client. | No daemon change. However, it needs N relay streams per client (16 per daemon, 128 gateway-wide) and Android battery. It also multiplies the client-side merge code that caused most past flicker, implemented in Swift, Kotlin, and iOS. |
| **B. Account feed from the attached daemon. (Recommended)** | The daemon a client attaches to publishes the account view: shared metadata from its peer replica, plus owner summaries received over live, bounded daemon-to-daemon subscriptions. The merge happens once, in Go, under test. Clients never move their feed. Conversation streams and mutations go to the owner over scoped connections. |
| **C. Gateway fan-out.** | Excluded. The gateway must not hold projects, cards, or transcripts. |

**B against the invariants:**

- The gateway stores nothing new.
- Conversations keep one execution owner, and the owner remains authoritative
  for runtime.
- The shared store stays leaderless. The attached daemon is only a read and
  merge point for its clients, not a project owner.
- Streams and queues stay bounded: one bounded summary stream per online peer.
- The raw data plane stays loopback-only.

## Plan

Each phase ships independently. Phase 0 items are small and each fixes a specific
symptom.

### Phase 0 — Stop the visible damage

1. **Gateway ingress.** Find why `:443` refuses about half of new connections.
   Candidates include the host firewall, HAProxy listener state, and a stale
   deployment slot. Operations work on the production host; not done here.
2. **Peer health.**
   - Upgrade or re-enroll `d_jg-8jSKHuxu9ucTa` and `d_H5yBBqECIxCzQSTG`.
   - Enforce the published minimum daemon floor, so a schema-incompatible peer
     is rejected clearly rather than silently stalling replication.
   - Show per-machine sync staleness in both clients (open item from
     `product-assessment-2026-09-28.md`).
3. **Turn end.**
   - Write the final runtime in the same commit as the terminal chunk, or write
     an explicit `finishing` state then.
   - Run the git refresh afterwards.
   - Write `cancelling` on Stop.
4. **No-op publishes.**
   - Make `MergePeerRecords` and `MarkConversationRead` conditional writes
     (`beginConditionalWrite` already exists).
   - Give leases a kind that doesn't invalidate the projection.
   - Send `WatchKV` frames only when matching entries change.
   - Ship the `UpdateCardCache` fix that is already in the tree.
5. **Clients: quick fixes.**
   - Android: fold `detail.card` into the list stores through `mergeCardState`.
   - Mac: remove the Changes-tab card write-back, and filter archived cards in
     `BoardProjection`.
   - Both: make archive optimistic, log and surface poll failures, and remove
     per-frame timestamp invalidation.
6. **Stop moving the feed on navigation.** Route conversation streams and
   mutations for foreign cards over scoped connections. Mac already uses these
   for the outbox and fleet features. The feed stays on its machine.
7. **Transport resets.**
   - Refresh the direct token per RPC, not by reconnecting. `internal/clientcore/route.go`
     already does this.
   - Let direct-TLS streams renew instead of cutting at expiry.
   - Don't rotate the epoch at compaction when the retained rows still cover
     live cursors.

### Phase 1 — Entity-keyed changefeed with read-your-writes

- **Journal.** Record touched entity keys (card, board, project, conversation,
  settings) and the `command_id` on each sync event.
- **Delta construction.** Build deltas by re-reading only the touched entities.
  Resume by replaying the journal from the client's cursor. Reset only when
  compaction has passed that cursor. This removes the content-hash projection
  cache and the whole-workspace rebuild per commit.
- **Write acknowledgement.** Mutation RPCs return `{command_id, commit cursor}`.
  Clients hold an optimistic overlay until the feed cursor reaches the commit
  cursor, or the RPC fails.
- **Fewer commits.** Collapse turn start, move→start, and move→archive into a
  single publish each.

### Phase 2 — Account-wide feed

- **Owner summary stream.** Add a bounded, cursor-resumable, daemon-to-daemon
  subscription for owner summaries: runtime, lane/placement, `responseSeq`,
  `lastActivityAt`, title, and token usage.
  - It runs over a long-lived peer link, not a new gateway dial per round.
  - The attached daemon folds summaries into its projection and publishes them
    immediately.
  - The peer store keeps durable metadata and offline catch-up.
- **Clients.** Attach once. Mac attaches to the local daemon when there is one;
  Android attaches to its preferred machine. Remove the 15 s all-machine polls.
- **Offline owners.** The feed marks their cards with explicit staleness, never
  with a silently old "Running".

### Phase 3 — One reducer per client

- **Store.** One normalized entity store per client, with all views derived.
  Every write goes through `apply(frame | receipt | failure)`. Delete the direct
  upserts, `replacingCard`, the Changes-tab write-back, and the extra
  post-mutation GetState calls.
- **Open transcript.** `WatchConversation` alone owns it. WatchSync
  conversations are used only for first paint and Inbox details.
- **Conformance.** Shared golden fixtures (frame sequence → expected entity
  state), run from Go, Swift, and Kotlin tests. Once the daemon merges the
  account view, this reducer is small. Whether to adopt the gomobile core can be
  decided separately.

### Acceptance measures

| Measure | Target |
|---|---|
| Runtime change on machine B, seen by a client attached to A, with no navigation | ≤1 s p95 |
| Inbox showing Running after the transcript's terminal chunk | Never |
| No-op requests (read receipt, empty peer pull, lease churn) | Advance no sequence and send no frame |
| Token refresh, route change, and card navigation | No reset or snapshot |
| `store_changed` rate with one agent streaming | Bounded by semantic changes (measured before and after) |
| Every optimistic action | Confirmed or reverted by `command_id`; no bounce |

## `internal/clientcore` (untracked, in progress elsewhere)

`internal/clientcore` and `mobile/dietercore` are a gomobile client core. They
provide a route (per-RPC token refresh and pinned TLS), a replica that buffers
while `projection_pending` is set, and a CreateCard-only outbox. Nothing imports
them yet.

As written, the core would not fix these symptoms:

- It targets one machine per core (`Config.DaemonID`).
- It replaces cards without the causal merge in `cardstate.go`.
- It confirms by RPC acknowledgement rather than by feed.
- It fsyncs the full snapshot on every cursor change.
- A delivery failure tears down the whole session, including WatchSync.

With Phase 1 and Phase 2 in place, its reducer can stay thin. Its route layer is
the right pattern for Phase 0, item 7.

## Not verified / open

- **Which machine each client was attached to** when the Running→Done symptom
  appeared, and who owned that card. To check, compare the card's
  `ownerDaemonId` with the attached machine. On Android, look for
  `transport restart` in `adb logcat -s DieterSync`.
- **The cause of the gateway refusals.** The gateway host was not inspected;
  this needs production operations access.
- **Suspected, not measured:**
  - Android's two-phase reset blanking conversation-derived UI.
  - How often "Syncing" flickers on `projection_pending`.
  - Peer catch-up hiding cards until all of their dependencies arrive.
- **Client file:line references** in sections 5 and parts of 3 come from
  parallel code reads and were spot-checked. The central claims in sections 1–4
  were re-verified directly.
