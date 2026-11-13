# Proposal: synced folders (Mac, phones and daemons)

Status: implemented 2026-11-13 in one pull request
([ADR 0005](../adr/0005-synced-folders.md); measurements in
[synced-folders-results.md](synced-folders-results.md); deviations in §8);
decisions in §6 · scope: a new `folder` shared record kind, a
`FolderService` and `dieter folder` CLI group, a daemon sync engine
(`internal/host/folders`, `internal/store/folders`), a client sync engine in the
Kotlin core for Android and iOS, background scheduling on both phones, a
Folders destination on all three clients and Folder sync settings on the
phones · UI mockup in
[`assets/synced-folders-mockup.html`](assets/synced-folders-mockup.html)

## TL;DR

A **synced folder** is a named directory that Dieter keeps the same on several
of the account's devices: daemons (Mac mini, Linux box, a MacBook that runs a
daemon) and the phones. Drop a PDF into the folder on your phone and it shows up on the daemon,
where an agent can read it. An agent writes a report into the folder and it
shows up on your phone and Mac. Edit a file on a Mac and every member gets the
new version.

- **Daemons are the hubs.** A folder always has at least one daemon member.
  Daemons sync with each other without a leader, the way peer records already
  do. Phones sync only with a daemon, their _home_ daemon for that folder,
  because clients never accept connections. A Mac takes part through its own
  daemon; the Mac app manages folders and reveals the local copy in Finder, but
  runs no sync engine of its own.
- **Built on what exists.** Content moves with the existing chunked,
  revision-checked, resumable transfer RPCs (`ReadFileChunk`,
  `BeginFileUpload`… in `files.proto`) and the atomic `filetransfer.Publish`.
  `TransferPath` gains a `folder_id`. Folder definitions replicate as shared
  peer records, which carry no local paths. Every byte travels over the
  existing mutual-TLS carriers (direct, WebRTC, relay tunnel), so the gateway
  sees only ciphertext.
- **Correct by construction.** Each member keeps an index of entries with
  version vectors. Wall clocks never decide which edit is newer. Two edits made
  at the same time keep both versions: one keeps the name and the other becomes
  a visible conflict copy. An edit beats a concurrent delete. Deletes and
  overwrites go to a trash on every daemon member. A guard pauses the folder
  instead of applying a mass deletion, and a missing or replaced folder root
  pauses the member instead of deleting anything.
- **Mobile settings put the user in control.** Per device:
  - how often to sync: Android runs at an exact interval from 15 minutes up,
    iOS at a preferred interval it schedules itself;
  - which networks to use (Wi-Fi only, cellular for small files, Low Data
    Mode);
  - power (only while charging, pause in Low Power Mode or below a battery
    level);
  - a storage limit, and an auto-download size limit. Larger files are listed
    and download on tap.

  Per folder: direction (two-way, download only, upload only, paused), where
  the folder lives on the device, and overrides of the device defaults.

- **Agents can use it, safely.** A folder can be linked to a project. Turns of
  that project on a member daemon then learn its path. Agent turns may read
  folder status and write files, but cannot create folders, attach paths,
  change modes or confirm mass deletions. Those calls refuse a turn token, the
  same rule `TrustService` follows.
- **Delivery in one pull request** (§4): daemon ↔ daemon sync, the CLI, the
  phone engine with background scheduling and the full settings, the Folders
  UI on all three clients, agent integration, rename detection and block-level
  transfers, documentation and tests. It is inert until someone creates a
  folder. A sync engine in the Mac app, File Provider, push and folder
  triggers are follow-ups (§7).

## 1. Goals and non-goals

**Goals**

- Two-way sync of ordinary files and directories between any mix of an
  account's daemons, Android phones and iPhones. Macs take part through the
  daemon running on them.
- No data loss. Concurrent edits, offline edits, interrupted transfers,
  crashes, unmounted disks and mass deletions never silently destroy content.
- Bounded everything: folders, members, entries, versions, transfers, trash,
  status records and relay use.
- Mobile users decide when sync may run, on which networks, at what battery
  and storage cost, and which files download automatically.
- One protocol for every carrier and client, including the CLI.
- A first-class path for agents: the phone-to-agent inbox and the
  agent-to-phone outbox.

**Non-goals (v1)**

- Syncing Git working trees or registered checkouts. Git already does this, and
  replicating a working tree contradicts the invariants.
- A general Dropbox replacement: no sharing with other accounts, no public
  links, no web access (Dieter has no web UI).
- Syncing ownership, ACLs, extended attributes, hard links, sparse files or
  symlinks. This matches `dieter file sync`.
- Client-to-client sync without a daemon.
- A local copy on a Mac that runs no daemon (follow-up, §7).
- Real-time collaborative editing or merging file contents.
- Sandboxing agents' access to synced files. Agents already run as the daemon
  user.

## 2. What exists today (code facts)

### 2.1 Transfer primitives (daemon)

- **`internal/filetransfer`**: bounded, rooted file I/O.
  - `Clean` rejects absolute paths, `..`, NUL, `.git` and the
    `.dieter-transfer-` prefix.
  - `Parent` walks every path component with `O_NOFOLLOW` and pins the parent
    directory's descriptor.
  - `Entry.Revision` is an observation digest of dev, inode, ctime, size, mtime
    and mode. `Describe` hashes a file and fails if the file changed while it
    was being hashed.
  - `List` returns revision-checked pages of at most 512 entries. `Read` returns
    revision-checked chunks of at most 1 MiB.
  - `Publish` streams into a private sibling file and verifies its size and
    SHA-256. It then replaces the destination only if the destination still has
    the expected revision, or creates it only if it is still missing. The
    create-only case uses `linkat`, so a file that appeared in the meantime is
    never overwritten.
  - `Remove` deletes an observed file revision and never a directory tree.
  - `Plan` is the pure one-way planner behind `dieter file sync`, with rules
    where the last matching pattern wins. `MaxEntries = 100000`.
- **`internal/host/filetransfer.Manager`**: durable upload sessions under
  `DIETER_HOME/transfers`.
  - Uploads are idempotent per operation ID, written in 1 MiB chunks with
    receipts, and stay resumable for 24 hours.
  - Limits: 64 GiB per file, 256 GiB of staging and 4096 sessions.
  - Every mutation runs under `fsx.LockHome`. Commit recovers its receipt after
    a crash.
- **`FileService`** (`api/proto/dieter/v1/files.proto`) exposes
  `StatTransferFile`, `ListTransferFiles`, `ReadFileChunk`,
  `Begin/Write/Get/Commit/AbortFileUpload` and `DeleteTransferFile`. Their
  roots are a project checkout or a conversation workspace (`TransferPath`).
  Today only the Go CLI calls them (`internal/cli/rpc_file_transfer*.go`). The
  user guide is `site/content/docs/file-transfers.md`.

### 2.2 Replication

- `internal/replication/schema/domain.go` declares the shared record kinds:
  project, board, label, item, assignment, checkout and schedule. Its rule is
  explicit: _"Local filesystem paths, credentials and conversation content are
  deliberately absent."_ The `strings` field shape is capped at 64 values.
- KV namespaces with one writer per key, which only daemons may write, already
  carry agent channel claims and receipts (`schema/channel.go`, keys like
  `<project>.<daemon>`). Values are at most 32 KiB (`crdt.MaxValueBytes`).
- `peersync` dials each roster daemon over the same carriers clients use, on
  the replication relay lane (`relay.TunnelLimit`: replication 8, command 32).
- `WatchChanges` streams each machine's view to clients and has owner-only
  sections. Agent mail used one to deliver headers without polling.

### 2.3 Clients

- **Files.** The Kotlin core has a `files` domain (`files/Files.kt`) for
  browsing and editing through `ListFiles`, `ReadFile` and `SaveFile`. No
  client uses the transfer RPCs. Attachments are sent inline, at most 4 files
  and 6 MB in total (`composition/Attachments.kt`).
- **Background execution.** None on any platform. Android has no WorkManager
  or foreground service. iOS has no `BGTaskScheduler` and no
  `UIBackgroundModes`. Nothing checks network type or battery. The core already
  has the policy without a host: `BackgroundMode` (Live / Smart / App only),
  `BackgroundPolicy.shouldRun`, `CoreRuntime.periodicWindow()` and
  `ConnectionSupervisor.refreshForWidget(timeout)`, which opens a bounded
  connection window.
- **Persistent folder access.** None anywhere. Android has no
  `ACTION_OPEN_DOCUMENT_TREE`, iOS has no bookmarks or File Provider, and the
  Mac has no bookmarks or FSEvents. iOS already has an App Group, used by the
  share extension. The Mac app is not sandboxed.
