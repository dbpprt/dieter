# High-priority assessment remediation — 29 September 2026

Work starts from `afc07c9a` in the assigned project checkout. This is the working
record for the four findings quoted on the card, in their requested order.
The available `product-assessment-2026-09-28.md` provides related trust context,
but does not contain the quoted technical findings or identify the three Android
bugs. The exact source assessment has been requested; unverified details below
are not treated as confirmed reproductions.

## Step 2: gateway availability

**Confirmed.** `Hub.authenticateLink` allows 64 concurrent unauthenticated
handshakes. Its `Recv` uses the server-wide 16 MiB receive limit, and only then
does `handshake` check the decoded HELLO against 64 KiB. The proof has the same
large transport limit. That permits roughly 1 GiB of advertised message
allocations, before protobuf and transport overhead, against the example
192 MiB container. Public unary methods have a small HTTP body limit, but that
alone does not constrain allocation from the gRPC envelope.

OAuth and enrollment rates use the immediate peer. The recommended single-IP
deployment discards the client address at HAProxy, then again at the gateway's
Caddy hop. Merely accepting an arbitrary forwarding header would introduce
spoofing and would not fix the first hop.

**Implemented in this change.**

- Inspect the five-byte gRPC envelope before exposing it to the decoder. Bound
  both handshake messages to 64 KiB and public unary messages to 8 KiB; reject
  compression on those public messages.
- Admit handshakes and public unary calls before gRPC starts its body reader.
  Hold subsequent daemon frames until the Ed25519 challenge proof succeeds.
  Close/cancellation unblocks the reader. Successful authentication releases the
  handshake slot; it does not impose a 64-daemon connection cap.
- Reject unauthenticated relay calls before starting their body readers too.
- Bound HTTP/2 upload windows to 64 KiB per stream and 1 MiB per connection.
- Preserve the client address using HAProxy PROXY v2, require it on Caddy's
  loopback TLS listener, and overwrite `X-Forwarded-For` at Caddy. Trust exactly
  one valid IP only from the gateway's explicit loopback-proxy configuration.
- Cover envelope rejection, compression, pipelining, admission, reader close,
  HTTP/2 enrollment isolation, and spoofed headers. Extend the real-container
  integration probe to exercise two distinct source addresses through both hops.

**Verification completed.** `just check-changed --dry-run` selected deployment
units, real-container integration, affected Go race tests, and `go vet`.
`just check-changed` then passed all of them (36 deployment unit tests; existing
Go race results were reused from the test cache). `git diff --check` passed.

Docker was unavailable because the existing Colima VM was stopped and the active
context pointed to the absent `/var/run/docker.sock`. Starting the existing VM
restored Docker and selected its `colima` context. Initial image builds hit
connection refusals from `proxy.golang.org`; an exact-release build subsequently
downloaded dependencies and compiled successfully, and the integration build
then passed. No dependency pins or network settings were changed. Colima remains
running for local development.

The pinned HAProxy, Caddy, gateway, and coturn containers passed:

- Separate enrollment rate buckets for two client source IPs, including attempts
  to bypass limits by changing a spoofed forwarding header.
- 512 oversized unauthenticated daemon envelopes at concurrency 64 through both
  proxies. Each advertised 16 MiB using only its five-byte header and was rejected
  for resource exhaustion. The gateway had a 192 MiB memory limit with no extra
  swap, remained running, and recorded no OOM or restart. Its cgroup v2 peak at
  that point was **11,587,584 bytes (11.1 MiB)**. This bounded regression exercises
  preallocation rejection; it is not a long soak or a total-memory guarantee for
  every workload.
- TLS 1.3/HTTP2 and unauthorized gRPC behavior; unknown/missing SNI and TLS 1.2
  rejection; bidirectional UDP/TCP/TLS TURN payloads and invalid credentials;
  active TURN allocation survival across certificate reload; and readiness with
  only one allocation available in the quota bucket.

The fixture cleaned up its containers, network, volumes, and image. The extra
diagnostic image and store-probe source were removed too. No production gateway
deployment or operator-daemon restart was performed.

## Step 3a: streaming durability overhead

