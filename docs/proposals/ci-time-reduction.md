# Proposal: CI in a third of the time

Status: proposed 2026-11-27 · scope: `.github/workflows/{ci,nightly,release}.yml`,
`.github/workflows/_build-apple.yml`, `.github/actions/setup`, `.github/filters.yml`,
`fastlane/Fastfile` and `fastlane/helpers` (iOS lanes), `apps/kotlin/gradle.properties`,
Maestro flows. Data: 96 runs from 2026-11-13 to 2026-11-27 (60 `ci.yml`, 14 nightly,
22 release; 1,198 jobs) and 126 downloaded job logs. The first test fixes from §5
(R4) ship with this proposal.

## TL;DR

A pull request that touches Kotlin waits a median of **109 minutes** (p90 163) for
CI, a main push with iOS 118–190, and a release-notes push 75–116 minutes for one
minute of work. The nightly has not passed once in 13 runs, so in practice no release
goes through the full Release-flow check. Almost all of that is one job: `ios`, a median
of **128 minutes**, of which the Kotlin/Native **Release** link takes 73.

Four changes get PR and main CI to about **38 minutes** (a third), and make the nightly
green again:

1. **Boot the simulator after the build** (a few lines in `Fastfile`, done in this
   change). Until now it idled in memory through the whole link on a 7 GB runner. Three
   runs confirm it: Gradle drops from 84 to 37–42 minutes and the iOS job from 128 to
   92–100 (§6). The flows then run on a just-booted simulator and take 38–43 minutes
   instead of 23, which a follow-up (R1b) should win back.
