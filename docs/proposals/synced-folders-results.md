# Synced folders: measurement results

Measurements for [the synced folders proposal](synced-folders.md) §4.3, taken
2026-11-13 on a Mac mini (Apple Silicon, macOS, APFS) while implementing the
feature. The harness is `tools/spikes/folders` (`walk` and `relay`).

## M1: stat walk on macOS

`go run ./tools/spikes/folders walk -entries 100000` builds 1,000 directories
with 99 files each and walks them with `filetransfer.Scan` three times.

| Volume                 | Wall time per walk | CPU per walk | Share of a core at a 60 s interval |
| ---------------------- | ------------------ | ------------ | ---------------------------------- |
| Internal SSD (APFS)    | 190–199 ms         | 207–216 ms   | 0.35%                              |
| External volume (APFS) | 190–198 ms         | 207–215 ms   | 0.35%                              |

**Accepted** (threshold: walk ≤ 2 s and ≤ 5% CPU). macOS members are walked
every 60 s; the FSEvents helper stays a follow-up. A Linux box was not
measured: Linux members watch with inotify and walk at the rescan interval, so
the walk cost matters only when the watch limit is reached.

Deviation from decision 7: kqueue on directories was not built. fsnotify's
kqueue backend opens a descriptor for every file of a watched directory, and
the 60 s walk alone is cheap enough, so macOS members rely on the walk.

## M2: bulk transfers vs. interactive latency

`go run ./tools/spikes/folders relay` runs an isolated gateway, one daemon and
one paired client in one process, all on loopback. A 64 MiB file sits in a
synced folder; N goroutines download it in 1 MiB `ReadFileChunk` calls through
the relay tunnel (command lane) while the client measures `GetFolderStatus`.

| Chunk streams | Interactive p50 | Interactive p95 | Chunk throughput |
| ------------- | --------------- | --------------- | ---------------- |
| 0             | 0.36–0.38 ms    | 0.93–1.03 ms    | –                |
| 1             | 0.50 ms         | 1.49 ms         | 917 MiB/s        |
| 2             | 1.42–1.69 ms    | 2.09–2.55 ms    | 949–1,279 MiB/s  |
| 4             | 3.54 ms         | 4.55 ms         | 1,007 MiB/s      |

**Not accepted by the stated threshold** (p95 rises ≤ 20%). One stream raises
p95 by about 45%, two by about 100%. In absolute terms the rise is below
1 ms for one or two streams, and the run is CPU-bound in a single process
rather than limited by a network.

**Fallback applied** (as planned):

- Phones transfer one file at a time (the Kotlin core's transfer runner).
- Daemons reach each other through `peersync.DialPeer` on the replication
  lane with one cached connection per peer, so folder pulls between daemons
  never share the command lane with interactive calls.
- A `bulk` relay lane remains a follow-up. Measure on a real WAN path before
  raising phone concurrency.

## M3: Android shared storage (SAF)

**Not measured in this change.** It needs the warm emulator or a Pixel with a
profile that names its serial, and a document provider holding 10,000 files.
The phone entry bound stays 25,000. If a measurement shows that a scan of
10,000 nested files exceeds 10 s, lower the bound to 10,000 with the
_Too many files for this phone_ status, as the plan's fallback says.

## M4: iOS keychain and device key while locked

From code inspection
(`apps/apple/DieterKit/Sources/DieterPlatform/CoreKeychainSecureStore.swift`,
`CoreDeviceKeys.swift`):

- Session items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: usable
  after the first unlock, also while the phone is locked.
- The device key is a Secure Enclave key created with CryptoKit's default
  access control (`WhenUnlockedThisDeviceOnly` with private key usage). Signing
  with it, which every mutual TLS handshake needs, fails while the phone is
  locked.

**Fallback applied:** background runs reach the machines only while the iPhone
is unlocked; a locked run fails its connection and the next scheduled run
tries again. The Folder sync settings caption and the user guide say so.
Keychain and key attributes are unchanged: that touches authentication and
needs its own threat-model review. A manual three-day background soak on a
real iPhone is still required before merge (there is no physical-iPhone E2E).

## Correctness findings from the end-to-end tests

The two-daemon tests (`internal/testkit/topology/folders_e2e_test.go`, run 10
times under the race detector) found four defects, all fixed before the tests
went green:

1. **Trash links changed the file being replaced.** Preserving the old version
   with a hard link updates the inode's ctime, which made every replacement's
   compare-and-swap fail. `filetransfer.Preserve` now returns the revision
   after linking.
2. **A local edit right after a download could be lost.** The revision was
   read after publishing, so an edit in that window was recorded with the
   downloaded content's hash. `filetransfer.PublishWith` now returns the
   revision observed before the rename; a stale revision only costs a re-hash.
3. **A slow mass deletion leaked its first files past the guard.** A scan
   during `rm -rf` saw only some deletions, below the threshold. Deletions
   now settle for 3 s, and the guard judges every missing path at once.
4. **Restoring held deletions could fail for good.** A serving daemon refused
   reads while its recorded revision was stale (ctime changed by a rename), and
   the restore ran once. Reads now refresh a stale revision when the content
   still matches, and restores retry each cycle.
