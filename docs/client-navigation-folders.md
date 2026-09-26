# Shared navigation and account KV

Mac and Android organize projects and standalone chats using the same account
KV namespace, `navigation`. Folder membership never changes project identity,
conversation ownership or pin state. Deleting a folder returns its contents to
the unfiled list; it never deletes resources. Unavailable/filtered resource IDs
remain in the layout.

The daemon's existing leaderless peer store holds the authoritative records.
Native clients keep an account cache and a durable pending queue. Each accepting
daemon acknowledges its own SQLite commit; other daemons converge over verified
direct TLS, WebRTC (direct or TURN), or relay. The gateway stores no KV contents.

## Contract

`GetKV`, `ListKV`, `PutKV`, `DeleteKV`, `MoveKV`, and `WatchKV` use the current
release compatibility baseline. Namespaces and keys use ASCII letters, digits, dots,
dashes and underscores. Namespaces are at most 120 bytes; keys at most 128.
Values are canonical JSON, at most 32 KiB. Namespaces are data organization,
not authorization scopes: clients retain binary full account access.

A write includes the account, accepting daemon ID, operation ID, and expected
revision. Empty revision means create only. Compare-and-set is local to the
accepting replica, not a globally linearizable lock. Retrying exactly the same
request on that daemon returns its original durable receipt, even after a
restart or subsequent writes. Reusing an operation ID with different input fails.
Receipts commit atomically with records and are bounded to 65,536/64 MiB per
account per daemon. Capacity errors are explicit; receipts are not silently aged
out. A pending request with an uncertain outcome waits for its accepting daemon.

The generic JSON store preserves causal siblings. Its deterministic projection
selects the greatest canonical version hash, with concurrent deletion winning.
Clients inspecting meaningful conflicts can read all versions and resolve with
the observed revision. This is eventual state convergence, not etcd consensus,
a distributed lease, or an audit log.

`ListKV` returns up to 64 records plus a snapshot cursor and continuation key.
A changed snapshot returns Aborted. `WatchKV` bootstraps from current records in
bounded pages, then follows persisted changes. On reset, build a replacement
projection and publish it at `caughtUp`. Cursors are replica epoch/sequence pairs;
a replaced or different replica resets the stream. Intermediate edits can be
coalesced. Tombstones are retained. Watches have no unbounded subscriber queues,
poll cross-process commits every 250 ms, and allow at most 64 subscriptions per
daemon. Peer synchronization remains bounded and coalesces local wakeups.

## Portable navigation records

| Key | JSON value |
| --- | --- |
| `projects-folder.ID.name`, `chats-folder.ID.name` | Folder name, at most 256 UTF-8 bytes; tombstone deletes folder |
| `projects-folder.ID.expanded`, `chats-folder.ID.expanded` | Boolean |
| `projects-folder.ID.position`, `chats-folder.ID.position` | Parent/rank tuple |
| `projects-item.ID.position`, `chats-item.ID.position` | Folder ID and rank together |
| `projects-order.ID.position`, `pinned-order.ID.position` | Top-level project and pinned-chat ordering |
| `projects-pinned.ID.position` | Pinned-project membership and ordering; deleting the record unpins the project |
| `projects-disclosure.ID.expanded` | Project sidebar disclosure |
| `chats-section.ID.expanded`, `chats-disclosure.ID.expanded` | Chat project section and details disclosure |
| `lane.BOARD.LANE.sort` | `ascending` or `descending` |

`MoveKV` computes an immutable fractional rank between stable neighboring keys.
Moving one item changes only its atomic parent/rank record. Independent edits
merge without overwriting a complete folder array. An absent parent folder
projects its retained items as unfiled. Duplicate names created concurrently
retain distinct folder identities. UI rename rejects local duplicate names;
there is no global uniqueness lock.

Native clients show pending navigation edits, retain an account cache across
restarts, and isolate queues when switching accounts. An offline rename checks
that its folder still exists before delivery. A stale accepting replica cannot
replace a cached acknowledged value until its causal clocks catch up. Logout
clears the active account binding; another account cannot deliver the old queue.
Window sizes, current selection, scroll offsets and search queries remain local.

This is a pre-release cutover. Old folder arrays and ordering preferences are
not read, imported or dual-written. The pure UI models project shared records.

## CLI

All operations use the running daemon API. Global `--machine ID|NAME` selects a
remote enrolled daemon through the existing authenticated transports.

```sh
dieter kv list --namespace navigation
dieter kv get --namespace navigation --key projects-folder.ID.name
dieter kv put --namespace navigation --key projects-folder.ID.name --file name.json
dieter kv move --namespace navigation --key projects-item.ITEM.position --parent FOLDER
dieter kv watch --namespace navigation --count 2
```

`put`, `delete` and `move` accept `--revision`, `--operation`, `--account`, and
`--daemon`. Preserve these values and the exact input when retrying an uncertain
mutation. CLI errors report the admitting account/daemon and operation ID.