2. **Debug Kotlin/Native on PRs and main**, Release on the nightly and in a
   release-blocking smoke job. The Release flows exist because of a Release-only crash
   (#142), so that safeguard moves to where shipping happens instead of disappearing.
3. **One iOS build job plus 2–3 flow shards**, with the iPad flows in their own shard.
   A flaky flow then costs a 15-minute shard rerun, not a 2-hour job.
4. **Trustworthy flows** (in progress with this proposal): `Send queued message now`
   failed 11 of 11 times on Android because the flow could never pass there, and five
   iOS flows timed out on slow hosted simulators.

Quick wins in cache hygiene, planner precision and main-branch concurrency (R5, R6)
take care of most of the rest, including the 75–116-minute wait for release-notes pushes.

## 1. Baseline

"Wall" is run creation to the last job, so it includes concurrency waits and runner
queues; first attempts only.

| Scenario                             |   n |      Median |     p90 | Green                         | Critical path                                                     |
| ------------------------------------ | --: | ----------: | ------: | ----------------------------- | ----------------------------------------------------------------- |
| PR touching Kotlin/UI (iOS selected) |  14 |     **109** | **163** | 1/14 (7 failed, 6 superseded) | `ios`                                                             |
| main push with iOS                   |   3 |     118–190 |         | 2/3                           | `ios`, plus up to 109 min behind the previous main run            |
| main push without iOS (notes, docs)  |   3 | 81 (75–116) |         | 3/3                           | 1–2 min of work after the main concurrency queue                  |
| nightly (full)                       |  13 |     **166** |     172 | **0/13**                      | `ios` hits its limit before the iPad flows; Android always failed |
| release (dev)                        |  11 |          59 |      82 | 9/11                          | `apple / ios` IPA, or a macOS job waiting for a slot              |
| PR touching Go only                  |  18 |         8.9 |     9.2 |                               | `kotlin`                                                          |

Inside the `ios` job (n = 30 completed builds):

| Phase                                                                              |   Median |      p90 |
| ---------------------------------------------------------------------------------- | -------: | -------: |
| Setup (checkout, mise, gems, npm, Gradle cache)                                    |      1.5 |        3 |
| Gradle start → link starts (wrapper, configuration, K/N toolchain on a cache miss) |     11.4 |     20.8 |
| `:ui:linkReleaseFrameworkIosSimulatorArm64`                                        | **72.6** | **96.3** |
| xcodebuild (Release, simulator)                                                    |     15.5 |     19.3 |
| Install → Maestro done, smoke (11–12 flows)                                        |     22.9 |     32.5 |
| Install → Maestro done, full iPhone (18–19 flows)                                  |     42.7 |     53.9 |
| **Job total**                                                                      |  **128** |  **159** |

Other jobs: `apple` 44 (p90 59), `android` 19, `kotlin` 13–15, `go` 4, `go-e2e` 3.
Each PR run spends about 172 macOS minutes in two concurrent slots.

## 2. What the data shows

- **A booted simulator through the whole link (confirmed, §6).** `fastlane/Fastfile` (`platform :ios`
  `lane :e2e`) starts `xcrun simctl bootstatus <udid> -b` before `build_ios_simulator`,
  on purpose ("The boot overlaps the build"). The release workflow's `apple / ios` job
  runs the same kind of Release link (device slice, same runner pool, no caches at all,
  no simulator):

  |                     | CI `ios` (simulator booted) | release `apple / ios` (no simulator) |
  | ------------------- | --------------------------: | -----------------------------------: |
  | Gradle start → link |                 11.4 (n=33) |                 7.4 (n=14, no cache) |
  | K/N Release link    |   **72.6** (p90 96.3, n=30) |            **30.6** (p90 34.7, n=14) |
  | xcodebuild          |                        15.5 |                        7.6 (archive) |

  With `org.gradle.jvmargs=-Xmx5g` and the K/N compiler and LLVM in that JVM, a
  booted iOS 27 simulator on a 7 GB runner very likely pushes the machine into swap.
  That is strong circumstantial evidence; §6 tests it directly.

- **The nightly has never been green**, so it never reaches `release.yml`. All 11 dev
  releases in the window were manual dispatches.
- **Half of all PR iOS runs fail**, nearly always on one or two flows, and the only
  remedy is rerunning a two-hour job.
- **The Actions cache is over budget**: 13.2 GB against GitHub's 10 GB per repository.
  LRU eviction explains why the Kotlin/Native toolchain cache missed in 15 of 30 iOS
  runs, which costs about 10 minutes before the link each time (15.6 vs 5.8). mise is
  cached per job (12 entries, about 3.8 GB), and one open PR held 4.1 GB of PR-scoped
  caches.
- **macOS slots are the scarce resource.** At most 5 macOS jobs run at once. The 36–50
  minute queues happened while CI's two and a release's four or five macOS jobs ran.
  Any sharding has to reduce macOS minutes, not just spread them out.
- **The planner over-selects.** The `apple` filter includes `apps/kotlin/ui/**`, but the
  Mac app links only `:core:apple`. 6 of the last 13 Kotlin PRs touched only `ui` and
  still ran the 33–60 minute `apple` job.
- **Main is serialized at the workflow level** (`ci.yml` concurrency, no cancel on push),
  so a release-notes push waits for the previous push's iOS job.
- The Kotlin/Native cache barely changes the link itself (72 vs 80 minutes); the link
  output can't be reused across Kotlin changes, so caching can't fix the dominant cost.

## 3. Recommendations

Savings are on the critical path per run. "Measured" means from the data above;
"estimate" means extrapolated and confirmed in §6.

### R1. Boot the simulator after the build — measured 28–36 min off every iOS job (done in this change)

In `lane :e2e`, create the simulator as now but start `bootstatus` only after
`build_ios_simulator`. The boot (1–2.5 minutes) moves onto the critical path, and
xcodebuild gets the memory too. The README now says "boots it once the app is built".
Risk: low; `boot.wait(300)` already covers slow boots.

The link saves about 43 minutes, but the flows give back up to 20: install → Maestro
done for the 12 smoke flows took 39, 39 and 43 minutes in the three runs, against 23
for the last green 12-flow run on the same `xcode-27` image with the old order. Single
flows are about twice their medians (Task turn 5–6 minutes against 2.7). The likely
cause is a simulator that boots seconds before the flows and is still busy with
first-boot work, where before it had the whole link to settle.

### R1b. Boot the simulator between the link and xcodebuild — estimate up to 15 min more

Split `build_ios_simulator` so the boot starts when the Kotlin/Native link is done:
xcodebuild (13–15 minutes, far less memory than the link) then overlaps the boot and the
simulator's first-boot work. If the flows still run slow, add a short warm-up (launch
and quit the app once) before the first flow. Measure install → Maestro done against the
23-minute baseline; if xcodebuild slows by more than the flows gain, keep R1 as it is.