**Implemented: conditional cache updates and bounded durable token batches.**
Before this change, every UI chunk opened a conversation transaction and then
called `UpdateCardCache`. Even when every cached value matched, that method's
deferred commit emitted `store_changed`. An isolated ten-call reproduction left
the card unchanged but advanced the sync sequence ten times. The ordinary no-op
path cost seven fsync calls by source inspection, excluding recovery/compaction.

`UpdateCardCache` now compares under the central cross-process lock after the
same pending-write, peer-effect, and schedule-outbox recovery as other writers.
It prepares a new durable mutation only when a value changes. Real changes retain
atomic card/peer publication, title/runtime revisions, notifications, and
checkpoint handling. Omitted fields, explicit empty options, and account clearing
retain their existing meanings. Recovery notifications remain safe hints even
when no new mutation was necessary.

The turn runner now buffers adjacent text, reasoning, and tool-input deltas with
three bounds: **32 events, 64 KiB of chunk payload, or 20 ms from the first pending
delta**. The timer flushes even while the worker is idle. The 20 ms bounds batching
wait, not disk/lock latency or downstream backpressure. Larger individual chunks
use the existing single-event size limit. The producer uses an unbuffered handoff
and each retained chunk owns its bytes.

A store batch preserves every event and its sequence. It takes the writer lock
once, appends all validated newline-terminated records with one journal fsync,
reduces them in order, and publishes one sync transaction. Activity updates,
projection caching, and optional checkpoints run once per batch. A batch crossing
a 128-event checkpoint boundary checkpoints its complete end. Finish/usage events
still invalidate metadata; text-only batches retain conversation-only sync.

Semantic outputs flush earlier deltas before being persisted: message/tool
boundaries, finish/error/abort, session, capability, and content presentation.
Runner completion also drains pending deltas, including cancellation and graceful
restart suspension. The active-turn barrier remains in place through trailing
session/capability state and final cache publication. Buffered deltas are sent to
clients only after persistence succeeds. A write failure cancels and joins the
runner, reports the error, and never retries the uncertain batch.

The worker callback's acceptance into memory is not a durability acknowledgement.
An abrupt process death can discard pending, unpublished deltas. A crash during a
journal write may retain complete records from an unacknowledged batch; recovery
preserves that prefix and removes only the torn final record. This retains the
existing append-journal recovery model and format. It does not promise atomic
all-or-nothing rollback of an unacknowledged batch.

**Regression evidence:**

- Ten identical cache updates now leave the card, sync journal, high-water, and
  metadata revision unchanged. Real changes publish once; no-op calls recover an
  earlier interrupted mutation without publishing an extra one.
- 128 deltas in four store batches produce four sync transactions, preserve all
  128 sequences, and recover correctly from a cold store. Metadata is unchanged
  until a finish/usage update requires it.
- Two separate processes append concurrently without lost sequences. A process
  exiting after journal fsync but before sync publication, followed by a simulated
  complete-prefix/torn-suffix write, recovers without losing or duplicating data.
- Race tests cover buffer ownership, count/byte bounds, idle timer flushing,
  completion/failure/cancellation draining, and stopping an idle runner after a
  persistence failure. The app stream test retained 96 deltas with 19 total turn
  transactions and verified durable data before each delivered chunk. A real
  journal-path failure in a disposable store exposed no failed token to clients,
  did not replay it, and persisted the final failure after storage was restored.
- Local, authenticated direct TLS, and gateway relay CLI tests each retained all
  128 deltas, trailing session state, full wire snapshots, and unchanged watch
  resume. Each complete fixture turn used 22 sync transactions, including
  admission, semantic events, and teardown. These are functional counts, not a
  general throughput or latency benchmark.
- The live Connect watch receives a timed batch while the worker is waiting,
  resumes from that cursor without duplicate messages, and retains the remaining
  output and trailing session through completion after reconnecting.

**Affected Go verification passed:** all selected package race suites and
`go vet`, including existing queue, cancellation, restart/continuation, peer
projection, and store recovery tests. Gateway deployment units and container
integration passed again with the combined changes. The first aggregate attempt
hit an unrelated screen-relay readiness assertion under concurrent test load;
the complete CLI race suite passed on the final run. Android unit tests selected
by concurrent Android edits in the shared checkout passed too; those edits were
left untouched by this task. The repeated container probe rejected all 512
oversized envelopes and measured **11,735,040 bytes (11.2 MiB)** peak gateway
memory against its 192 MiB limit.