- **Settings.**
  - Device-local: `DeviceSettings` is backed by SharedPreferences on Android
    and UserDefaults on Apple platforms.
  - Account-wide: `SharedKv`.
  - Screens: `ui/.../settings/SettingsScreen.kt` on mobile and
    `mac/.../Features/Settings/Views/DieterSettingsView.swift` on the Mac.
- **Core storage.** Wire protobuf files written atomically through Okio
  (`storage/CoreStorage.kt`). There is no database. The outbox journals
  commands with deterministic IDs.
- **Mac.** The app does not run a daemon, but it knows when a daemon is on the
  same Mac (`local` on the session slice, `AppSession.isLocalMachine()`).
- **Platform targets.** Android `minSdk 26`, `targetSdk 37`. iOS deployment
  target 18.0. macOS 26.

## 3. Design

### 3.1 Concepts

| Term              | Meaning                                                                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Folder**        | An account-wide shared object: an ID, a name, rules, a trash policy and an optional linked project. It has **no path**.                                                              |
| **Member**        | One device that keeps a copy. A _daemon member_ binds a local directory on its host. A _client member_ is an Android phone or an iPhone.                                             |
| **Mode**          | Per member: `two-way`, `send-only` (upload only), `receive-only` (download only). Any member can also be paused.                                                                     |
| **Home daemon**   | The daemon member a client syncs with. Defaults to _Auto_: prefer a daemon with a direct route, then the most recently reachable one. Changes on failover.                           |
| **Index**         | Each member's list of entries (path, kind, size, mtime, executable bit, SHA-256, version). It carries a member-local sequence that increases monotonically, and a random `index_id`. |
| **Version**       | A version vector per entry: `[(actor, counter)]`. The actor is the first 8 bytes of SHA-256(device ID), so no slot table is needed.                                                  |
| **Conflict copy** | When versions are concurrent, the losing version is kept as `Name (conflict, Pixel 9, 2026-11-13 14.12).ext`. It is a normal file that syncs to every member.                        |

A folder requires at least one daemon member. Phones are never the only copy,
and clients never need to reach each other.

**Macs take part through their daemon.** On a Mac that runs a daemon, the
folder lives on that daemon. The Mac app shows it as "This Mac" and offers
_Reveal in Finder_, because `FileExternalActions` already knows when a machine
is this Mac. The Mac app has no sync engine, so nothing competes with the
daemon for the directory. A Mac without a daemon can create, manage and
inspect folders, and browse a daemon's copy with the existing file browser,
but keeps no local copy; the app suggests installing the daemon.

### 3.2 Topology

```text
 daemon A (Mac mini) ◀══ folder peer sync (replication lane) ══▶ daemon B (Linux box)
   ▲  Mac app on the mini: "This Mac", Reveal in Finder            ▲
   │ home (Auto: A, else B)                                        │ home
 Pixel 9                                                         iPhone
```

- **Daemon ↔ daemon.** Each pair of daemon members exchanges index pages,
  starting from the per-peer checkpoint. Each daemon **pulls** the content it
  needs with `ReadFileChunk` from any daemon member that has the wanted
  version. It prefers a direct route, then the most recent peer. At most 2 of
  the 8 replication-lane tunnels per peer are used for folders. Peer record
  sync runs on the same lane and keeps its share.
- **Client ↔ home daemon.** The client downloads with `ReadFileChunk` and
  uploads with upload sessions whose target is a folder. It sends directory
  creations and deletions with `ApplyFolderEntry`. It uses the command lane,
  where interactive calls also run, so a client runs at most 2 transfers at
  once. Measurement M2 checks how much this hurts interactive latency (§4.3).
- **Live hints.** Each daemon publishes its folder heads (folder ID, sequence
  and coarse state) in an owner-only `WatchChanges` section. Clients and peers
  that are connected start a run as soon as a head moves. Nobody polls while
  connected.

### 3.3 Where a folder lives on each platform

| Member         | Location                                                                                                                                                                                                                                                                                                                                                                                                 | Change detection                                                                                                                                                                                                                                                                                                                                    |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Daemon (Linux) | Any absolute directory the user picks, using the existing `ListDirectories` picker. Guardrails in §3.8.                                                                                                                                                                                                                                                                                                  | Recursive inotify through `fsnotify` (already a dependency), debounced. When `max_user_watches` is exhausted, it falls back to a stat-only scan every 60 s. A full rescan runs every hour regardless.                                                                                                                                               |
| Daemon (macOS) | Same.                                                                                                                                                                                                                                                                                                                                                                                                    | `fsnotify` uses kqueue on macOS, which needs one descriptor per watched file, and the daemon has no cgo for FSEvents. Decision: kqueue watches **directories** (adds, removes, renames, atomic saves), and a stat-only walk every 60 s catches in-place edits. Measurement M1 sizes the walk; an FSEvents mode in the native helper is a follow-up. |
| Android        | **Shared folder (default).** A tree the user picks with `ACTION_OPEN_DOCUMENT_TREE`, with a persisted URI permission, for example `Documents/Dieter/Inbox`. Other apps can see it. Android 11+ doesn't allow picking the root of a storage volume or `Download/`. **Private.** App storage, visible only through Dieter's own browser and the share sheet.                                               | SAF sends no reliable change notifications. The engine scans at the start of each run (children queried with a projection cursor) and every 30 s while Dieter is in the foreground.                                                                                                                                                                 |
| iOS            | The app's Documents container, exposed in Files as **On My iPhone › Dieter › _Folder_** (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). Other apps edit in place through Files. Default data protection (`completeUntilFirstUserAuthentication`) keeps files readable for background runs after the first unlock. A File Provider extension, with online-only files, is a follow-up (§7). | A scan at the start of each run, plus an `NSFilePresenter` on the folder while the app is in the foreground.                                                                                                                                                                                                                                        |

### 3.4 The index and versions

Each index entry is exchanged in this form:

```text
path       NFC, '/'-separated, relative; ≤ 4096 bytes, components ≤ 255 bytes
kind       file | directory | deleted
size, modified_nanos, executable
sha256     files only
version    [(actor u64, counter u64)], ≤ 64 entries
sequence   member-local, monotonic
author     device ID of the last change (display only)
```

Some fields stay with the member and are never exchanged:

- the observed `filetransfer` revision, used for cheap change detection and to
  suppress echoes;
- on clients, `absent_by_policy` for files not downloaded because of the
  auto-download limit, and `evicted` for files freed to save space. An absent
  file is never a deletion.

**Local change.** When a scan finds a different observed revision, the member
hashes the file. `Describe` rejects a file that changes while it is hashed, so
such files are retried later. If the hash is unchanged (only touched), the
member records the new observed revision and does not bump the version.
Otherwise it sets `version[me] += 1`, assigns the next sequence and records
itself as author.

**Fresh index.** This covers a reinstalled app, a deleted `DIETER_HOME`, or a
new attach of a directory that is not empty. The member first adopts the home
daemon's index (a peer's, for a daemon). Equal hashes adopt the remote version,
so the member's counters continue past any it issued before. Files that exist
only locally become new local changes. Differing files are concurrent and
become conflict copies. When attaching, the user can choose **Adopt folder
contents** instead: differing local files go to the trash first, and the folder
wins.

### 3.5 Reconciliation rules

The rules are pure. They live once in Go (`internal/folders/reconcile`) and
once in the Kotlin core (`folders/Reconcile.kt`), verified against the same
golden vectors (`tests/fixtures/folders/`), the way roster verification is
shared today.

| Local vs remote entry                         | Outcome                                                                                                                                         |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Equal, or local dominates                     | Nothing.                                                                                                                                        |
| Remote dominates                              | Apply remote: download, mkdir, or delete (to the trash on a daemon).                                                                            |
| Concurrent, same content (same hash/kind)     | Merge the vectors (element-wise max). No conflict.                                                                                              |
| Concurrent, different content                 | A deterministic winner keeps the name. The loser becomes a conflict copy written by the member that detects the conflict, and syncs everywhere. |
| Concurrent, one side deleted                  | The modification wins and the deletion is dropped. Resurrecting a file is the safe direction.                                                   |
| File vs directory at the same path            | The directory wins. The file becomes a conflict copy.                                                                                           |
| Receive-only member changed something locally | Not sent. Shown as **Local changes** with _Revert_ (re-download) or _Keep_.                                                                     |
| Send-only member is behind                    | Remote changes are not applied. Shown as **Not in sync** with _Override folder_ (re-publish local versions with bumped counters).               |

