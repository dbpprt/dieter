# ADR 0005: Synced folders

- Status: accepted 2026-11-13, implemented in the synced-folders pull request
- Proposal: [docs/proposals/synced-folders.md](../proposals/synced-folders.md)

## Context

Getting a file from a phone to an agent, or an agent's result onto a phone,
took a detour. Attachments are sent inline with a message, at most 4 files and
6 MB in total. `dieter file cp` and `dieter file sync` move larger files, but
only from a computer that runs the CLI, one way and on demand. Users asked for
an inbox they fill from the phone's share sheet and an outbox where agents
leave reports that show up on the phone and the Mac.

Nothing in Dieter moved file content between devices on its own. Peer
replication carries shared records that deliberately hold no local paths, and
the invariants say it never copies a working tree. The phones had no background
execution, no persistent access to a folder and no notion of network or battery
conditions. Clients never accept connections, so two phones can't reach each
other.

## Decision

Adopt the proposal's design with the decisions in its §6:

- **Folders are shared records without paths.** A folder (ID, name, rules,
  trash policy, deletion guard, optional linked project, archived flag) is a
  shared record kind, `folder`, with one register per field. Each daemon member
  describes its own membership, and the phones homed on it, in a single-writer
  KV record, `folder-member`, that only that daemon writes; the public KV API
  refuses it. The directory a daemon binds stays in its own store, and other
  devices learn it only by asking that daemon.
- **Daemons are the hubs.** Every folder has at least one daemon member.
  Daemon members sync with each other without a leader: each pulls the content
  it needs from any daemon member that has the wanted version.
- **Phones sync with a home daemon.** An Android phone or an iPhone syncs only
  with one daemon member, chosen automatically (a direct route first, then the
  most recently reachable) or pinned by the user, and fails over to the next.
  Phones are never the only copy and never talk to each other.
- **Macs take part only through their daemon.** A Mac keeps a copy only when a
  daemon runs on it. The Mac app manages folders, shows that copy as "This Mac"
  and reveals it in Finder, but runs no sync engine, so nothing competes with
  the daemon for the directory.
- **Content travels only over roster-authenticated carriers.** Files move with
  the existing chunked, revision-checked, resumable `FileService` calls, whose
  `TransferPath` gains a `folder_id`, and are published with
  `filetransfer.Publish`. Every byte runs inside the mutual TLS connection
  between two roster devices (direct, WebRTC or relay tunnel) and never through
  gateway storage. Daemons use at most 2 of the replication lane's 8 tunnels
  per peer; phones use the command lane with at most 2 transfers at once.
- **Version vectors decide, never wall clocks.** Each member keeps an index of
  entries with version vectors. Concurrent edits keep both versions: a
  deterministic winner keeps the name and the other becomes a visible conflict
  copy. An edit beats a concurrent delete and a directory beats a file. The
  rules exist once in Go and once in the Kotlin core and pass the same golden
  vectors.
- **Nothing silently destroys content.** Every download is a compare-and-swap
  against the observed local revision. A missing or replaced folder root, or a
  revoked tree permission, pauses the member instead of becoming deletions; no
  marker file is written into the user's folder. A deletion guard holds mass
  deletions until a person applies or restores them. Daemon members move
  deleted and overwritten files to a trash under `DIETER_HOME`; phones delete
  directly, and any device can restore from a daemon's trash.
- **Folders never attach registered checkouts.** `AttachFolder` refuses `/`,
  the home directory itself, system directories, `DIETER_HOME` and any path
  that contains it or lies inside it, a path that overlaps another member on
  the same daemon, and a registered checkout or any path inside one. `.git` is
  never synced. Git keeps working trees in sync; replication still never copies
  one.
- **Agent turns can't change folders.** `CreateFolder`, `UpdateFolder`,
  `ArchiveFolder`, `AttachFolder`, `UpdateFolderMember`, `DetachFolder`,
  `RegisterFolderClient`, `UnregisterFolderClient`, `ResolveFolderDeletions`
  and `PurgeFolderTrash` refuse a turn token, and the CLI refuses them inside a
  turn before it contacts any daemon, as it does for device trust. Turns may
  read folders and status, rescan, restore from the trash and transfer files.
  A folder linked to a project adds a bounded block (at most 8 folders and
  1 KiB) to the turn instructions of that project's conversations, only on
  daemons that are members. Received files on macOS members get
  `com.apple.quarantine` by default.
- **Storage.** A daemon keeps its member binding, index, peer checkpoints,
  client registry, trash and status in its own store aggregate under
  `DIETER_HOME/folders`, written atomically under the central lock. A phone
  keeps its index as sharded Wire files in the core's storage, with a transfer
  journal; its folder sync settings are device-local and never replicated.
- **Background work.** The daemon engine starts only with `dieter serve`. A
  phone syncs inside bounded run windows that its platform background host
  grants, under a policy in the core that the user's settings drive.
- **Bounds.** 64 folders per account; 16 members per folder, at least one a
  daemon; 16 phones homed on one daemon per folder; 64 counters per version;
  100,000 entries per folder on daemons and 25,000 on phones; 64 GiB per file;
  64 rules; index pages of 512 entries and at most 2 MiB; 4 transfers per
  folder and 8 per daemon, 2 per phone; 2 folder tunnels per peer; 5 conflict
  copies per file; 100 retained errors per member; trash for 30 days by default
  and at most 10% of the volume or 20 GiB per folder; a deletion guard at more
  than 100 files or 30% of the folder (at least 10) per batch; one
  `folder-member` write per minute per daemon and folder; a turn-instruction
  block of at most 8 folders and 1 KiB.

## Consequences

- `docs/invariants.md` gains a _Synced folders_ section with these rules.
- The `folder` record kind and the new proto fields raise the **daemon floor**
  (`internal/platform/version`). An older daemon would reject `folder` records
  in peer sync, so every daemon of an account must run the new release before
  folder records replicate. Clients need no new floor: an older client simply
  shows no folders.
- Phones gain background execution. Android schedules WorkManager periodic
  work with constraints from the settings and runs long transfers as
  user-initiated data transfer jobs (a `dataSync` foreground worker before
  Android 14). iOS registers `BGAppRefreshTask` and `BGProcessingTask`
  handlers, uses `BGContinuedProcessingTask` on iOS 26 for _Sync now_, and
  declares the `fetch` and `processing` background modes. iOS decides when
  background runs happen, and the settings say so. Nothing is scheduled until a
  folder exists on the device. The core's existing Smart background mode can
  use the same hosts later.
- Phones hold new data: copies of synced files, the local index and the
  transfer journal. Revoking a phone from the roster stops further sync but
  doesn't erase its copy. An Android shared folder is readable by apps with
  broad storage access; _Private to Dieter_ avoids that. The threat model
  covers both.
- On macOS daemons, kqueue watches directories and a stat walk every 60 s
  catches in-place edits, so such an edit can take up to a minute to start
  syncing. An FSEvents mode in the native helper is a follow-up.
- Out of scope, as follow-ups: a sync engine in the Mac app, File Provider
  extensions, push-triggered sync, a `bulk` relay lane, selective sync and
  folder triggers that start turns, which need their own ADR.
