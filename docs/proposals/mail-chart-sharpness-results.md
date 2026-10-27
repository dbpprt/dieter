# Sharp Mac chart previews and bounded parallel rendering

Follow-up to [Mail chart transparency](mail-transparency-results.md), tested on
27 October 2026 on the same Apple Silicon host. The supplied screenshot showed
soft chart labels and paths in a larger report.

## Cause and change

Mac Mail and the native Files editor rasterized each shared SVG using WebKit
snapshots. When the 24 MiB image cache filled, every completed chart was
repeatedly downsampled. A report could therefore become blurry as later charts
finished. One WebKit page also serialized the entire queue.

The Mac adapter now captures vector PDF drawing commands from the same offline
renderer and gives AppKit an `NSPDFImageRep` with bitmap caching disabled.
Text and paths draw at the destination display's backing scale. The cache is
charged for PDF data and source bytes, without reducing resolution. An output
that cannot fit falls back to source (or the Files source-opening placeholder);
that decision is retained to prevent retry loops. The 24 MiB and 48-diagram
limits remain in place.

Two independent, reusable WebKit pages overlap render work. Each page owns its
DOM and Mermaid configuration. Closing, hiding, changing theme or removing a
block cancels the affected workers; late results cannot enter the current
cache. Resuming retains completed previews and requeues interrupted work.
Mobile already displays SVG directly; this change does not add a mobile bitmap
pipeline or change the shared offline renderer, source validation or exports.

## Measurements

The same synthetic report has 24 unique 900px-wide line charts, each with 256
inline observations, axes and a title. The timer covers queue admission through
completion notification; compilation is excluded. These are local samples,
not a cross-device speed guarantee.

| Renderer                       | Report time | Cached output and source |
| ------------------------------ | ----------: | -----------------------: |
| Original serial bitmap adapter |     1.188 s |         25,117,281 bytes |
| Vector adapter, one worker     |     0.581 s |            500,900 bytes |
| Vector adapter, two workers    |     0.591 s |            500,900 bytes |

This workload renders about twice as fast and retains about 50 times fewer
cache bytes. Most of that improvement comes from eliminating snapshots and
repeated downsampling. Two workers did not improve this small report's elapsed
time in the initial sample; the deterministic concurrency test separately
proves two blocks start before either finishes and that the queue never
exceeds the configured pool size. Timing is reported, not asserted as a flaky
performance threshold.

The final full-suite run also exercised 24 charts with 4,096 observations each
(98,304 observations total). One vector worker took 1.393 s; two took 1.195 s,
about 14% less time, with 2,660,657 cached bytes in either case. Its smaller
256-observation case took 0.520 s and 0.430 s respectively. These samples show
why bounded overlap helps heavier work while small-report results vary with
startup and notification timing.

The old cached chart had only 797 by 327 pixels for a 900px-wide display slot.
The new report test requires every chart to retain a single PDF representation
and extractable title text, including after cache requests. Separate tests keep
24 vectors intact under a 512 KiB budget and exercise source fallback instead
of blur when output cannot fit.

## Verification

`just check-changed` passed, including Kotlin tests/core E2E, DieterKit (17),
native helpers (10), Mac (511), the iOS simulator build, Android lint/unit and
documentation checks. The Mac suite includes vector text, alpha/explicit-white,
static HTML/PDF export, cache bounds, two-worker overlap, width/theme staleness,
source removal, hide/resume and disposal regressions. Hardware-only privacy
checks remain opt-in and are unrelated to this change.

The final isolated Mac E2E run passed backgrounds/selection (17.1 s), rich
Markdown/fallback/navigation (8.1 s), and the supplied 15-chart report (14.6 s).
The report flow asserts 15 rendered charts and zero source fallbacks in both
light and dark themes. Actual compositor screenshots were opened and inspected;
the supplied report's labels/paths are visibly sharper, transparent margins
match the reader and authored white surfaces remain white. Scrolling, switching
messages and reopening retain the correct chart content. No task-owned
`DieterMac` or `DieterE2E` process remained after cleanup.

[Native vector chart capture](assets/mail-charts-vector-mac.png) shows only the
synthetic chart fixture. The supplied report, its source and its comparison
captures remain local and are not committed.

Evidence paths relative to the worktree:

- `tmp/pipeline/20261027T142517-swift-tests-8ca347/`: full Apple logs and test
  counts, including both report sizes and worker settings.
- `tmp/pipeline/20261027T142822-ios-build-6b7375/`: iOS simulator build.
- `tmp/pipeline/20261027T142916-mac-e2e-ae39e1/`: results and cleanup evidence;
  `mail-revised-local/upday-{light,dark}-{header,1,2,3,4,5}.png`,
  `mail-backgrounds/` and `mail-rich/` contain the opened native captures.