**Deterministic winner.** The entry with the higher `modified_nanos` wins; a
tie goes to the lexicographically higher author device ID. The rule uses only
data inside the entries, so every member picks the same winner and nothing
ping-pongs. A file keeps at most 5 conflict copies; older copies go to the
trash.

**Daemon-side compare-and-swap.** Every download is published with
`filetransfer.Publish` against the observed local revision. If the user edits
the file while it downloads, the publish fails with `Conflict`, the member
rescans that path, and reconciliation runs again. It never overwrites. Client
adapters keep the same rule (§3.14).

### 3.6 Transfers

- **Chunks.** 1 MiB chunks with SHA-256, the existing `ChunkSize`. Downloads
  are revision-checked. Uploads are resumable sessions with commit receipts.
  Both resume after interruption.
- **Uploading into a folder.** `BeginFileUpload` gains a `FolderVersion` that
  carries the base version the client saw and its new version. The daemon
  checks it again at `CommitFileUpload`, under the lock:
  - if the upload's version dominates the daemon's current entry, it publishes
    and appends the index entry in the same critical section;
  - otherwise it returns `Conflict`, and the client fetches the index and
    reconciles.
- **Order of work in a run.** Index exchange first, then directories and
  deletions, then files in ascending size. A short iOS refresh window still
  moves many small files, and a large video never blocks a text file.
- **Concurrency.** 4 files per folder on a daemon (8 per daemon in total) and
  2 on a phone. Each daemon member has a bandwidth limit, using the same
  aggregate limiter as `file sync --bandwidth-limit`.
- **Staging.** Uploads reuse `DIETER_HOME/transfers` (24-hour receipts and
  quotas). Downloads write a payload-only `.dieter-transfer-*` sibling, which
  `Clean` already protects, and publish it atomically.
- **Local reuse.** If a needed SHA-256 already exists locally, the
  member copies the file locally instead of downloading it. This covers renames
  and duplicates.
- **Block-level updates.** For files over 8 MiB, a member records the SHA-256
  of every 1 MiB block in its own store, never in index entries, so index pages
  stay small. A member that holds an older version fetches the new block list
  with `GetFolderBlocks` (paged, at most 65,536 blocks for 64 GiB), copies the
  blocks it already has from the old file, and downloads only the rest. The
  whole file is still verified against its SHA-256 before it is published.

### 3.7 Daemon storage

The folder data on a daemon lives in its own store aggregate,
`internal/store/folders`, which imports only `home`, like `channels` and
`mail`:

```text
DIETER_HOME/folders/<folderId>/
  member.json        local binding: path, root identity (dev, ino), mode, paused,
                     rescan interval, bandwidth limit, quarantine flag
  index/             segment log (append, fsync) + snapshot.pb; compacted at 4× growth
  peers/<device>.json  checkpoint: index_id + sequence received from that member
  clients.json       client members homed here: device, mode, last seen, sequence
  trash/             trashed payload + manifest (§3.8)
  status.json        last scan, last sync, need counts, bounded error list
```

Index appends are batched: one `fsx.LockHome` per batch of at most 256 entries
or 1 s, never one per file. `filetransfer.Publish` happens first. A crash
between a publish and its index append is safe: the next scan sees an observed
revision it doesn't know, hashes the file, finds the expected content, and
records it.

### 3.8 Safety: guardrails, deletes, trash

- **Attach guardrails (daemon).** `AttachFolder` refuses:
  - `/`, the user's home directory itself, and system directories;
  - `DIETER_HOME` and anything that contains it or is inside it;
  - a path that overlaps another folder member on the same daemon;
  - a registered checkout or any path inside one.

  It warns about other Git working trees and about network or removable
  volumes. `.git` stays excluded everywhere, as `Clean` already enforces.

- **Root identity.** At attach, the daemon records the root's `(dev, ino)`. If
  the root is missing, its identity changed (an unmounted or replaced disk),
  or a tree URI permission was revoked, the member pauses with _Folder location
  unavailable_ and **never** turns the absence into deletions. No marker file
  is written into the user's folder.
- **Mount points.** The scanner doesn't cross into another device inside the
  tree. That subtree is skipped and listed in status.
- **Mass-delete guard.** A batch that would delete more than 100 files, or more
  than 30% of the folder (with a floor of 10 files), pauses the member with
  _Confirm deletion of 412 files_ → **Apply** or **Restore**. Restore
  re-downloads the files, or re-publishes them from the trash. The guard checks
  local scans before they are sent and incoming batches before they are
  applied.
- **Trash lives on daemons only.** A daemon that deletes a file because of a
  remote change, or overwrites one, moves the old version to
  `DIETER_HOME/folders/<id>/trash`. It renames when the folder is on the same
  volume and copies within quota when it isn't. When neither works, the member
  warns that trash is unavailable.
  - Retention: 30 days by default, at most 10% of the volume or 20 GiB per
    folder.
  - Phones delete directly. Every daemon member keeps the
    old version, so any device can restore it with `RestoreFolderTrash`.
- **Disk floor.** Downloads stop while free space is below max(1 GiB, 5%). On
  phones, the user's storage limit also applies (§3.15).

### 3.9 Names, types and platform limits

- Paths are normalized to NFC in the index. On ingest, `Clean` applies plus the
  length limits of §3.4.
- **Case-insensitive file systems** (macOS by default, many SD cards). When two
  entries differ only by case, the second is marked _Can't sync here_ in that
  member's status. Nothing is overwritten.
- **Names a target can't store**, such as `\ : * ? " < > |` on FAT or exFAT
  trees reached through SAF, are also _Can't sync here_ on that member.
- **Symlinks, sockets and devices** are skipped and listed in status. They
  don't fail the whole folder, unlike `file sync`, which must fail explicitly.
- Only the executable bit is synced, and only between daemons and the Mac. No
  ownership, ACLs or extended attributes.
- **Quarantine.** On macOS members, files received from another device get
  `com.apple.quarantine`, the same as AirDrop and browsers. Gatekeeper then
  checks an executable an agent wrote before it runs. Configurable per folder;
  on by default.
- Directories are synced as entries, so empty directories appear on every
  member, unlike `file sync`.

### 3.10 Replicated records

- **Shared domain kind `folder`** in `schema/domain.go`. Each field is its own
  register, so unrelated edits never conflict:

  | Field         | Shape       | Notes                                                      |
  | ------------- | ----------- | ---------------------------------------------------------- |
  | `identity`    | object      | `id`, `createdAt`; cannot be deleted                       |
  | `name`        | string      |                                                            |
  | `rules`       | strings     | ≤ 64 patterns, `filetransfer.Rule` syntax, last match wins |
  | `trashDays`   | string enum | `off`, `7`, `30` (default), `90`                           |
  | `deleteGuard` | string enum | `default`, `strict` (10 files / 10%), `off`                |
  | `projectId`   | string      | Optional link for agents (§3.17)                           |
  | `archived`    | bool        | Members stop syncing and keep their files                  |

  Default rules: `.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`, `~$*`, `*.tmp`,
  `*.swp`. They are editable. `.git` and `.dieter-transfer-*` are always
  protected.

- **KV namespace `folder-member`**, key `<folder>.<daemon>`. Only that daemon
  writes it, and the public KV API refuses, as it does for the channel
  namespaces. The value describes the daemon's own membership (mode, paused,
  coarse state, sequence, last sync) and the client members homed on it
  (≤ 16: device, mode, last seen, acknowledged sequence). It is written on
  state changes, at most once per minute. Live progress travels on
  `WatchChanges`, never as replicated churn. **No local paths**: the daemon's
  directory stays in its own `member.json`, and a device sees it only by asking
  that daemon.
- **Tombstones** stay until every current member has acknowledged a sequence
  that covers them, or for 90 days. A member that returns after its tombstones
  were collected may resurrect files, which errs toward keeping data.
- Revoking a device from the roster drops its membership on the next write.
  Archiving a folder stops all members.

### 3.11 API: `FolderService` and `TransferPath`

New file `api/proto/dieter/v1/folders.proto`, one handler in
`internal/api/folders.go`:

```proto
service FolderService {
  // Shared definition (any daemon; replicated).
  rpc CreateFolder(CreateFolderRequest) returns (Folder);
  rpc UpdateFolder(UpdateFolderRequest) returns (Folder);          // name, rules, trash, guard, project
  rpc ArchiveFolder(FolderRef) returns (Folder);
  rpc ListFolders(ListFoldersRequest) returns (FolderList);        // with members' coarse state

  // This daemon's membership (path is owner-local).
  rpc AttachFolder(AttachFolderRequest) returns (FolderMember);    // path, mode, join: merge|adopt
  rpc UpdateFolderMember(UpdateFolderMemberRequest) returns (FolderMember); // mode, paused, rescan, bandwidth
  rpc DetachFolder(DetachFolderRequest) returns (google.protobuf.Empty);    // files stay on disk

  // Client members homed on this daemon.
  rpc RegisterFolderClient(RegisterFolderClientRequest) returns (FolderMember);
  rpc UnregisterFolderClient(FolderClientRef) returns (google.protobuf.Empty);

  // Sync protocol (peers and clients).
  rpc GetFolderIndex(GetFolderIndexRequest) returns (FolderIndexPage); // since (index_id, sequence), ≤ 512 entries, ≤ 2 MiB
  rpc ApplyFolderEntry(ApplyFolderEntryRequest) returns (FolderEntry); // mkdir / delete with base + new version
  rpc GetFolderBlocks(GetFolderBlocksRequest) returns (FolderBlockPage); // 1 MiB block hashes of one file version (> 8 MiB)

  // Operations.
  rpc GetFolderStatus(FolderRef) returns (FolderStatus);           // state, need files/bytes, conflicts, errors
  rpc RescanFolder(FolderRef) returns (FolderStatus);
  rpc ResolveFolderDeletions(ResolveFolderDeletionsRequest) returns (FolderStatus); // apply | restore
  rpc ListFolderTrash(ListFolderTrashRequest) returns (FolderTrashPage);
  rpc RestoreFolderTrash(RestoreFolderTrashRequest) returns (FolderEntry);
  rpc PurgeFolderTrash(PurgeFolderTrashRequest) returns (google.protobuf.Empty);
}
```

Existing messages change as follows:

- `TransferPath.folder_id`: exactly one of project, card or folder.
- `BeginFileUploadRequest.folder_version`: required for folder targets.
- `ChangesFrame`: gains an owner-only `folders` section with heads and coarse
  state.

`StatTransferFile`, `ListTransferFiles`, `ReadFileChunk`, the upload RPCs and
`DeleteTransferFile` then work against a folder member's root, with the same
bounds and errors. Errors use `fault` kinds: `Conflict` when a version or
revision is stale, `FailedPrecondition` when the member is paused, its root is
unavailable or the guard is pending, and `ResourceExhausted` when a bound is
hit.

**Turn tokens.** These calls refuse a turn token:

- `CreateFolder`, `UpdateFolder`, `ArchiveFolder`;
- `AttachFolder`, `UpdateFolderMember`, `DetachFolder`;
- `Register/UnregisterFolderClient`;
- `ResolveFolderDeletions` and `PurgeFolderTrash`.

So an injected agent can neither mirror `~/.ssh` to a phone nor attach a
two-way member at `~` that wipes another machine. Reads, `RescanFolder`,
`RestoreFolderTrash` and transfers are allowed.

### 3.12 CLI

```text
dieter folder list | show FOLDER
dieter folder create NAME [--rule '-*.log' …] [--project P] [--trash-days 30]
dieter folder update FOLDER [--name …] [--rule …] [--project …] [--delete-guard strict]
dieter folder archive FOLDER
dieter folder attach FOLDER PATH [--mode two-way|send-only|receive-only] [--join merge|adopt] [--dryrun]
dieter folder detach FOLDER
dieter folder pause | resume FOLDER
dieter folder status FOLDER [--format json]
dieter folder rescan FOLDER
dieter folder deletions FOLDER --apply | --restore
dieter folder trash list | restore | purge FOLDER …
dieter folder index FOLDER [--since INDEX_ID:SEQ]     # protocol inspection, like `file scan`
dieter folder blocks FOLDER PATH                      # block hashes of a large file (protocol inspection)
dieter folder client register | unregister …          # protocol parity for client members
dieter file cp|sync --folder FOLDER …                  # existing commands gain the folder root
```

`attach --dryrun` prints the join plan: adopted, new, conflicting and trashed
paths. The CLI follows the usual parity rules: entries in the command table,
offline help, `rpcCommand` mappings, a regenerated CLI reference, end-to-end
tests over the local, direct-TLS and relay routes, and updates to the
`dieter-cli` skill.

### 3.13 Daemon engine (`internal/host/folders`)

The engine is composed in `internal/daemon` and started only by `dieter serve`,
like the scheduler. Constructing a handler in a test starts nothing. Each
attached member has:

- **a watcher**: inotify on Linux, kqueue on directories plus the 60 s stat
  walk on macOS (§3.3), debounced for 2 s,
  falling back to stat polling;
- **a scanner**: an incremental walk with `filetransfer.List`-style pinned
  directory descriptors and the guardrails in §3.8;
- **a peer loop per daemon member**: index exchange from the checkpoint,
  pulls, independent backoff, and checkpoints that advance only after durable
  index appends, the same discipline as `peersync`;
- **a client registry**: home bookkeeping, acknowledged sequences for
  collecting tombstones, and the `folder-member` record;
- **status**: the `WatchChanges` heads and the bounded error list.

The dialer to peers is `peersync`'s, so folder sync uses the same roster-pinned
carriers and lane accounting.

### 3.14 Phone engine (Kotlin core, `folders/`)

All rules live in the core. The apps provide only platform adapters.

- **`FolderSync`** (commonMain). One engine per folder that is on this device:
  - the local index, as sharded Wire files in `CoreStorage` (256 shards by
    path hash, each written atomically), so a change rewrites a few KiB rather
    than the whole index;
  - the reconcile rules from §3.5;
  - the transfer runner, with a journal for resumption;
  - checkpoints per folder and home daemon.
