# Mail chart transparency and selection: verification

Follow-up to [rich Markdown in Mail](mail-rich-markdown-results.md), verified
on mini-home on 27 October 2026 against `origin/main` at `2d736128`, after
stable v0.6.430. The isolated debug clients identify as
`0.6.431-dev.696+2d736128.dirty`. No production mailbox, operator preferences,
daemon or installed app was used or replaced.

## Reproduction and fixes

The supplied revised `report.md` contains 15 inline Vega-Lite charts with
`background: null` and `config.view.fill: null`. It was injected into the
disposable E2E mailbox using `DIETER_TEST_MAIL_REPORT`; its workspace links
were not opened. The older deliberately white report was not used.

Opening native screenshots reproduced opaque chart rectangles on Mac and a
white rectangle against the tinted iPhone light reader. Transparent SVG/PNG
pixels alone had missed both problems. Mac WebKit snapshots need page drawing
disabled and a clear nonopaque hosting window. On iOS, clearing WebKit's page
and scroll backgrounds is necessary, and Compose's default interop placement
cuts through the reader surface. Overlay placement preserves that surface.
A clear UIView container keeps WebKit's frame at the local origin, with
automatic content insets disabled, so scrolling a partly clipped chart does
not shift its page. Mobile adapters also receive subsequent renderer height
updates when titles or legends reflow.

Diagram-only CSS resets `color-scheme` to `normal`, avoiding WebKit's system
canvas fill. Both preview modes use the shared `renderer: "svg"` embed option;
the canvas only measures wrapped text. Theme defaults now cover titles,
subtitles, axes, ticks, legends and text marks,
including raw Vega's fill styles. Explicit CSS backgrounds choose contrasting
defaults; author-specified backgrounds and colors keep precedence. Android's
existing clear WebView backing is retained.

The supplied mailbox screenshot's dark text on blue was reproduced in the
actual Mac list. Increased background prominence now selects white primary
text, slightly dimmer white secondary text/time, and white avatar decoration.
Important/flag/unread indicators retain their existing white selected state.
Inspection covered active/inactive selection, read/unread, flagged/important,
both themes and the narrow mailbox column. Row spacing, baseline alignment,
separators, two-line previews and badge placement showed no further defect;
their geometry was retained. Phone lists were inspected in both themes at
their native narrow widths.

## Screenshots opened during implementation

These are native Mail readers with the surrounding surface. The committed
captures use the synthetic six-chart [background fixture](../../tests/fixtures/mail/backgrounds.md).
The supplied report and its full screenshots remain local artifacts.

| Before                                                        | What was visible                                                                                                                      |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [Mac chart](assets/mail-transparency-mac-before.png)          | Opaque dark rectangle, with unreadable default title/subtitle text. Cropped to the reader to omit the supplied report's list preview. |
| [iPhone light chart](assets/mail-transparency-ios-before.png) | White chart margins against the tinted Mail surface.                                                                                  |
| [Mac selected row](assets/mail-selection-before.png)          | Sender, subject, preview and time stay dark on saturated blue.                                                                        |

| Platform | Light                                                      | Dark                                                       | Visually observed                                                                                            |
| -------- | ---------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| iPhone   | [Null/omitted](assets/mail-transparency-ios-light.png)     | [Omitted/white](assets/mail-transparency-ios-dark.png)     | Transparent margins match the tinted/black reader; white retains a separate white surface and dark text.     |
| Android  | [Null/omitted](assets/mail-transparency-android-light.png) | [Omitted/white](assets/mail-transparency-android-dark.png) | Reader surface continues through the chart, including margins and legend; white remains opaque and readable. |

[Mac selected row after the fix](assets/mail-selection-after.png),
[Mac transparent chart in dark appearance](assets/mail-transparency-mac-dark.png)
and [Mac explicit white beside transparent charts](assets/mail-transparency-mac-white.png).
These crops omit the supplied report's list preview; the gallery retains
full-window light/dark captures and both active/inactive selection states.
[iPhone mailbox in light](assets/mail-rows-ios-light.png) and
[dark appearance](assets/mail-rows-ios-dark.png) show read/unread, important
and flagged rows at phone width.

Final screenshot inspection checked the plot, title/subtitle and legend
margins, labels and annotations, null/omitted/explicit-white cases in both
Vega-Lite and raw Vega, scrolling, switching messages and reopening. Native
phone chrome remains usable above the charts. Explicit white remains white
and uses readable dark defaults in dark appearance.

## Runs and artifact locations

Paths below are relative to this card's worktree. Each E2E directory includes
`results.json`, flow output and cleanup evidence. The representative final
captures listed here were opened and visually inspected. The local gallery
is `tmp/mail-visual-evidence.html`.

| Platform                           | Final flows                                                                           | Evidence under `tmp/pipeline/`       |
| ---------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------ |
| iPhone 17 Pro / iOS 26.5 simulator | Backgrounds 91.0 s; revised report 80.6 s; rich fallback/lifecycle 55.0 s; all passed | `20261027T120113-ios-e2e-479016`     |
| Android 15 emulator                | Backgrounds 86.1 s; revised report 54.0 s; both passed                                | `20261027T120841-android-e2e-28cf6c` |
| macOS                              | Backgrounds/selection 17.7 s; revised report 13.3 s; both passed                      | `20261027T121208-mac-e2e-e956dd`     |

