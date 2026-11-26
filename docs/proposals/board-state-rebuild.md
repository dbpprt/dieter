# Proposal: rebuild the board state 4× faster

Status: proposal 2026-10-29 · scope: `readPeerPage`, `listCardsContext`, a
`Replica.ListSnapshot` and `primeEntity` in `internal/store`; no schema, RPC,
CLI or client change · related: writer wait in
[multi-card-responsiveness.md](multi-card-responsiveness.md) ·
reference implementation: fork commit
[`6b49ab3`](https://github.com/JustinNeumann/dieter/commit/6b49ab3265faf6e5fe26703a0e11153ad8f3a902)

## TL;DR

`GetState(all_projects)` rebuilds the whole board state after every metadata
change and holds the central writer lock while it does, so card creates, moves
and transcript appends wait behind it. Usage updates and turn events of running
agents advance the metadata revision, so while agents run most calls rebuild.
Three small changes in the replica reads make the rebuild 4× faster:

1. **One lower bound for prefix pages.** `readPeerPage` gives SQLite
   `key>after AND key>=prefix`. SQLite uses the first bound, which is `""` on
   the first page, so every prefix read walks all keys that sort before its
   prefix. That is about half of a rebuild.
2. **One snapshot per card list.** `listCardsContext` opens a replica snapshot
   (a transaction with cold caches) for every card through
   `readCard → overlayCard`. A list pins one snapshot and, up to 16 MiB of peer
   records, reads it once into an in-memory state that the list owns.
3. **No JSON encoding to size the cache.** `primeEntity` encodes every primed
   record only to measure it for the view cache budget; an estimate does.

Measured on the fork: with 340 cards on a Raspberry Pi 5 a rebuild went from
0.96 s to 0.22 s, on 4 x86 cores from 390 ms to 100 ms. The materialized state
is byte-identical (sha256 of the JSON before and after). The fork's server
builds carry the change since `v0.6.429-antigravity.5`.

## 1. What exists today (code facts)

All references are to `main` at 7f2afded (0.6.431).

| What               | Where                                                                                                                                                                                                                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Callers            | `GetState(all_projects)` (`internal/api/state.go:16`): `dieter status` (`internal/cli/daemon_commands.go:81`), the daemon health project count (`daemon_ops.go:187`), board resolution (`rpc_projects.go:499`, `:605`), board-scope settings (`rpc_settings.go:277`)                          |
| Cache and lock     | `GlobalStateContext` takes `globalStateMu`, then the writer lock (`internal/store/kanban/state.go:61`, `:65`), and reuses the cached state only while the metadata revision is unchanged (`:77`); otherwise it materializes under the lock (`:80`)                                            |
| Revision           | Text deltas, capabilities and presented content leave `metadata-highwater` alone; usage (`message-metadata`) and `finish` chunks, other conversation events and every card mutation advance it (`internal/store/home/sync.go:15-20`, `internal/store/conversations/conversations.go:298-315`) |
| Card list          | `materializeGlobalStateContext` → `listCardsContext(ctx, true)` (`state.go:102`); for each card file `readCard` (`cards.go:228`) → `overlayCard`, which opens `replica.Snapshot()` per card (`shared.go:483-494`); a second snapshot follows for shared-only cards (`cards.go:239`)           |
| Other list callers | `ListCards` for per-project state (`cards.go:372`), Done-card archiving (`cards.go:756`), project counts (`projects.go:253`), orphan detection (`internal/store/conversations/orphans.go:28`)                                                                                                 |
| Prefix pages       | `Each` / `EachMatching` start with `after = ""` (`internal/store/replica/view.go:252`) and call `readPeerPage` with `key>? AND key>=? AND key<?` (`view.go:292`); `peer_records` has `key TEXT PRIMARY KEY` (`database.go:47`)                                                                |
| Priming            | `primeEntity` reads `kind/id.` with one range read per entity, then `json.Marshal`s every field record to pass its length to the view cache (`view.go:363-392`); the cache holds 256 records / 4 MiB (`view.go:19-20`)                                                                        |
| Bounds             | At most 64 concurrent read snapshots (`view.go:24`); `peer_metadata.record_bytes` already tracks the encoded size of all peer records (`database.go:44`); the hard state limit is `crdt.MaxStateBytes` = 128 MiB (`internal/replication/crdt/store.go:21`)                                    |

Because every prefix read walks the keys before its prefix, and a rebuild
issues such reads per card and per dependency it resolves, the rebuild cost
grows with cards × records, not with cards.

## 2. Design

### 2.1 One lower bound in `readPeerPage`

Use the tighter bound as the only lower bound:

```go
query := "SELECT key,value FROM peer_records WHERE key>=? AND key<? AND (?='' OR substr(key,-length(?))=?) ORDER BY key"
lower := prefix
if after >= prefix {
	query = "SELECT key,value FROM peer_records WHERE key>? AND key<? AND (?='' OR substr(key,-length(?))=?) ORDER BY key"
	lower = after
}
```

The rows selected are the same: on the first page `after` is `""` and
`key>=prefix` already implies `key>""`; on later pages `after` lies inside the
prefix range and `key>after` implies `key>=prefix`. The upper bound, suffix
filter, ordering and page limits are unchanged. Every prefix read in the store
benefits, not only the board state.

### 2.2 One snapshot for a card list

- `Replica.ListSnapshot()` is `Snapshot()` for projections over every card. It
  pins the revision as today; if `peer_metadata.record_bytes` is at most
  `listSnapshotMaxBytes` (16 MiB), it reads all of `peer_records` in one
  ordered scan inside that same snapshot transaction, decodes each record with
  the existing `decodePeerRecord` (JSON plus `crdt.ValidateRecord`), checks the
  key, indexes the result with `indexPeerData` and closes the SQL snapshot. The
  caller gets a `PeerData` with the snapshot's epoch and sequence and no view.
- Larger replicas, and unenrolled stores (already in memory), get the paging
  snapshot unchanged.
- `listCardsContext` takes one `ListSnapshot` before the loop, reads each file
  with `readLocalCard` and projects it with `SharedCard(data, id, local)`, the
  same function `overlayCard` uses. A card the replica does not hold is skipped,
  as `overlayCard`'s `ErrNotFound` is today. The shared-only pass reuses the
  same data instead of opening a second snapshot.
- Nothing is cached across calls. Each list owns the records it decoded, so a
  caller that edits a returned card cannot reach another caller's records or
  clocks. The shared snapshot record cache keeps its role for point reads.

All of `listCardsContext`'s callers benefit, including per-project `GetState`
through `ListCards`.

### 2.3 Estimate record sizes for the view cache

```go
func recordSize(r crdt.Record) int {
	n := 32 + len(r.Kind) + len(r.ID)
	for _, v := range r.Versions {
		n += 48 + (len(v.Value)+len(v.Provenance))*4/3 + 24*len(v.Clock)
	}
	return n
}
```

The cache budget only needs an approximate size; encoding every primed record
cost about a tenth of a card list. The estimate adds a third to the raw value
and provenance bytes plus fixed costs per version and clock entry.

### 2.4 What does not change

- `GlobalStateContext` still captures the revision under the writer lock and
  materializes under it; the change shortens the hold, not the protocol.
- No new cache spans operations; the 256-record / 4 MiB view cache and the
  64-snapshot bound stay as they are.
- No storage schema, RPC, CLI output or client change. The produced
  `dieter.v1.State` is identical, so no client or fixture needs updating.

## 3. Measurements

As reported by the reference commit, one `GlobalState` rebuild before and after
the change, with the materialized JSON compared by sha256:

| Machine                   | Before | After  | Factor |
| ------------------------- | ------ | ------ | ------ |
| Raspberry Pi 5, 340 cards | 0.96 s | 0.22 s | 4.4×   |
| 4 x86 cores               | 390 ms | 100 ms | 3.9×   |

The commit attributes about half of the old rebuild to the two-bound query and
about a tenth of a card list to the JSON sizing. These are measurements on a
real store, not a fixture qualification on the reference M4; §5 question 4
proposes a benchmark that makes them reproducible.

## 4. Tests

The reference commit adds `internal/store/replica/list_snapshot_test.go`:

- `TestPeerPagesStayInsideTheirPrefix`: a prefix spanning three pages between
  neighbours that sort before and after it returns every record once, in order,
  in exactly 3 queries, and suffix filters still apply.
- `TestListSnapshotMaterializesOwnedStateWithinItsBound`: a small replica is
  materialized; projecting every card from it equals the paging projection;
  editing a listed card's shared base or clocks does not reach the next list;
  with the bound set to 0 the paging snapshot is used and projects the same
  cards.

Existing coverage that guards the output: the account projection fixture
compares `GetState(all_projects)` against a recorded `dieter.v1.State`
(`internal/api/account_projection_test.go`), plus the kanban and replica
projection tests. An upstream change would also run the race tests for the
store packages and `just check-changed`.

## 5. Open questions for maintainers

1. One change or three? 2.1 and 2.3 are small and independent; 2.2 adds the
   in-memory path and its bound. Following the responsiveness plan, they could
   land as separate changes, each with before/after numbers.
2. Is 16 MiB of encoded records the right bound? Decoded records take more
   memory than their encoding, and list callers outside `GlobalStateContext`
   (`ListCards`, archiving, orphans) are not serialized by `globalStateMu`.
   Should concurrent in-memory lists share one byte budget, as snapshots share
   their 64 slots?
3. Should the cache budget keep exact sizes (for example from the raw bytes the
   page read already has) instead of the estimate in 2.3?
4. Should an opt-in benchmark with 100, 340 and 1,000 cards, in the style of
   `TestConcurrentTurnWriterCost`, qualify the change on the reference M4, and
   should writer wait during a rebuild join the responsiveness targets?
5. Later, separate from this proposal: could the projection be built after
   releasing the writer lock? The lock captures a committed revision of the card
   files, which the replica snapshot does not cover.