- **`FolderSyncPolicy`** (commonMain). Turns the device settings (§3.15) and
  the current conditions into one decision per run: _run all_, _run small
  only_, or _skip, with a reason_. The UI shows the reason ("Waiting for
  Wi-Fi", "Paused: Low Power Mode", "Storage limit reached"). Unit tests cover
  every combination.
- **Platform interfaces**, injected like `DeviceSettings`:
  - `FolderFileSystem`: list a directory, stat, open for reading, write a temp
    file and replace atomically when the revision still matches, delete, mkdir,
    root identity, free space.
  - `DeviceConditions`: network (unmetered, metered, constrained, roaming,
    none), charging, battery %, Low Power Mode or Battery Saver, Data Saver.
- **Adapters.**
  - **Android.** SAF through `DocumentsContract`. SAF has no atomic replace,
    so the adapter writes a `.dieter-transfer-*` document, checks the target's
    last-modified time and size, deletes it and renames the temp. The short
    window is documented, and a lost race shows up in the next scan. Private
    app storage uses `java.io` with an atomic rename.
  - **iOS.** `FileManager.replaceItemAt` under `NSFileCoordinator`, so Files
    and other apps see coordinated writes.
- **Run window.** `CoreRuntime.folderSyncWindow(deadline, scope)` is modeled on
  `refreshForWidget`:
  1. connect to the home daemon, failing over to the next daemon member;
  2. scan;
  3. exchange the index;
  4. plan and transfer in the order of §3.6;
  5. persist after each durable step;
  6. stop cleanly at the deadline.

  If work remains, the window asks the platform host for a longer run.

- **ClientApi.**
  - `FoldersCommand`, scoped by folder: create, attach-here, set-mode,
    sync-now, pause, resolve-deletions, restore, download-file, evict,
    set-settings.
  - Slices `FOLDERS` (list with status), `FOLDER` (detail, local file tree,
    members, conflicts, trash) and `FOLDER_SYNC_SETTINGS`.
  - Device settings are a `FolderSyncSettings` Wire record in `CoreStorage`.
    They are device-local and never replicated.

### 3.15 Settings

#### Mobile: Settings › Folder sync (device defaults)

| Setting                    | Android options                                                                                     | iOS options                                                                                                                                                                               | Default                           |
| -------------------------- | --------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| **Folder sync**            | On / Off (master switch)                                                                            | Same                                                                                                                                                                                      | On once a folder is added         |
| **Sync in the background** | Every 15 min · 30 min · 1 h · 6 h · 12 h · 24 h · Only while Dieter is open · Manual only           | Often · About hourly · About every 6 h · Daily · Only while Dieter is open · Manual only. Caption: _"iOS decides the exact time based on battery, network and how often you use Dieter."_ | 1 h (Android), About hourly (iOS) |
| **While Dieter is open**   | Sync when opened · Upload my changes right away · Keep in sync live                                 | Same                                                                                                                                                                                      | All on                            |
| **Network**                | Wi-Fi and unmetered only · Any network · Any network, large files on Wi-Fi only                     | Same                                                                                                                                                                                      | Wi-Fi and unmetered only          |
| ↳ _Large file threshold_   | 10 MB · 25 MB · 100 MB                                                                              | Same                                                                                                                                                                                      | 25 MB                             |
| ↳ _Respect Data Saver_     | Follows Android Data Saver                                                                          | _Respect Low Data Mode_ (`NWPath.isConstrained`)                                                                                                                                          | On                                |
| ↳ _Never while roaming_    | `NOT_ROAMING`                                                                                       | Not available (no API); covered by the cellular choice                                                                                                                                    | On                                |
| **Power**                  | Only while charging · Pause in Battery Saver · Pause below 10% · 20% · 30% · Never                  | Only while charging · Pause in Low Power Mode · Pause below …                                                                                                                             | Pause in saver mode; below 20%    |
| **Download automatically** | Files up to 10 MB · 25 MB · 100 MB · 1 GB · All files · Nothing (on demand only)                    | Same                                                                                                                                                                                      | 25 MB                             |
| **Storage limit**          | 1 GB · 2 GB · 5 GB · 10 GB · 25 GB · No limit; plus _Keep at least 1 GB free_                       | Same                                                                                                                                                                                      | 2 GB; keep 1 GB free              |
| **Free up space**          | Button: evict downloaded files that are synced to a daemon (they remain listed and download on tap) | Same                                                                                                                                                                                      | –                                 |
| **Notifications**          | Conflicts · Needs attention (guard, location lost, limit reached) · Sync finished                   | Same                                                                                                                                                                                      | Conflicts and attention on        |
| **Status**                 | Last sync, next sync (estimate), pending ↑/↓ files and bytes, cellular data used this month         | Same                                                                                                                                                                                      | –                                 |

**Settings for each folder on this device** (in the folder's detail page, under
_On this device_). Each override defaults to _Use device setting_.

| Setting                              | Options                                                                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **Direction**                        | Two-way · Download only · Upload only · Paused                                                                               |
| **After upload**                     | Upload only: _Keep on this device_ · _Remove from this device_ (inbox style; eviction, never a delete)                       |
| **Location**                         | Android: _Shared folder…_ (SAF pick) or _Private to Dieter_. iOS: fixed, _On My iPhone › Dieter › Name_                      |
| **Sync interval**                    | Device default or an override (e.g. _Inbox_ every 15 min, _Archive_ daily). The scheduler uses the shortest active interval. |
| **Network / Download automatically** | Override the device defaults                                                                                                 |
| **Home machine**                     | Auto · a specific daemon member                                                                                              |
| **Remove from this device**          | _Keep files_ (stop syncing, leave them) · _Delete local copy_ (eviction, never a folder deletion)                            |

#### Mac app

The Mac syncs through its daemon, so it has no interval, network or power
settings. Settings gets a **Folders** section:

- **For each folder**: whether it is on this Mac ("This Mac", through the local
  daemon) and the daemon member settings below, editable in place.
- **Add this Mac to a folder**: picks the directory with `NSOpenPanel`. The
  daemon runs on the same machine, so the path is valid there, and the app sends
  it to `AttachFolder` on the local daemon.
- **A Mac without a daemon**: _"Install the Dieter daemon on this Mac to keep a
  copy of your folders here."_

#### Daemon members

These are set from any client or with `dieter folder update`/`attach`:

- path (read-only after attach);
- mode and paused;
- _Watch for changes_ (on);
- full rescan interval (15 min · 1 h · 6 h · 24 h; default 1 h);
- bandwidth limit;
- maximum concurrent transfers (1–8; default 4);
- quarantine (macOS).

#### Shared (any device)

Name, ignore rules, trash retention, deletion guard, linked project, members
(add a device, change its mode, remove it).

### 3.16 Scheduling on each platform

- **Android.**
  - **Periodic runs.** WorkManager `PeriodicWorkRequest` at the shortest
    active interval (15-minute minimum, with flex), with constraints that come
    straight from the settings: `NetworkType.UNMETERED`, `CONNECTED` or
    `NOT_ROAMING`, plus `requiresCharging`, `requiresBatteryNotLow` and
    `requiresStorageNotLow`. When settings change, the work is updated with
    `ExistingPeriodicWorkPolicy.UPDATE`.
  - **Policy at run time.** The worker calls `folderSyncWindow`. The core's
    policy re-checks the conditions WorkManager can't express (battery %, the
    large-file threshold, Data Saver).
  - **Long transfers.** _Sync now_ with large files, or a backlog, uses a
    user-initiated data transfer job on API 34+ (`setUserInitiated`, with a
    progress notification). On older releases it runs as a worker promoted
    with `setForeground` (`foregroundServiceType="dataSync"`). Android 15 caps
    `dataSync` services at 6 hours per 24 hours, which the engine respects by
    stopping cleanly.
- **iOS.**
  - `BGAppRefreshTask` `com.getdieter.ios.folders.refresh` (about 30 s)
    exchanges the index and moves small files. Its `earliestBeginDate` is the
    preferred interval, and it is rescheduled after every run.
  - `BGProcessingTask` `com.getdieter.ios.folders.transfer` takes larger
    backlogs. It sets `requiresNetworkConnectivity`, and
    `requiresExternalPower` when _Only while charging_ is on.
  - _Sync now_ that continues after the user leaves the app uses
    `BGContinuedProcessingTask` on iOS 26 and later, which shows system
    progress. On iOS 18–25 it uses `beginBackgroundTask`, then queues a
    processing task.
  - `UIBackgroundModes` gains `fetch` and `processing`.
  - **No background `URLSession` in v1.** Calls run as roster-pinned mutual TLS
    inside relay tunnels or WebRTC channels, which only the app process can
    run.
- **A shared win.** The new background hosts give the core's existing Smart
  background mode (`BackgroundPolicy.PERIODIC`, which has no host today) a real
  host on both phones. Wiring that up is optional follow-up work.

Measurement M4 checks that the device key and session keychain items can be
used after the first unlock while the device is locked. If they can't, background runs
only happen while the device is unlocked, and the settings say so.

### 3.17 Agents

- **Linked folders.** A folder with `projectId` set adds a bounded block to the
  turn instructions of that project's conversations, but only on daemons that
  are members. The block lists at most 8 folders and 1 KiB: name, absolute
  path, mode, and one sentence: _"Files the user adds on their devices appear
  here; files you write here reach the user's Mac and phones."_ Unlinked
  folders add nothing to the prompt.
- **CLI.** Agents may run `dieter folder status|show|index|rescan` and
  `file cp --folder`. Changes to configuration refuse their turn token (§3.11).
- **Inbox and outbox.** The canonical pair: an upload-only **Inbox** on the
  phone with _Remove after upload_, and a download-only **Reports** folder on
  the phone that agents write into. The share sheet gets _Save to folder…_,
  from the Android share target and the iOS share extension.

### 3.18 UI