The selected Android functional suite finished **43/45** on the reused
`Pixel_9_API_37_1` (`emulator-5554`). `sync.navigation-recovery` exceeded its
host-side case deadline after all five native assertions passed; `widget.inbox`
failed while waiting for a Compose hierarchy after opening a conversation.
An isolated rerun of both cases passed **2/2 without code changes**. Thus every
selected case has a qualified passing result, but the aggregate command itself
exited nonzero and required those retries. Evidence is retained in
`tmp/e2e-3856187808/results.json` and `tmp/e2e-1277925777/results.json`.
The fixture app was cleaned up and the existing emulator was left running;
the operator's app and daemon were not replaced or restarted. `git diff --check`
passed. Native client protocols and the persisted journal format are unchanged.
Peer-store capacity and retention are covered in the following slice.

## Step 3b: peer-store capacity and retention

**Implemented: disk-backed retention with bounded operational reads and writes.**
The former 262,144-record/128 MiB aggregate guard also counted archived identities
and causal tombstones. Another lifetime guard blocked new operation receipts at
65,536 entries or 64 MiB. Removing history by age would lose information needed
for offline merges or allow an old uncertain mutation to run again.

The replica now retains that information in SQLite without those lifetime
admission quotas. Normal mutations load their changed records and dependencies;
peer/KV reads, snapshots, watches and synchronization use indexed point reads and
bounded pages. Domain projections use a lazy view capped at 256 cached records
and 4 MiB of encoded cache data, and SQLite's page cache is set to 4 MiB per
connection. A projection pins one read-only SQLite snapshot, so concurrent token
writes neither mix its causal baseline nor abort ordinary reads. A separate
reader pool leaves the writer available; admission is bounded to 64 active
snapshots per process, each with a one-minute deadline and explicit release.
Stale mutation baselines still fail before commit. Requested native workspace
output takes memory proportional to that output; this change bounds the peer
storage working set.

The central cross-process lock, FULL synchronization, signatures, immutable
ownership, conflict checks, atomic mutation receipts/local effects, and persisted
record format are preserved. Snapshot revisions use the replica epoch/sequence,
avoiding a full-state hash. Per-value, actor, sibling and page limits remain;
receipts have a 2 MiB individual limit. Tombstones and old actor clocks remain
available to long-offline replicas. Disk usage grows with retained data and real
disk exhaustion remains possible. This does not introduce destructive garbage
collection or claim bounded total historical disk usage.

Replication now processes at most 64 pages per direction per exchange and resumes
from durable checkpoints in later rounds. `catchup` records progress without
claiming a completed exchange. Push checkpoints bind the receiving replica epoch
as well as the local epoch; replacing a receiving replica therefore resends its
missing history. Lost acknowledgements repeat idempotent joins. First enrollment
also streams pages, retaining a durable adoption actor so an interrupted retry
cannot create new conflicting owner versions. CLI help, README, skill guidance,
and storage/KV contracts describe the resulting behavior. No RPC/schema or native
protocol changes were needed.

**Focused regression evidence:**

- A real disposable SQLite fixture retained **262,146 records / 158,335,684 bytes**
  and **65,537 receipts / 78,053,480 bytes**, crossing all four former limits.
  Cold reads, writes, deletion, stale-peer merge, exact receipt replay, status and
  two snapshot pages passed, allocating **568,584 bytes** in the final measured run.
  This measures Go allocations for those operations, not whole-process peak RSS
  or a general performance guarantee.
- Cache count/byte bounds and rejection of mixed-revision views passed. The store
  rejected a write from an invalidated writer view. A pinned domain snapshot
  retained its complete old revision across concurrent writes and cache eviction;
  nested snapshots saw the new revision, without blocking the writer. Closing
  snapshots releases their connections and admission capacity.
- A receipt insertion failure rolled back its record and accounting; retry after
  repair succeeded exactly once. A subprocess exited with an open SQLite write
  transaction; restart retained the previous record/receipt and admitted new work.
- Concurrent offline edit/delete retained both siblings; deletion remained the
  conservative presentation until explicit resolution. Old actor history then
  prevented stale versions from returning.
