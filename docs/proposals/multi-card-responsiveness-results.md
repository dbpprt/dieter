# Multi card responsiveness results

Implementation of [the responsiveness plan](multi-card-responsiveness.md),
qualified on the mini-home M4 on 25 October 2026 using temporary stores,
repositories, authenticated loopback routes and a fixture gateway. The operator's
running daemon and launchd job were left unchanged.

## Changes

- The turn engine publishes its initial runtime and subsequent transitions,
  rather than repeating a conditional card-cache transaction after every chunk
  batch. Cancellation, finishing, suspension and recovery retain their existing
  ordering. A regression test asserts one writer admission per unchanged append.
- Replica snapshots share a bounded cache of immutable point reads, including
  absent fields. Every snapshot still establishes its real MVCC account, epoch
  and sequence before using cached data. Returned clocks, provenance and values
  are copied. Writer views remain independent. The shared cache holds at most
  256 records / 4 MiB for one revision; it cannot mix accounts or revisions.
- Writer diagnostics include failed admissions and expose an optional observer
  that runs after releasing the writer. Existing central locking, atomic writes,
  journal fsync and checkpoint behavior remain intact.
- Quota replies are validated before consuming pending requests. A bounded
  one-minute / 128-entry correlation window recognizes valid late or duplicate
  replies without applying them again or disconnecting the control lane.
  Unsolicited, malformed and unauthorized replies remain errors.
- The Homebrew formula now uses Standard scheduling. Its rendering test checks
  the policy, and the machine guide and CLI skill explain explicit activation
  and the resource use of background executions after an agent turn ends.

The replica cache extends reuse across operations because a warm card projection
otherwise repeats the same dependency queries on an unchanged revision. The
regression fixture measures six dependency queries cold and one warm; the
remaining range query reads label memberships. Cross-process writes, pinned old
snapshots, caller mutation and boundedness have dedicated tests.

## Concurrent writer measurements

The opt-in `TestConcurrentTurnWriterCost` seeds 100 cards and runs 20 bursts of
32 token deltas per turn, with heartbeats between bursts. Heartbeats do not flush;
the batch size and timer bounds determine durable appends. Setup and admission are outside
the measured streaming window. Every accepted token and final response receipt
is checked. These are finite, backpressured bursts, not a ten-minute offered-load
qualification.

The baseline is current main before these optimizations; it is not a rebuild of
the incident's installed 0.6.410 binary. Baseline and initial candidate runs used
the existing background scheduling environment. Other host activity was not
controlled, so timing differences are observations rather than portable speed
guarantees.

| Concurrent turns | Tokens retained | Baseline writer admissions | Candidate writer admissions | Baseline stream time | Candidate stream time |
| ---------------- | --------------- | -------------------------- | --------------------------- | -------------------- | --------------------- |
| 1                | 640             | 51                         | 31                          | 1.87 s               | 1.46 s                |
| 8                | 5,120           | 404                        | 228                         | 11.54 s              | 8.61 s                |
| 16               | 10,240          | 772                        | 432                         | 21.62 s              | 16.75 s               |

At 16 turns the candidate acquired the writer approximately **44% fewer times**.
A separate candidate run in a disposable Standard launchd job, without another
test suite alongside it, retained all 10,240 tokens in **11.89 seconds**, with
432 admissions, **623 ms p99 writer wait** and **52 ms p99 hold time**. No writer
admission failed. The proposed 500 ms p99 wait target was not met by this burst.

## End to end route qualification

`TestConcurrentTurnsStayResponsiveAcrossRoutes` ran in a disposable Standard
launchd job. It used real API admission and watches with a 100-card directory,
concurrent renaming, peer replication to a second enrolled daemon, cold transcript
replay, response receipts and turn/lease cleanup.