### R2. Debug Kotlin/Native on PRs and main; Release where shipping is decided — about 25–30 min more

- PR and main: `ios e2e configuration:debug` in `ci.yml`.
- Nightly: Release, full iPhone and iPad (unchanged, `full: true`).
- `release.yml`: a new `ios-release-smoke` job builds the Release simulator framework
  and runs a short smoke set (launch, Markdown code fences, Mail offline graphics,
  Task turn). `publish` needs it, so every release carries its own check against the
  Release optimizer, which today's process effectively lacks.

Release link on CI: 30.6 minutes without a simulator, 72.6 with one. Debug link of
`:ui` locally: 57–85 seconds for the task. Estimated Debug link on CI: 3–6 minutes,
with no dependence on runner memory. Risk: a Release-only miscompile shows up at
nightly or release time rather than on the PR; the release smoke still blocks publishing.
Debug code runs slower, so watch the flow times (§6).

### R3. One iOS build job and sharded flow jobs; iPad in its own shard

`ios-build` builds the framework and app and uploads `Dieter.app` as an artifact
(`compression-level: 0`). An `ios-flows` matrix then downloads it and only creates,
boots, installs and runs its slice: 2 shards for smoke; 3 iPhone plus 2 iPad for full.
Add `shard:I/N` to the flow selection in `fastlane/helpers/e2e.rb`, packing greedily by
historical duration (Appendix). Use `strategy.max-parallel` so one run never takes more
than 3 macOS slots.

Each shard boots a fresh simulator, so R1's slow-flow effect applies to every shard:
boot first, while the artifact downloads and the fixture gateway builds, and run the
warm-up from R1b if it helps. Smoke flows then drop from 23 to about 12 minutes plus 3–4
minutes of shard setup. Nightly
full iPhone drops from 43 to 15–18, and the iPad flows run at all. The biggest effect is
on reruns: a failed flow reruns one 15-minute shard instead of a 130-minute job.

### R4. Trustworthy flows (started in this change)

| Flow                                     | Platform | Failures       | Cause                                                                                                                                                                                                                                       | Fix                                                                            |
| ---------------------------------------- | -------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Send queued message now                  | Android  | 11/11          | `containsChild` matches direct children only; the queued text is a grandchild of `composer-queue`                                                                                                                                           | `containsDescendants`; the "not in the timeline" check becomes real too        |
| Send queued message now                  | iOS      | 7/12           | "send now" stops the turn through `board.cancel`, which needs the card in the account view; a conversation that just started can be running before that view lists it ("The card is no longer available", also seen in `MobileJourneyTest`) | `cancel` falls back to the conversation's known machine (core fix + unit test) |
| Providers                                | iOS      | 3 (+3 Android) | `scrollUntilVisible … centerElement` can't centre the last row once the page grew                                                                                                                                                           | scroll to the end (#240), plus a 40 s scroll timeout                           |
| Code review                              | iOS      | 2/6            | 20 s default scroll timeout on a long form, and 20 s for Changes to load the diff; both were on screen in the failure captures                                                                                                              | 60 s                                                                           |
| Mail offline graphics, chart backgrounds | iOS      | 3 + 1          | Diagrams render in a web view several times slower on hosted simulators; rendered at failure time                                                                                                                                           | 60 s render waits                                                              |
| Mail                                     | iOS      | 2              | The Undo tap can land while the snackbar slides in                                                                                                                                                                                          | `retryTapIfNoChange`                                                           |
| Conversation links and images            | iOS      | 3              | Quick Look loads out of process; instant `assertVisible`                                                                                                                                                                                    | waits up to 60 s                                                               |
| Terminals                                | iOS      | 1              | Relay-backed terminal connection > 20 s                                                                                                                                                                                                     | 60 s                                                                           |

The first PR run (with R1) then failed two more flows the same way, and this change
fixes both:

- **Mail offline graphics:** the app itself gave up ("The diagram renderer timed out.").
  Every diagram had 15 s from composition, and several web views start at once. The
  budget is now 60 s, counted from when the renderer's assets are loaded: with six
  web views starting at once, the first open needed nearly 30 s on a hosted simulator,
  and a 30 s budget still timed out once.
- **Mail:** `mail-access` on the long new-task form gets the same 60 s scroll timeout as
  Code review.

The run on top of #241 failed three flows whose outcome depended on scroll position:

- **Mail, Android:** on the 320x640 emulator the audit table opened half under the
  floating navigation bar, so the swipe from its centre landed on the bar and switched
  to Inbox. The flow now scrolls to the heading below the table first.
- **Mail offline graphics, iOS:** after reopening the report, the scroll for the
  _rendered_ Mermaid tag went past a diagram that was still rendering and never came
  back. `common/mermaid-rendered.yaml` stops at the diagram and waits there, longer
  than the app's render budget.
- **Agent memory, iOS:** hierarchy reads of 9.5 and 15 s exhausted the 20 s scroll to
  "Start a dream now" while the button was on screen; long-form scrolls get 60 s.

Still open: Go `TempDir RemoveAll cleanup: … dieter-home/sync: directory not empty`
(gateway e2e and some `internal/api` tests). `api.Server` has no close or drain, and
`topology.Daemon.Close` stops the listeners without waiting for the server's background
work (turn completion, change-counter writes in `sync/`), so a straggling write can race
the test's temp-directory removal. The fix is a `Server.Close` that waits for that work,
called from `topology.Daemon.Close` and the API test helpers. A retrying cleanup would
hide it, and cleanup failures must fail the gate.

None of these weakens an assertion: each waits longer for the same condition, or fixes
a selector that could never match. Later, a "retry a failed flow once and report it as
flaky" mode would cut reruns further. It has to stay visible in the summary under the
evidence rules in `AGENTS.md`, so that's a decision for the owner.

### R5. Cache hygiene: stay under 10 GB — about 5 min average, plus 2–4 on main

- `.github/actions/setup/action.yml`: key mise by OS and tool list instead of
  `github.job`, and save only on main (`cache_save`).
- Gems and `~/.npm`: `actions/cache/restore` on PRs, save on main only.
- `ci.yml`: split `apple-v2` into a Kotlin/Native cache keyed by the Kotlin version only
  (not all of `libs.versions.toml`) shared by `apple` and `ios`, plus per-job SwiftPM
  caches; skip the save on an exact hit (it takes 1–4 minutes on every main run).

### R6. Planner precision and main concurrency

- `.github/filters.yml`: drop `apps/kotlin/ui/**` from `apple`; UI-only PRs skip the
  33–60 minute job and free a macOS slot. (Unrelated coverage gap: `android` lacks
  `api/proto/**`, though `:core:model` generates Wire code from it.)
- Run "Swift generated code" (2–3 minutes in every `apple` run) only when `api/**` or
  the Swift plugin pins change.
- `ci.yml`: give pushes a per-commit workflow group and serialize only the macOS jobs on
  main (`concurrency` on the job). Release-notes and Go-only pushes then finish in 2–9
  minutes instead of 75–116.

### R7. Keep `apple` below the new iOS path

After R1–R3 the iOS path is about 38 minutes, and `apple` (44, p90 59) becomes the
critical path for core changes. R5 and R6 take 5–8 minutes off it. If that isn't
enough, move the Mac flows (9–20 minutes, including a second Swift build of the same
sources through xcodebuild) into their own job, at the cost of one more macOS slot.

### R8. Release workflow — median 59 → about 48, p90 82 → about 55

- Gradle and Kotlin/Native caches in the `release` cache scope, never restored from CI,
  as the threat model requires: pre-link 7.4 → about 3 minutes.
- `apple / daemon` waited 40–50 minutes for a macOS slot in 4 of 11 runs. Sign it inside
  `apple / mac` (same environment) and keep `harness-runtime` as a separate secret-free
  job; and don't dispatch a release while main CI holds two macOS slots.
- `ios-release-smoke` from R2 runs in parallel and adds no critical-path time.

### R9. Small items