- **Mobile (shared Compose UI).** **Folders** in the More sheet:
  - **Folders list**: status per folder ("Up to date · 3 min ago", "Waiting
    for Wi-Fi", "2 conflicts", "Paused"), plus _Sync now_ and _Add folder_.
  - **Folder detail**: a status header; **Files**, a browser of the local copy
    where files that aren't downloaded show a cloud badge and tapping one
    downloads it, then offers open and share; **Devices** (members, their
    mode, last sync); **On this device**; **Conflicts** with keep-this or
    keep-that actions; **Recently deleted** (the daemons' trash); **Folder
    settings**.
  - **Add folder**: create a folder or join an existing one → pick the anchor
    daemon and its path → pick this device's location → direction → review.
- **Mac.** A **Folders** destination with the same list and detail (minus
  _On this device_ phone settings), _Reveal in Finder_ when the copy is on this
  Mac, browsing a daemon's copy through the existing file browser, and the
  Settings section from §3.15.
- **Attention.** Conflicts, a pending deletion guard, a lost location and a
  reached limit become items in the Inbox and notifications, using the same
  surfaces as mail and turn status.

### 3.19 Bounds

| Bound                                   | Value                                                               |
| --------------------------------------- | ------------------------------------------------------------------- |
| Folders per account                     | 64                                                                  |
| Members per folder                      | 16, at least 1 daemon                                               |
| Clients homed on one daemon, per folder | 16                                                                  |
| Version entries per file                | 64                                                                  |
| Entries per folder                      | 100,000 on daemons (`filetransfer.MaxEntries`); 25,000 on phones    |
| File size                               | 64 GiB (`MaxFileSize`); phones also follow _Download automatically_ |
| Rules per folder                        | 64 (the `strings` shape cap)                                        |
| Index page                              | 512 entries, ≤ 2 MiB (peer page bound)                              |
| Concurrent file transfers               | 4 per folder, 8 per daemon; 2 per phone                             |
| Folder tunnels per peer                 | 2 of the replication lane's 8                                       |
| Conflict copies per file                | 5                                                                   |
| Status errors retained                  | 100 per member                                                      |
| Trash                                   | 30 days; ≤ 10% of the volume or 20 GiB per folder                   |
| Deletion guard                          | > 100 files or > 30% of the folder (floor 10) per batch             |
| `folder-member` record writes           | ≤ 1 per minute per daemon and folder                                |
| Turn-instruction block                  | ≤ 8 folders, ≤ 1 KiB                                                |

### 3.20 Security and trust

The `threat-model.md` updates in this change cover:

- **New asset.** Copies of synced files on every member, phones included.
  - A lost phone exposes its copy. Removing the device from the roster stops
    further sync but doesn't erase what is already on the phone.
  - Android shared folders are readable by apps with broad storage access.
    _Private to Dieter_ avoids that.
- **Gateway.** It sees nothing new beyond tunnel volume and timing, which now
  reveal sync activity. Folder names and rules travel only in peer records
  inside tunnels.
- **Prompt injection.** An injected agent can write hostile files into a
  linked folder, and they reach phones and Macs. Quarantine on macOS members
  makes Gatekeeper check them. An agent cannot change membership, attach
  paths, confirm mass deletions or purge the trash: those calls refuse turn
  tokens, a guardrail rather than isolation, as with the vault. An agent that
  writes `DIETER_HOME` directly bypasses it, as today.
- **Malicious peer daemon.** It can forge dominating versions or deletions. The
  deletion guard, the daemons' trash, per-entry validation on ingest
  (`Clean`, NFC, lengths, protected names) and the bounds limit the damage.
  Same-account peers stay trusted operators.
- **Path safety.** Remote index entries never reach the filesystem without
  `filetransfer.Clean` and the pinned-parent `O_NOFOLLOW` walk. Symlinks are
  never followed or created.

### 3.21 Invariant impact

This needs **ADR 0005 "Synced folders"**. The feature adds a new kind of data
that moves between machines, and adds background execution to clients. The ADR
adds a _Synced folders_ section to `invariants.md`:

- Folder definitions replicate as shared records with no local paths. Content
  moves only between folder members over the roster-authenticated carriers,
  and never through gateway storage.
- Synced folders never attach a registered checkout. Replication still never
  copies a working tree.
- Agent turns cannot change folders, membership or trash.
- Every folder bound in §3.19 is binding.

Existing invariants are kept:

| Invariant                                             | How                                                                                                                          |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Data under `DIETER_HOME`, no metadata in repositories | Index, checkpoints, trash and status live in `DIETER_HOME/folders`. No marker files in user folders (root identity instead). |
| Atomic writes and the central lock                    | `Publish` plus batched index appends under `LockHome`                                                                        |
| The gateway stores no project data                    | Content and records travel only inside tunnels                                                                               |
| Bounded relays                                        | Existing lanes and budgets, 2 folder tunnels per peer, bandwidth limits                                                      |
| CLI parity on every route                             | §3.12                                                                                                                        |
| Background work only in `dieter serve`                | §3.13                                                                                                                        |
| No scopes                                             | Membership decides where copies live, not who may call                                                                       |
| One release / floors                                  | The new record kind and proto fields raise the **daemon floor**. Older daemons would reject `folder` records in peer sync.   |

## 4. Implementation plan: one pull request

### 4.1 Scope

The pull request delivers all of §3. The items in §7 stay out: a sync engine in
the Mac app, File Provider, push, folder triggers, an FSEvents helper and a
bulk relay lane.

The feature is inert until someone creates a folder:

- no watcher or peer loop runs;
- Android enqueues no work, and iOS registers its task handlers at launch (iOS
  requires that) but schedules nothing;
- turn instructions are unchanged.

So the change needs no feature flag. The existing invariants and the bounds in
§3.19 are the guard rails.

### 4.2 Branch, commits and review

- **One branch, one PR.** This card's branch
  (`dieter/d3faf74dae33-can-you-ideate-a-feature-for-synchro`) against `main`.
- **About 24 logical commits**, in the dependency order of §4.4. Each commit
  builds and passes the tests of the packages it touches, so the PR can be
  reviewed commit by commit. Generated code is a commit of its own.
- **Sign-off.** Every commit carries a DCO `Signed-off-by` and passes the
  pre-commit hook (`just hooks`). Never `--no-verify`.
- **PR description.** It holds:
  - a reviewer guide that maps each commit to its section of this proposal;
  - the measurement results (§4.3) and the verification evidence (§4.6);
  - the results of the manual iOS background soak.
- **Rebase at each milestone** (§4.5). After a rebase that touches `api/proto`,
  run `just generate` again and do not merge generated files by hand.
- **Floor.** The commit that adds the `folder` record kind also raises the
  minimum daemon release in `internal/platform/version`. Older daemons would
  reject the new records in peer sync. Clients need no new floor: an old
  client simply doesn't show folders.

### 4.3 Measurements (first commits)

Each measurement has an acceptance threshold and a fallback that stays inside
the PR, so none of them can block it. The harness lives in
`tools/spikes/folders/`. Results go to
`docs/proposals/synced-folders-results.md`.

| ID     | What                                                                                                                                                                                                 | Accept if                                          | Otherwise (inside the PR)                                                                                                                            |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **M1** | Stat-only walk of 100,000 entries on the Mac mini and a Linux box, plus the kqueue descriptor count for watching directories                                                                         | Walk ≤ 2 s; ≤ 5% CPU on average at a 60 s interval | The walk interval scales with size (60 s per 25,000 entries); the FSEvents helper becomes the first follow-up                                        |
| **M2** | p95 latency of interactive RPCs (`GetState`, `ListFiles`) over the fixture gateway's relay with 0, 2 and 4 chunk streams on the command lane; folder pulls next to peer sync on the replication lane | p95 rises ≤ 20%                                    | Phones use 1 stream and daemons 1 folder tunnel per peer; a `bulk` lane becomes a follow-up                                                          |
| **M3** | SAF on the warm emulator and on a Pixel through a profile that names its serial: scan 10,000 nested files; write-and-rename throughput                                                               | Scan ≤ 10 s                                        | The phone entry bound drops from 25,000 to 10,000, with a clear _Too many files for this phone_ status                                               |
| **M4** | Keychain accessibility of the iOS device key and session items while the phone is locked (code inspection; the operator confirms on a real iPhone)                                                   | Usable after the first unlock                      | Background runs happen only while unlocked, and the settings say so. Keychain attributes are **not** changed in this PR: that touches authentication |

The phone's index storage needs no measurement. It is sharded Wire files (§6).
A `jvmTest` guards it: one changed entry rewrites at most one shard, and a cold
load of 25,000 entries stays under a fixed budget.

### 4.4 Work breakdown, in commit order

| #   | Commit                       | Files                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Tests in the commit                                                                |
| --- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 1   | ADR and invariants           | `docs/adr/0005-synced-folders.md`; a _Synced folders_ section in `docs/invariants.md`; this proposal's status                                                                                                                                                                                                                                                                                                                                                                                                                | –                                                                                  |
| 2   | Measurements                 | `tools/spikes/folders/` (walk, lane and SAF harnesses); `docs/proposals/synced-folders-results.md`                                                                                                                                                                                                                                                                                                                                                                                                                           | –                                                                                  |
| 3   | Protocol                     | New `api/proto/dieter/v1/folders.proto`. `files.proto`: `TransferPath.folder_id`, `BeginFileUploadRequest.folder_version`. `state.proto`: `ChangesFrame` folder heads. `client/v1/client.proto`: `FoldersCommand`, slices `FOLDERS`, `FOLDER` and `FOLDER_SYNC_SETTINGS`, updates and results. New `core/v1/folders.proto`: index shard, transfer journal, `FolderSyncSettings`                                                                                                                                              | `buf lint`                                                                         |
| 4   | Generated code               | `just generate`: `internal/gen`, DieterKit Swift                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Generation drift check                                                             |
| 5   | Pure rules (Go)              | New `internal/folders/`: `version.go`, `entry.go` (NFC, lengths, `Clean`), `reconcile.go`, `conflict.go` (winner, copy names), `guard.go`, `names.go` (case and charset collisions), `order.go` (work order). Golden vectors in `tests/fixtures/folders/`. A depguard rule: stdlib, `fault` and `filetransfer` only                                                                                                                                                                                                          | Golden vectors; fuzzing of `entry` validation                                      |
| 6   | Filesystem primitives        | `internal/filetransfer/`: `walk.go` (recursive pinned-descriptor walk that reports mount points and symlinks), `dirs.go` (`Mkdir`, remove an empty directory), `trash.go` (rename on the same device, otherwise a bounded copy), `identity.go` (root `(dev, ino)`), `blocks.go` (1 MiB block hashes; publish from local blocks plus fetched ones), `quarantine_darwin.go`/`_linux.go`                                                                                                                                        | Temp-dir tests, including races and symlink substitution                           |
| 7   | Replication schema and floor | `schema/domain.go`: the `folder` kind and its enums. New `schema/folder.go`: the `folder-member` namespace and its bounds. `internal/api/kv.go`: the public KV API refuses `folder-member`. `internal/platform/version`: daemon floor                                                                                                                                                                                                                                                                                        | Schema validation; KV refusal                                                      |
| 8   | Store aggregate              | New `internal/store/folders/`: member, index (segment log, snapshot, compaction), peers, clients, trash manifest, status, block cache. Wiring in the store composition root. Store layering in `.golangci.yml`, at the `channels`/`mail` level                                                                                                                                                                                                                                                                               | Crash recovery (a kill between publish and append), compaction, bounds             |
| 9   | Folder-aware upload commit   | `internal/host/filetransfer/manager.go`: commit of a folder target calls a `FolderCommitter` under the same `LockHome` (version check and index append)                                                                                                                                                                                                                                                                                                                                                                      | Conflict on a stale version; receipt recovery                                      |
| 10  | Engine: local side           | New `internal/host/folders/`: `manager.go`, `watch_linux.go`, `watch_darwin.go`, `scan.go`, `guardrails.go`, `guard.go`, `trash.go` (retention sweeper), `status.go` (heads, errors)                                                                                                                                                                                                                                                                                                                                         | Temp-dir tests: attach refusals, root change pauses, guard trips, echo suppression |
| 11  | Engine: remote side          | `peer.go` (index exchange through `peersync.DialPeer`, at most 2 tunnels per peer, backoff, checkpoints), `pull.go`, `blocks.go`, `reuse.go`, `clients.go` (registry, acknowledgements, tombstone collection), `record.go` (`folder-member` writer, at most once a minute)                                                                                                                                                                                                                                                   | Two in-process engines over a fake peer                                            |
| 12  | Daemon composition           | `internal/daemon/services.go`, `run.go`: the engine starts only in `dieter serve`                                                                                                                                                                                                                                                                                                                                                                                                                                            | `serve_test.go`: constructing a handler starts nothing                             |
| 13  | API                          | New `internal/api/folders.go`; mounted in `service.go`; `file_transfers.go` (folder root, `folder_version`); `changes.go` (folder heads); a shared turn-token guard extracted from `trust.go`                                                                                                                                                                                                                                                                                                                                | `folders_test.go`; turn-token refusals; `TestGRPCAPIImplementsEveryDeclaredRPC`    |
| 14  | CLI                          | `internal/cli/commands.go`, new `rpc_folders.go`, `--folder` in `rpc_file_transfer.go` and `file_transfer_endpoint.go`, `rpcCommand` in `help_contract_test.go`, regenerated `site/content/docs/reference/cli.md`                                                                                                                                                                                                                                                                                                            | Help contract; offline help                                                        |
| 15  | Agents                       | `internal/prompt/prompt.go`: the linked-folders block; engine plumbing for it                                                                                                                                                                                                                                                                                                                                                                                                                                                | `prompt_test.go`: contract, bounds, only on member daemons                         |
| 16  | Go end-to-end                | New `internal/testkit/topology/folders_e2e_test.go`, `internal/cli/folder_cli_e2e_test.go`, `tools/fixtures/gateway/folders_fixture.go` (a seeded folder whose daemon member is a temp dir)                                                                                                                                                                                                                                                                                                                                  | §5, on local, direct-TLS and relay-only routes                                     |
| 17  | Core rules (Kotlin)          | `core/runtime/.../folders/`: `Versions.kt`, `Reconcile.kt`, `Names.kt`, `Guard.kt`                                                                                                                                                                                                                                                                                                                                                                                                                                           | `commonTest` reading `tests/fixtures/folders/`                                     |
| 18  | Core engine                  | `FolderIndex.kt` (sharded `CoreStorage`), `FolderTransfers.kt`, `FolderSync.kt`, `FolderSyncPolicy.kt`, `FolderSyncSettings.kt`, `FolderPlatform.kt` (`FolderFileSystem`, `DeviceConditions`, `FolderScheduler`), `Folders.kt` (surfaces). Changes to `api/DaemonApi.kt`, `sync/AccountView.kt`, `CoreRuntime.kt` (`folderSyncWindow`), `client/FolderCommands.kt`, `ClientApi.kt`, `Surfaces.kt`                                                                                                                            | Policy matrix; engine against fakes; `:core:e2e` against the fixture daemon        |
| 19  | Android shell                | WorkManager in `libs.versions.toml` and `android/build.gradle.kts`. New `android/.../folders/`: `FolderSyncWorker.kt`, `FolderTransferJob.kt` (user-initiated job on API 34+, `dataSync` worker below), `SafFolderFileSystem.kt`, `PrivateFolderFileSystem.kt`, `AndroidDeviceConditions.kt`, `FolderNotifications.kt`. `AndroidManifest.xml`: `RUN_USER_INITIATED_JOBS`, `FOREGROUND_SERVICE(_DATA_SYNC)`, `POST_NOTIFICATIONS` and service declarations. Tree picker in `ui/src/androidMain/.../NativeSurfaces.android.kt` | `just android test_unit`                                                           |
| 20  | iOS shell                    | `ios/App/Info.plist`: `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `UIBackgroundModes` (`fetch`, `processing`), `BGTaskSchedulerPermittedIdentifiers`. `ios/App/DieterApp.swift`: task registration. New `ios/Host/Sources/DieterIOS/Folders/`: `FolderBackgroundTasks.swift`, `ContainerFolderFileSystem.swift`, `IOSDeviceConditions.swift`. Platform bridge in `core/apple/.../DieterShared.kt`. _Save to folder…_ in `ios/Share/`                                                                        | `:core:runtime:iosSimulatorArm64Test` on a disposable simulator                    |
| 21  | Shared Compose UI            | New `ui/src/commonMain/.../folders/`: Folders list, detail, file pane, _On this device_, Folder sync settings, add-folder flow, conflicts, trash. `tools/ToolScope.kt` (`ToolPage.FOLDERS` in More), `settings/SettingsScreen.kt`, _Save to folder…_ in `share/ShareTargetScreen.kt` and `store/SharingModel.kt`, Inbox attention items                                                                                                                                                                                      | `:ui:jvmTest` offscreen tests                                                      |
| 22  | Mac app                      | New `mac/Sources/DieterMacKit/Features/Folders/` (list, detail, _Add this Mac_ with `NSOpenPanel` → local `AttachFolder`, _Reveal in Finder_ through `FileExternalActions`); a Folders section in `DieterSettingsView.swift`; the sidebar destination                                                                                                                                                                                                                                                                        | `just mac test_unit` (check the summary line); `check-api-boundary.sh`             |
| 23  | Device flows                 | New `tests/maestro/mobile/folders.yaml` (smoke) and `tests/maestro/mac/folders.yaml`                                                                                                                                                                                                                                                                                                                                                                                                                                         | Maestro lint                                                                       |
| 24  | Documentation                | New `site/content/docs/synced-folders.md`; `site/content/docs/file-transfers.md`; `site/content/docs/architecture.md`; `docs/architecture.md` (components, packages); `docs/threat-model.md` (§3.20); `.agents/skills/dieter-cli/SKILL.md`; this proposal set to _implemented_, with deviations recorded                                                                                                                                                                                                                     | `just site check`                                                                  |

### 4.5 Milestones inside the PR

| Milestone           | Commits | Done when                                                                                                                                                                        |
| ------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. Foundation**   | 1–9     | Go unit tests of the touched packages pass, `just generate` shows no drift, and the measurements are written up                                                                  |
| **B. Daemons sync** | 10–16   | The topology E2E passes on all three routes. A manual run works on isolated daemons (temporary `DIETER_HOME`, free loopback ports, fixture gateway); never the operator's daemon |
| **C. Core engine**  | 17–18   | The same golden vectors pass in Go and Kotlin, and `:core:e2e` syncs against a fixture daemon                                                                                    |
| **D. Apps**         | 19–22   | A file round-trips daemon ↔ app on the warm emulator and a disposable simulator; settings and background scheduling work on the emulator                                         |
| **E. Finish**       | 23–24   | Device flows, documentation, the 24 h soak and the full verification gate (§4.6) pass                                                                                            |

### 4.6 Verification gate (before the PR leaves draft)

The gate follows `AGENTS.md`. Start with the dry run, run each selected check
once at the end, rerun only what failed, and run Gradle and Xcode builds one at
a time:

```sh
mise exec -- just check-changed --dry-run
mise exec -- just generate && git diff --exit-code
mise exec -- just lint
mise exec -- just test
mise exec -- just test-e2e
mise exec -- just kotlin :core:runtime:jvmTest :ui:jvmTest
mise exec -- just kotlin :core:runtime:macosArm64Test :core:apple:macosArm64Test
mise exec -- just kotlin :core:e2e:test
mise exec -- just android test_unit
mise exec -- just mac test_unit
mise exec -- just e2e android profile:android-emulator flows:folders
mise exec -- just e2e ios flows:folders
mise exec -- just e2e mac flows:folders
mise exec -- just site check
```

Two more checks have no CI equivalent. Both are required before merge and
reported in the PR:

- **The 24 h soak** (§5), run on isolated daemons and the warm emulator.
- **A 3-day iOS background soak** on a real iPhone, run by the operator. There
  is no physical-iPhone E2E. It records actual run cadence, the
  locked-device behavior (M4) and `BGContinuedProcessingTask` on iOS 26.

### 4.7 Size and risks

**Rough size**, hand-written lines excluding generated code, about 23,000 in
total:

| Area                    | Lines (approx.) |
| ----------------------- | --------------- |
| Go, including tests     | 9,000           |
| Kotlin core             | 6,000           |
| Compose UI              | 3,000           |
| Android and iOS shells  | 2,000           |
| Mac                     | 1,500           |
| Proto and documentation | 2,000           |

| Risk                                     | Mitigation                                                                                                                        |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Review load of one large PR              | Commits that pass on their own, in dependency order; a reviewer guide; generated code isolated                                    |
| Branch drift over weeks                  | Rebase at every milestone; regenerate instead of merging generated files                                                          |
| Data-loss bugs                           | Pure rules shared through golden vectors; crash and unmount tests; the guard and the trash; the soak; inert until a folder exists |
| Platform background behavior             | Honest UI copy ("iOS decides"); the core's policy is unit-tested and the platform hosts stay thin                                 |
| Relay contention                         | M2 with an in-PR fallback (§4.3)                                                                                                  |
| The floor bump forces daemons to upgrade | Called out in the release notes. Every daemon of an account must run the new release before any folder records replicate          |
| CI time                                  | Every surface is affected, so expect long runs. Device flows run once at the end                                                  |

## 5. Tests and verification

- **Go unit tests.**
  - Reconcile golden vectors: dominance, concurrency, delete vs. modify, file
    vs. directory, the deterministic winner, case collisions, rules.
  - Index log crash recovery: kill the process between publish and append.
  - Root identity change (a simulated unmount) and the deletion guard
    thresholds.
  - Guardrails: refusing `DIETER_HOME`, checkouts and overlaps.
  - Tombstone collection. Echo suppression after a publish.
- **Go end-to-end** (`internal/testkit/topology`, `-tags e2e`). Two to three
  daemons and the fixture gateway, run over local, direct-TLS and relay-only
  routes:
  - create, attach and converge;
  - a partition with concurrent edits produces exactly one conflict copy
    everywhere;
  - an interrupted large transfer resumes;
  - a mass delete pauses, then restore works;
  - a CLI parity test for every `dieter folder` command;
  - `TestGRPCAPIImplementsEveryDeclaredRPC` and the help-contract tests keep
    passing.
- **Kotlin `commonTest`.**
  - The same golden vectors.
  - `FolderSyncPolicy` across the full matrix of interval, network, power,
    storage and size.
  - The engine against a fake `FolderFileSystem` and a fake daemon: budget
    expiry mid-run, resuming from the journal, `absent_by_policy` never
    becoming a delete, _Remove after upload_ evicting files.
- **Maestro** (E2E app identities, the fixture gateway's seeded folder, the
  warm emulator, disposable simulators):
  - **mobile** (`folders.yaml`, smoke): a daemon-side file appears in Folders;
    a file added on the device reaches the daemon; settings persist across a
    restart; the Wi-Fi-only paused state; the conflict UI;
  - **Mac** (`folders.yaml`): the Folders destination lists the seeded folder
    and its members, and the folder settings save.
- **Soak test.** 50,000 files and 10 GB with random churn across 2 daemons and
  1 emulator for 24 h. It checks convergence, bounded memory and file
  descriptors, and that relay byte budgets are never exceeded.
- Verification follows `AGENTS.md`: `just check-changed --dry-run`, the
  selected checks run once at the end, and Gradle and Xcode run one at a time.

## 6. Decisions

Taken 2026-11-13:

1. **iOS location.** The app's Documents container, shown in Files as _On My
   iPhone › Dieter_. A File Provider is a follow-up.
2. **Mac.** A Mac keeps a copy only through a daemon running on it. The Mac app
   manages folders and reveals the copy in Finder. It has no sync engine in
   this PR.
3. **Registered checkouts** and paths inside them are refused as folder
   locations.
4. **Agent visibility** is opt-in per folder, through the project link.
5. **Push-triggered sync** is deferred.
6. **Delivery.** Everything in §3 ships in one pull request (§4).
7. **macOS change detection.** kqueue on directories plus a 60 s stat walk; M1
   sizes it.
8. **Phone index storage.** Sharded Wire files in `CoreStorage`, with no
   database.
9. **Relay lanes.** The existing lanes. A `bulk` lane only as a follow-up, if
   M2 shows contention.
10. **Trash** lives on daemons only. Phones delete directly, and any device can
    restore from a daemon's trash.

## 7. Out of scope and follow-ups

- A sync engine in the Mac app, for a local copy on a Mac without a daemon.
- File Provider extensions on iOS and macOS (online-only files in Files and
  Finder).
- Push-triggered sync (contentless pings through APNs and FCM).
- An FSEvents mode in the native macOS helper, if M1 shows the stat walk costs
  too much.
- A `bulk` relay lane, if M2 shows contention. It changes the relay protocol
  and raises the floors.
- Hosting the core's existing Smart background mode on the new background
  hosts.
- Automatic camera-roll upload into a folder.
- Selective sync of subdirectories on a member, beyond rules and
  auto-download.
- Sharing a folder with another account.
- Folder triggers that start turns. These are a new source of turns and need
  an ADR next to schedules and agent channel wakes.
- File version history beyond the trash.

## 8. Implementation notes and deviations

What the pull request does differently from §3 and §4, and why:

- **macOS change detection** is a stat walk every 60 s; kqueue on directories
  was not built (fsnotify's kqueue backend needs a descriptor per file, and M1
  shows the walk costs 0.35% of a core for 100,000 entries).
- **Deletions settle for 3 s** before a scan records them, and the deletion
  guard judges every missing path at once, so `rm -rf` in progress is held as
  one batch (found by the end-to-end tests).
- **Recorded revisions may be stale, never wrong.** `filetransfer.PublishWith`
  returns the revision observed before the rename and `Preserve` the revision
  after its hard link; a daemon that serves a read refreshes a stale revision
  when the content hash still matches.
- **Phones transfer one file at a time** (M2 fallback); daemons pull between
  themselves on the replication lane with one connection per peer.
- **iOS background runs connect only while the iPhone is unlocked** (M4): the
  Secure Enclave device key uses CryptoKit's default access control. The
  caption and the guide say so; key attributes are unchanged.
- **M3 (SAF) was not measured**; the phone bound stays 25,000 entries.
- **Browsing another machine's copy**: the six editor file calls
  (`ListFiles` … `DeleteFile`) gained `folder_id`, and the client `FilesTarget`
  a `folder_id`, so the Mac and phones browse any daemon member's copy in the
  existing Files surface.
- **`UpdateFolderMember` without fields is a read** of the daemon's membership
  (path, mode, limits) and is allowed for agent turns.
- **The CLI refuses folder changes inside an agent turn** before contacting any
  daemon, because a turn token reaches only the local daemon.
- **Phone engine scope**: block-level updates and local reuse by content hash
  run on daemons; the phone engine downloads whole files. Upload-only
  "Override folder" and download-only "Keep" actions, folder items in the
  Inbox, and an iOS `NSFilePresenter` are follow-ups.
- **Daemon floor**: `deploy/gateway/compatibility-policy.json` requires
  0.6.445; adjust it to the release that ships this change.