The final iPhone initialization check passed the background/list and
scroll/reopen flow again in 90.4 s (`20261027T121859-ios-e2e-dcf6f0`), after
moving clear-background assignments out of its layout callback into
initialization.

The final mobile background/list PNGs are under each directory's
`maestro/2026-10-27_132129/` (final iOS) or
`maestro/2026-10-27_130849/` (Android), then
`Mail chart backgrounds/takeScreenshot/`. Opened captures include
`mail-backgrounds-{light,dark}-vega-lite-{null,white}.png`,
`mail-backgrounds-{light,dark}-vega-white.png`,
`mail-backgrounds-{light,dark}-reopened.png` and `mail-rows-{light,dark}.png`.
The supplied report's captures are in
`Revised upday report (local attachment)/takeScreenshot/`:
`upday-{light,dark}-{chart,scrolled}.png`. For iOS, these and the source fallback
captures in `Mail offline graphics/takeScreenshot/` are in the earlier
`20261027T120113-ios-e2e-479016/maestro/2026-10-27_130336/` run. Its disposable
simulator was confirmed absent after pipeline cleanup.

The final Mac PNGs are under `mail-backgrounds/`:
`mail-backgrounds-{light,dark}-{selected,inactive,1,2,3,reopened}.png` and
`mail-rows-{light,dark}-{selected-unread,important,flagged}.png`. The supplied
report is under `mail-revised-local/upday-{light,dark}-{header,1,2,3,4,5}.png`;
the flow asserts **15 rendered, zero source fallbacks** in both themes.
Both flow processes exited and no `DieterMac` process remained.

Earlier rich lifecycle runs also passed on Mac
(`20261027T111317-mac-e2e-e7603a`) and Android
(`20261027T112107-android-e2e-171322`). Attachment-specific local flows are
retained under `tmp/mail-local-flows/`, outside the checked-in fixture suite.

Rejected iterations are retained: Mac `20261027T110512-mac-e2e-57ebc5`,
iOS `20261027T112138-ios-e2e-fba45b`, `20261027T112935-ios-e2e-36a54c`,
`20261027T113608-ios-e2e-030d2d`, `20261027T114607-ios-e2e-53ab56` and
`20261027T115510-ios-e2e-a42009`. Passing flow assertions in those iOS runs
did not override the visible white backing or clipped charts.

The first Android comparison run, `20261027T112107-android-e2e-171322`,
failed with an ANR during concurrent iOS compilation on this 16 GB host.
Its device logs, screenshot and `lastanr.txt` were retained; the report and
rich lifecycle flows passed. The final retry runs without concurrent Apple
builds. No assertions were removed, emulator data wiped or unrelated process
stopped.

## Checks and boundaries

The change selector was inspected with `--base origin/main --dry-run` and
its selected checks were completed:

| Check                                      | Result                                                                                                                                                  |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Go formatting/lint, unit/component and E2E | Passed; the fixture-count assertion was updated for the added comparison and its package rerun.                                                         |
| Kotlin tests                               | Passed; 71 core E2E cases passed initially, then the Mail case passed on focused rerun after updating its seeded counts; remaining JVM/UI tests passed. |
| Apple unit suites                          | DieterKit 17, native helpers 10, Mac 507 passed with minimum-count guards.                                                                              |
| Final renderer/native export follow-up     | 44 Node tests passed; two focused Mac snapshot/HTML-export tests passed after the mobile sizing bridge change.                                          |
| Native builds                              | iOS simulator build passed; Android lint/unit and all three platform E2E builds passed.                                                                 |
| Pipeline helpers                           | 25 tests, 245 assertions passed.                                                                                                                        |
| Documentation and Maestro plans            | Passed.                                                                                                                                                 |

Final formatting and staged lint passed.

The six-chart fixture covers `background: null`, omitted background and
`background: "#ffffff"` in both Vega dialects, with subtitles, axes, legends
and annotations. Native snapshot tests verify transparent margins, explicit
white and alpha-preserving downsampling. Static HTML export retains all six
SVGs and both explicit white backgrounds; the Apple suite also exercises
existing PDF rendering and pagination.

Offline validation, the interpreter, inline-data limits, URL denial, raw-HTML
escaping, readable source fallback and disposal remain in place. Verification
used an iPhone 17 Pro simulator with iOS 26.5, an Android 15/API 35 emulator
at 720×1280/280 dpi, and macOS 27.0.1. No physical iPhone, iPad or Android
phone was qualified by this follow-up.

Reproduce the checked-in regression with pinned tools:

```sh
mise exec -- just check-changed --base origin/main --dry-run
mise exec -- just e2e mac flows:mail-backgrounds screenshots:compositor
mise exec -- just e2e ios flows:mail-backgrounds
mise exec -- just e2e android profile:android-emulator flows:mail-backgrounds
```

The Mac compositor option requires Screen Recording permission and fails if
capture fails. It captures the task window only. Default permission-independent
CI capture remains available. iOS creates/deletes its own simulator; Android
borrows the exact configured warm emulator; task-owned clients and fixture
gateways are closed by the supported workflows.