- An interrupted later adoption page resumed with the same actor, preserved the
  conversation owner and introduced no identity conflict.
- Bounded catch-up resumed after restarting the worker, without a premature
  success timestamp. A lost push reply and a replaced receiver both recovered
  retained tombstones without resurrection.
- Existing local/direct-TLS/WebRTC/TURN/relay peer and KV integration tests passed.
  CLI pagination and native Connect page-byte/continuation tests passed in the
  affected race run too.

The first repository check plan failed because concurrent work added a nested
`mobile` module that root-module discovery included incorrectly. That separate
task has since fixed discovery; the current `just check-changed --dry-run` passes.
The fresh aggregate run passed all 37 planner tests and 36 deployment tests, then
stopped before Docker integration assertions because Docker Hub refused the
pinned Alpine dependency download. Direct pull retries also failed initially.
After registry connectivity recovered, the isolated integration rerun passed
TLS, proxy rate isolation, all 512 oversized envelopes, UDP/TCP/TLS TURN payloads,
certificate reload, and one-allocation readiness. Gateway cgroup peak was
**11,927,552 bytes (11.4 MiB)** against its 192 MiB limit. The fixture cleaned up
its containers, network, volumes and image. No image pins or network settings
were changed.

**Go verification completed with targeted reruns.** The same reverse-dependency
selector produced `tmp/peer-capacity-checks.json`. The full store race suite,
including the real above-capacity fixture, passed in **833.820 seconds** with a
25-minute package deadline. CLI, daemon, gateway, peerstore, changeset, workspace
and the other selected package race suites passed. The first race run exposed
ordinary reads aborting during concurrent writes; pinning domain snapshots fixed
those failures, including streaming reads and card creation.

The aggregate race command still exited nonzero for five timing assertions in
app, scheduler and server. Two fixtures began their clocks before lengthy setup
writes; they now seed cards before starting title-job deadlines and set the
scheduler clock after the Done transition. All five cases passed in a sequential
race rerun (app 46.532 s, scheduler 7.431 s, server 15.101 s). The other deadline
cases needed no production or test changes. That rerun encountered a transient
vet error while another task added a helper in the shared checkout; a separate
affected `go vet` passed after the helper was present. Thus every selected test
case has a passing result, but the aggregate required these qualified reruns.

The large capacity qualification now uses `DIETER_PEER_CAPACITY=1`, matching the
existing opt-in directory-scale fixture, so routine race checks retain their
usual deadline. The documented command passed again in **19.689 seconds** without
race instrumentation and supplied the measurements above. Smaller concurrency,
recovery and retention regressions always run. `git diff --check` and Go formatting
checks passed. Concurrent module, harness and native-client edits were preserved;
no operator service was restarted.

## Step 4: Android data integrity and Node worker crashes

The exact three Android failures and Node failure are not identified by the
available assessment. Obtain their cited paths and triggers, reproduce each on
the current revision, then handle each as a separate regression fix. Existing
Quick Task draft and harness checkpoint changes are already in this checkout;
the source assessment's revision matters when determining what remains broken.

Each data-loss fix must cover restart and failed persistence, not only successful
UI operations. Use disposable Android fixtures and the Android emulator skill;
run the worker regression on macOS without replacing the live harness runtime.

## Step 5: local trust boundary

Separate two guarantees before implementation:

1. **Other host users.** Loopback TCP is reachable by other users. A private local
   transport or authenticated local access must reject them while retaining
   CLI/native-client parity and the authenticated remote routes.
2. **Processes with the owner's identity.** A token file readable by the same
   user does not isolate an unsandboxed agent from the daemon or its enrollment
   key. The current invariant explicitly runs agents unsandboxed as that user.
   Meaningful separation requires an execution sandbox or a separate OS identity
   and a deliberate policy for what agents may access. This is an architecture
   decision, not something file mode 0600 or a bearer header can solve.

First trace every local caller, credential location, and inherited process
environment. Then implement and test the chosen boundary with CLI and native
clients, including positive same-owner access and negative cross-user access.
Keep binary account access semantics; do not silently introduce scopes.

The gateway, streaming persistence and peer-store capacity slices are implemented.
Steps 4–5 remain open as described above.