- `tmp/mail-sharpness/`: original cached bitmap, new vector PDF samples, and a
  before/after crop of the supplied report (`comparison.png`).

This adapter-only follow-up uses the existing three-platform transparency
qualification in [the earlier report](mail-transparency-results.md); no mobile
runtime code or shared JavaScript changed here. No physical device was newly
qualified. Native verification used the isolated E2E app and fixture, without
operator preferences, production Mail or an operator app/daemon replacement.

Reproduce the focused regression and native journey:

```sh
mise exec -- just check-changed --dry-run
mise exec -- swift test --package-path apps/apple/mac --no-parallel --filter nativeDiagram
mise exec -- just e2e mac flows:mail-backgrounds,mail-rich screenshots:compositor
```

The supplied-report flow uses the existing local `DIETER_TEST_MAIL_REPORT`
fixture hook, described in the earlier report. Final formatting, staged lint and
documentation checks passed.

## Further performance work

The next profile tested two versus four workers. Four improved the heavy
24-chart report only from 1.191 s to 1.131 s, at the cost of twice as many
WebKit pages. The default stays at two.

Further improvements target work the reader need not repeat:

- Completed chart vectors survive message switches in a bounded cache owned by
  that Mail model. Source bytes, normalized diagram kind, width and theme form
  the key. Up to 48 entries / 24 MiB are retained in memory with least-recently
  used eviction. Failures, placeholders and WebKit pages never enter this cache.
  Detaching the model clears it and invalidates pending insertions. Models and
  message windows do not share the cache.
- Completed queues notify the native reader on the next main-actor turn instead
  of waiting for the remaining 100 ms coalescing timer. Intermediate updates
  still coalesce, and hiding/disposal cancels pending notifications.
- Source identities retain references to source strings instead of constructing
  a combined language/source string on every lookup. Source membership borrows
  contiguous UTF-8 buffers for literal search, with a literal Foundation
  fallback for other storage. This avoids expensive Unicode-equivalent search
  through similar JSON prefixes. Membership, equality and hashing preserve exact
  source bytes: canonically equivalent Unicode can mean different JSON field
  names or JavaScript string values.

An isolated source-search sample dropped from 0.371 s to 0.011 s for the same
24 large source slices. Focused render measurements after the change:

| Report (24 charts)       | First rendering, two workers | Reopening cached vectors |
| ------------------------ | ---------------------------: | -----------------------: |
| 256 observations/chart   |                      0.312 s |                 0.0024 s |
| 4,096 observations/chart |                      0.610 s |                 0.0350 s |

The heavy report's first rendering is about 49% faster than the preceding
1.191 s two-worker measurement. Cached reopening avoids WebKit rendering and
returns all 24 vectors synchronously. These timings cover chart requests and
completion, not body fetching, Markdown parsing or compositor presentation;
they remain local samples without performance assertions in CI. Vector cache
bytes remain 500,900 and 2,660,657 respectively.

Focused regressions cover exact Unicode and embedded-NUL source matching,
byte-distinct cache keys, width/theme/source changes, least-recently used and
byte-budget eviction, failure retries, model isolation and clearing during an
in-flight render.

Follow-up verification:

- The change-selected Apple run passed DieterKit (17) and native helpers (10),
  then completed the Mac suite with 517 total cases. Its sole failure was the
  timer-overload policy check. The timer was corrected to the required
  nanosecond API; all 24 focused diagram/policy tests then passed. Two final
  cache-observation/clearing tests passed after adding native E2E evidence.
  Passing unrelated suites were not repeated. The initial failed run is kept
  under `tmp/pipeline/20261027T145114-swift-tests-a2f2b1/`.
- `tmp/mail-render-speed/final-focused.log` records the corrected measurements
  and policy pass; `worker-profile.log` records the earlier worker sweep.
- The final Mac E2E run in `tmp/pipeline/20261027T145950-mac-e2e-18aac9/` passed
  rich Markdown/fallback/reopening (8.7 s), backgrounds/selection (16.3 s), and
  the supplied 15-chart report (13.9 s). The rich flow now asserts cache reuse
  after switching messages: `mail-rich/mac-mail-rich-reopened.txt` records
  **4 reused**. The report still asserts 15 rendered / zero fallbacks in both
  themes. Compositor captures of the reopened message, report and explicit-white
  fixture were opened and inspected. No task-owned app remained after cleanup.
- Documentation checks, Maestro flow lint, formatting and staged lint passed.

This follow-up changes only the Mac adapter and reader. The earlier mobile
qualification still applies to the unchanged shared SVG renderer.
