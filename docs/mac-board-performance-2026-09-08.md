**100-card board opening — diagnosis and fix, 8 September 2026**

The dominant measured cost was constructing and laying out offscreen card views on the main thread. Board selection also made a redundant full-project request even when the live synchronization stream already supplied that project. The previous rendering test accepted up to five seconds of layout work, which guarded against hangs but could not establish that opening a board felt responsive.

The investigation started from source revision `cf5857d1`. The installed Homebrew cask is still **0.4.101**. The changed, tested debug app is at `apps/mac/build/Dieter.app`; this is not a published Homebrew update.

**Follow-up:** [native click and app-wide navigation audit](/Users/dbpprt/Development/dieter/docs/mac-navigation-responsiveness-2026-09-08.md) measured **113–120 ms** from clicking the optimized 100-card board to a destination drawing callback. The numbers below isolate layout stages; they do not establish immediate button feedback.

**Where the time went**

The same diagnostic constructs realistic variable-height cards with summaries, labels, workspace badges, comments, and subagent indicators. It times data projection, creation of the hosting view, synchronous layout, and bitmap drawing separately. Each workload uses three new hosted views after the SwiftUI framework has warmed up. These are debug medians on this Mac, not cold application-launch times, compositor frame times, or release p95 values.

| Workload | Before: layout + draw | After: layout + draw | Heavy card views after |
|---|---:|---:|---:|
| 10 cards in one lane | 23.73 ms | 22.92 ms | 6 |
| 100 cards in one lane | 61.95 ms | 30.09 ms | 6 |
| 100 cards across four lanes | 136.55 ms | 64.42 ms | 24 |

For the four-lane board, the original layout alone took **118.67 ms**, and drawing took **17.88 ms**. The replacement takes **55.93 ms** and **8.49 ms**, respectively. Preparing the 100-card model took **0.8–0.9 ms** in both versions. This isolates the main cost to UI construction and layout, rather than sorting or filtering 100 card records.

The old eager stack mounted up to **40 cards per lane**. A board with 25 cards in each of four lanes therefore created all 100 rich card graphs immediately. Each included buttons, drag/drop targets, hover state, menus, sheets, badges, and text layout, even far below the viewport. A single crowded lane only mounted its first 40, at the cost of pagination.

Separately, three read-only CLI requests for the real Dieter project's **87 cards** took **114–121 ms**, including CLI startup, transport, and output encoding. This is not a direct GetState RPC measurement. Code inspection established that both board navigation paths unconditionally called `refreshState()`, which requests all cards and chats for the project. That request is now skipped when the selected machine has a live synchronized projection of the project. Cold or unsynchronized projects still refresh.

**Changes**

- `BoardLaneList` uses an AppKit table to recycle rows outside the viewport. Visible cells retain the existing SwiftUI card controls and appearance. All cards remain reachable by normal scrolling; board pagination is removed. The Chats pagination policy is unchanged.
- Row heights use cached measurements of the card's bounded text and visible sections. This avoids constructing hidden SwiftUI graphs just to measure them. Native hosting views have automatic intrinsic sizing disabled because the table supplies their frames. Width changes invalidate the height cache.
- Updates with unchanged ordering reload only the changed rows. Sorting or selecting another board resets the lane to its beginning. Card identity resets reused SwiftUI state. Drop ordering reads the current projection when the drop occurs rather than retaining an old array in a recycled row.
- Both `openBoard` and `selectBoard` reuse live synchronized project state. Tests use a closed RPC client to prove these paths do not accidentally issue another GetState request. The guard rejects another machine's projection, an active synchronization, and missing snapshots.
- The native board fixture now contains **100 cards**, including **85 in Todo**. A deterministic regression checks that 100 rows are represented while fewer than 15 card views are mounted in a single lane, then scrolls to the final row. This catches eager rendering regressions independently of machine speed.

The AppKit sizing behavior used by this implementation is documented in Apple's [automatic row height property](https://developer.apple.com/documentation/appkit/nstableview/usesautomaticrowheights) and [row height property](https://developer.apple.com/documentation/appkit/nstableview/rowheight).

**Native results and verification**

The final packaged 100-card fixture mounted **20 card rows** across its four visible lanes. Selecting the live board took **0.1 / 0.2 / 0.2 ms**. A subsequent forced synchronous layout/display took **81.8 / 94.9 / 71.8 ms**. These samples include the real workspace chrome and use a different lane distribution from the hosted benchmark, so they should not be substituted into its comparison table. They also show that opening the board is not yet an 8–16 ms frame-budget operation in debug.

Native checks passed for sorting (with screenshot inspection), scrolling beyond the former 40-card limit to the last of 85 Todo cards, clicking that recycled card to open the correct conversation, and returning to the beginning. Core native checks also passed, including light/dark appearance, board/conversation navigation, offline cached navigation, reconnect, Files, Schedules, and creation flows. Relevant screenshots were inspected.

- **229 Mac tests passed.** A pre-existing schedule fixture race surfaced during verification: asynchronous persisted-state restoration could replace its fake RPC's selected project. The two schedule fixtures now explicitly disable restoration; production schedule behavior was not changed.
- **`just check` passed**, including Go race tests, vet, builds, protocol checks, and all 43 harness tests. Four incidental generated protoc-version comments were restored after inspection. The expanded Go fixture was formatted with `gofmt`.
- Canonical `dieter-local` and `dieter-tests` caches were reused. No caches were deleted. The packaged app's signature was verified by the build recipe.
- Final inventory: **zero DieterMac processes**. The operator daemon is PID **79045**, started at **13:36:12** before this investigation. This task did not restart, replace, upgrade, or stop it. Native mutations were confined to disposable fixtures.

The tested executable SHA-256 is `f1f79fa4517ad7187aefa1295f67fd30146f57269493d6134c7da96ec472abf5`.

Evidence: [baseline timings](/tmp/dieter-board-baseline.log), [final timings](/tmp/dieter-board-final-profile.log), [Mac tests](/tmp/dieter-board-final-tests-isolated.log), [repository checks](/tmp/dieter-board-repository-check.log), [100-card native report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/board-20260908-175457-67f56885-6e9f-43df-9f08-62b86534d9bb/report.json), [scrolled last card](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/board-20260908-175457-67f56885-6e9f-43df-9f08-62b86534d9bb/02-board-scrolled-to-last.png), [core report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/core-20260908-175522-2e1d2870-dfe5-4aa0-8e34-34212c64410e/report.json).

Reproduce the optional stage diagnostic with `DIETER_BOARD_PROFILE=1 just mac test boardOpeningStageDiagnostic`. The ordinary suite keeps the deterministic virtualization and navigation checks enabled.