| Route                         | Concurrent turns | Tokens retained | Streaming and verification time | Completed probes | Maximum health plus card read latency |
| ----------------------------- | ---------------- | --------------- | ------------------------------- | ---------------- | ------------------------------------- |
| Local loopback                | 8                | 5,120           | 6.38 s                          | 63               | 18.7 ms                               |
| Direct mutual TLS             | 8                | 5,120           | 6.37 s                          | 63               | 22.4 ms                               |
| Gateway relay with mutual TLS | 16               | 10,240          | 12.77 s                         | 127              | 40.9 ms                               |

The test completed successfully in 55 seconds including setup and admission.
No control-lane disconnect occurred during these streams. Probe times cover a
health request followed by a card-detail request, rather than UI presentation.

The separate `TestLateProviderQuotaReplyKeepsControlLaneAlive` let a real quota
request expire, released its delayed reply and required five further control
acknowledgements plus a successful relayed health call. It passed. The existing
blackholed-tunnel test also passed, observing acknowledgement timeout, handshake
timeout and reconnection after the proxy resumed.

## Scheduling comparison

Six disposable launchd jobs alternated Background and Standard scheduling, each
spawning a child that performed the same arithmetic workload for three seconds.
Parent and child priorities changed together: Background was priority 4 and
Standard was priority 20 in the representative samples. Median throughput was
87 versus 1,534 loop blocks per second on this busy host. This establishes a
scheduling effect and inheritance; it is not a daemon throughput multiplier or
a long-duration thermal measurement. Every fixture job was removed afterward.

## Validation and limits

Focused race tests passed for writer diagnostics, shared-cache bounds and
invalidation, pinned snapshots, quota correlation, late replies and provider
cooldowns. Repository lint, formatting, identity drift and the Homebrew rendering
assertions passed. Documentation checks passed, and the pipeline suite passed
25 tests / 245 assertions with no skips. The selected full integration gate
remains incomplete: a CLI
test hit the 2 GiB disk-admission guard at 2,030 MiB free, and the shared Go build
cache lost files during compilation. An isolated-cache retry passed lint but
was stopped as free space fell toward the admission floor. Failed output is
retained in the card's registered processes. Only this task's stopped build
cache was removed to return its disk space; test evidence was retained.

Initial route-fixture failures exposed missing admission IDs and peer-account
initialization; those fixture defects were corrected. An initial broad suite run
alongside performance measurements suffered storage admission and request
timeouts. Its failed output was retained; the retry used Standard scheduling,
one Go package at a time and two Go execution threads. The API package then
passed. Timing qualification ran separately from that suite. Tests keep their
original correctness assertions. Final broad validation is delegated to GitHub
Actions at the operator's request; no further local suites will run. The
harness-runtime attempt
timed out in its two bootstrap-cache tests at their existing 30-second deadlines
and its bundled Codex streaming test failed with `kill EPERM` in
`local-sandbox.mjs`. The run was stopped as free space dropped further. No
harness-runtime sources were changed by this implementation; those files contain
concurrent work. These failures remain unresolved by this change.

The first Actions run passed the concurrent-turn route test, CLI E2E, quota
timeout test, formatting, pipeline and site checks. The new writer-count test
failed because it incorrectly used a heartbeat as a flush barrier. The fixture
now uses text-end, checking both its append and the preceding delta append
without assuming a timer schedule. Follow-up validation runs in Actions.

The host had approximately 4–7 GiB free during the performance runs, below the
plan's 20 GiB reference condition. During broader verification it fell below the
2 GiB admission floor and later reached approximately 400 MiB free. The operator
subsequently reported disk space available. Ten-minute 8/16-turn offered-load runs, long
tool-heavy histories and long-duration foreground/thermal impact remain
unqualified. The measured 623 ms p99 burst writer wait also remains above the
proposed 500 ms target. The end-to-end correctness and responsiveness results
above do not imply those remaining performance targets passed.

Activation of the new service policy remains an operator step after the updated
formula is available. Shipping or staging a binary alone does not refresh the
running launchd definition. No release was published or production service
restarted during this work.