- `org.gradle.parallel=true`: `kotlin` runs `:ui:jvmTest` and `:core:e2e:test` one after
  the other. That saves 2–3 minutes, and Go-only PRs drop to about 6–7.
- Configuration cache: 0.5–1 minute per invocation, once the custom `Exec`/`Sync` tasks
  in `ui/build.gradle.kts` are checked.
- Not worth it: a remote Gradle build cache (core outputs already come from main's cache,
  and the link isn't reusable) and Android emulator snapshots (boot is 32 s).

### R10. Optional, paid: a larger macOS runner for Release links

More cores and twice the memory would cut the Release link further and remove the memory
sensitivity. Larger runners are billed even for public repositories. Use one only for the
Release-link jobs (nightly, `release.yml`), and only after R1 is measured.

### Considered and rejected for now

- **Reusing a Release framework keyed by the Kotlin input hash:** nearly every
  iOS-selecting PR touches Kotlin; PR caches can't be read by main; and handing main a
  framework built by PR code is a trust problem. It could help follow-up pushes that
  change only Swift or flows later.
- **Maestro `--shard-split` across simulators on one runner:** memory is already the
  bottleneck.
- **Merging `kotlin`+`android` or `apple`+`ios`:** little shared output, and a longer
  critical path.

## 4. Projected wall time (minutes)

| Scenario              |            Today |            Phase 1 |       Phase 2 |
| --------------------- | ---------------: | -----------------: | ------------: |
| PR touching Kotlin/UI |    109 (p90 163) |      ~75 (R1: 101) |    **~38–45** |
| main push with iOS    |          118–190 |                ~75 |    **~38–45** |
| main push without iOS |               81 |                 ~5 |            ~5 |
| nightly               | 166, never green | ~140, can be green |           ~75 |
| release               |      59 (p90 82) |                 59 | ~48 (p90 ~55) |

Phase 1 assumes R1b wins back most of the slow flows. The green PR run with R1 and R4
alone took 101 minutes from creation to the last job, all of it in `ios`. Reaching a
third on PRs and main needs R2, and flows at warm-simulator speed in the shards (R1b);
at today's post-R1 flow speed it is about 45. With Release builds kept on PRs, the floor
is about 60 minutes unless larger runners are bought.

## 5. Phases

- **Phase 0 — confirm the two big assumptions (half a day).**
  1. An `ios_only` run with the boot after the build: done, R1 confirmed (§6). Next,
     R1b against the 23-minute flow baseline, with a swap sampler (`sysctl
vm.swapusage`, `vm_stat`) so link and flow slowdowns can be told apart.
  2. The same with `configuration:debug`: Debug link, Debug xcodebuild and per-flow
     times against the Appendix.
- **Phase 1 — quick wins (1–3 days): R1, R1b, R4, R5, R6, R9.** The PR path goes from
  109 to about 75; the nightly can turn green; release-notes pushes stop queueing.
- **Phase 2 — structural (3–5 days): R2, R3, R7, R8.** PR and main reach about 38–45;
  the nightly about 75; a flaky flow costs one shard rerun.
- **Phase 3 — optional:** R10, the framework reuse for non-Kotlin follow-ups, and a
  visible flaky-retry mode.

What to measure continuously: wall time per scenario (median and p90), queue time per
job, time per `ios` phase (link, xcodebuild, flows), cache hits per job and total cache
size, failures per flow and platform, the nightly's green rate, and macOS jobs running
when a job is enqueued.

## 6. Phase 0 experiment: result

| Run                                                                      | Branch                               | Change                          | Result                                                                             |
| ------------------------------------------------------------------------ | ------------------------------------ | ------------------------------- | ---------------------------------------------------------------------------------- |
| [46052306413](https://github.com/dbpprt/dieter/actions/runs/46052306413) | `ci-experiment/sim-boot-after-build` | simulator boots after the build | measured below                                                                     |
| [46052310568](https://github.com/dbpprt/dieter/actions/runs/46052310568) | `main`                               | control                         | cancelled to free macOS slots for a release; the historical medians above stand in |

|                                                                | Historical median (simulator booted during the build) | Experiment (boot after the build) |
| -------------------------------------------------------------- | ----------------------------------------------------: | --------------------------------: |
| Gradle: pre-link + `:ui:linkReleaseFrameworkIosSimulatorArm64` |                                      11.4 + 72.6 = 84 |            **37** (link about 35) |
| xcodebuild + boot + install                                    |                                           15.5 + boot |                          about 16 |
| `ios` job total (smoke flows)                                  |                                                   128 |                            **92** |

R1 is confirmed. The Release link runs as fast as in the release workflow (31 there,
about 35 here), and the job is 36 minutes shorter. The run failed two flows, Mail
offline graphics (a render wait) and Code review (the Changes diff wait). The branch is
`main` plus the boot change only; this change fixes both flows.

The two PR runs of this change repeat it. The second is the first green iOS run in the
measured window with 12 smoke flows and the new order:

| Run (`ios` job)                                                          | Gradle (pre-link + link) |     xcodebuild + boot | Install → Maestro done (12 flows) | Job | Flows            |
| ------------------------------------------------------------------------ | -----------------------: | --------------------: | --------------------------------: | --: | ---------------- |
| [45997500430](https://github.com/dbpprt/dieter/actions/runs/45997500430) |                     79.6 | 9.4 (boot overlapped) |                          **23.0** | 117 | 12/12, old order |
| [46052306413](https://github.com/dbpprt/dieter/actions/runs/46052306413) |                     37.0 |                    11 |                              39.1 |  92 | 10/12            |
| [46065666666](https://github.com/dbpprt/dieter/actions/runs/46065666666) |                     40.7 |                    15 |                              38.5 |  97 | 10/12            |
| [46078186264](https://github.com/dbpprt/dieter/actions/runs/46078186264) |                     41.6 |                    13 |                              43.1 | 101 | **12/12**        |

All four ran on the `xcode-27` image. Gradle keeps the R1 saving; the flows take 16–20
minutes longer than in the old order, which R1b addresses.

## Appendix: per-flow Maestro times on CI (median seconds, failures)

| Flow                          | Smoke | iOS n | iOS median | iOS failed | Android n | Android median | Android failed |
| ----------------------------- | ----- | ----: | ---------: | ---------: | --------: | -------------: | -------------: |
| Mail chart backgrounds        |       |    12 |        289 |          1 |        12 |            114 |              1 |
| Mail offline graphics         | yes   |    26 |        202 |          3 |        27 |             74 |              0 |
| Code review                   | yes   |     6 |        193 |          2 |         8 |             93 |              0 |
| Send queued message now       |       |    12 |        187 |          7 |        11 |             68 |             11 |
| Mail fast scrolling           |       |    12 |        162 |          0 |        11 |             48 |              0 |
| Task turn                     | yes   |    26 |        161 |          0 |        27 |             74 |              0 |
| Mail                          | yes   |    26 |        136 |          2 |        27 |             55 |              0 |
| Conversation changes          | yes   |    25 |        132 |          1 |        27 |             59 |              1 |
| Providers                     | yes   |    25 |        125 |          3 |        26 |             61 |              3 |
| Tools                         |       |    12 |        109 |          1 |        11 |             40 |              1 |
| Folders                       | yes   |    25 |        102 |          0 |        26 |             59 |              1 |
| Terminals                     |       |    12 |         96 |          1 |        11 |             49 |              1 |
| Agent and model pickers       |       |    12 |         94 |          0 |        11 |             47 |              0 |
| Board and conversation        | yes   |    26 |         91 |          0 |        28 |             23 |              1 |
| Channels                      |       |    12 |         89 |          0 |        11 |             38 |              0 |
| Inbox                         | yes   |    26 |         75 |          0 |        27 |             22 |              0 |
| Conversation links and images | yes   |    26 |         68 |          3 |        27 |             23 |              1 |
| Devices                       | yes   |    26 |         48 |          0 |        27 |             21 |              0 |
| Markdown code fences          | yes   |    26 |         47 |          0 |        27 |             12 |              0 |

The iOS smoke set sums to 23.0 minutes and all flows to 40.2. The same flows run 2–4
times longer on the hosted iOS simulator than on the Linux Android emulator.
