# Native documentation screenshots

The canonical images live in
[`landingpage/static/images/screenshots`](../../landingpage/static/images/screenshots).
The website and root README share those assets. The
[product tour](../../landingpage/content/docs/tour.md) explains the concepts they show.

Captured on **22 September 2026**, from native debug builds. These are actual
rendered interfaces, not product mockups or generated images. Whole-window
captures are stored as lossless PNGs; no UI text or application state was painted
over. The ten images total about 1.6 MiB.

| Image | Dimensions | Concept and source |
| --- | --- | --- |
| `macos-board.png` | 1380 × 870 | Five projects; Orbit's 17-task board, four labels, two execution owners, and three active mock turns |
| `macos-terminal.png` | 1380 × 870 | Build Mac's native terminal, eight passing disposable-project tests, and Git status |
| `macos-screens.png` | 1380 × 870 | Live WebRTC screen stream from Studio Mac showing an owned Orbit Preview window |
| `macos-files.png` | 1380 × 870 | Main project Files surface with an editable Markdown launch plan and host-assignment table |
| `macos-machines.png` | 1380 × 870 | Build Mac's availability, route, and live CPU/memory/GPU telemetry over the shared board |
| `android-activity.png` | 1080 × 2424 | Activity feed with sample task/chat activity |
| `android-chat.png` | 1080 × 2424 | Standalone conversation starting a mock agent |
| `android-task.png` | 1080 × 2424 | Board task conversation and its review tabs |
| `android-machines.png` | 1080 × 2424 | Compatible and intentionally incompatible fixture machines |
| `android-telemetry.png` | 1080 × 2424 | Host route and live telemetry viewed from Android |

## Mac capture environment

- Canonical `apps/mac/build/Dieter.app`, built with `just mac build` and the
  canonical SwiftPM cache. Dark appearance, **Electric Blue** design,
  transparency off. **The conversation workspace side panel is disabled in
  every Mac capture.** Files is the independent main project surface.
- Isolated preferences, client state, gateway, and disposable repositories.
  The operator's running daemon, credentials, and projects were not modified.
- Five sample projects: **Atlas API**, **Canvas**, **Field Notes**,
  **Northstar Mobile**, and **Orbit**. Orbit's **Product launch** board has
  17 tasks across Todo, Running, Review, and Done, with Frontend, Quality,
  Design, and Backend labels.
- **Studio Mac** and **Build Mac** are two independently enrolled daemon
  identities with separate checkout and conversation ownership. Both fixtures
  run on the same physical Mac. They exercise actual shared project records and
  authenticated routing; these images do not establish a physical two-host test
  or a performance benchmark. Projects, tasks, names, labels, and terminal
  sessions were created through the Dieter CLI.
- Three deterministic mock turns were active during the board capture. Mock
  content, token counts, timers, and sample task claims are illustrative. The
  terminal's eight tests actually ran, but test only its tiny sample project,
  not Dieter itself. Hardware telemetry is an actual snapshot of the fixture host.

### Screen-sharing capture

The screen image uses the native Dieter viewer, authenticated gateway signaling,
real WebRTC media, ScreenCaptureKit, and hardware encoding. Its source is an
owned AppKit/WKWebView window titled **Orbit Preview**, containing a disposable
sample dashboard. Its displayed metrics are sample content, not Dieter metrics
or agent results.

An isolated development copy of the capture helper uses
`SCContentFilter(desktopIndependentWindow:)` for that exact owned window instead
of capturing the physical display. This prevents private desktop content and
recursive screen mirroring from entering the stream. **Window-only sharing is
not presented as a shipped product feature:** standard Dieter screen hosting
shares a display. No production capture code or OS permission was changed.

The captured session showed **Live**, **Control active**, and **Direct media**.
No remote keystrokes or clipboard transfer were needed. A prior Release Control
interaction displayed a clipboard cancellation warning; the final capture uses
a freshly connected, visibly clean session. This is screenshot evidence of a
live viewer, not a complete remote-input or clipboard test.

## Android capture environment

- Visible `Pixel_9_API_37_1` emulator, `emulator-5554`, host GPU, native Compose UI
  in dark appearance. Activity and Machines integration fixtures supplied
  disposable account and project state through `scripts/isolated-gateway`.
- Android retains the fixture's **Isolated E2E** names. The deliberately
  incompatible host demonstrates rejection of a mismatched application
  contract; it is not a connected second project host.
- Android images are unchanged from the initial documentation refresh. The
  attached physical phone was not targeted.

## Refresh the set

Read the repository's Mac and Android operation skills before capturing. Preserve
the operator's daemon, client state, credentials, and attached physical devices.

1. Run `just mac status` and `just android emulator-status`. Reuse healthy owned
   processes; do not launch a second Mac app beside an operator's app.
2. Build with `just mac build`. Use the isolated fixture and launch arguments
   documented in `apps/mac/Tools/DieterMacSmokeDriver/main.swift` for a disposable
   account, preferences suite, and client state root. Seed projects, cards, files,
   and processes through the Dieter CLI, never by editing its store. Attach each
   checkout to the same shared project; keep real execution-owner records.
3. Set dark appearance, Electric Blue, transparency off, and disable
   **Settings → Experimental → Show the workspace side panel**. Use the main
   Files, Terminals, and Screens surfaces. For screen capture, isolate the visual
   target and disclose any development-only source adaptation as above.
4. For Android, use `just android machines-test` and the isolated
   `ActivityEndToEndTest` fixture. Keep `ANDROID_SERIAL=emulator-5554` on connected
   tasks. Capture the observed Compose root at the relevant test checkpoints, or
   use `just android screenshot PATH` for a full-device capture.
5. Navigate the real native UI. Capture the verified Mac window with
   `screencapture -x -o -l WINDOW_ID PATH`. Inspect both the accessibility hierarchy
   and PNG, including native text, materials, clipped controls, and tables.
   AppKit view-cache exports can render materials badly; use an actual window
   capture for publication.
6. Inspect every image for private prompts, account identifiers, tokens,
   notifications, and other applications. Replace data in the disposable fixture
   before capture instead of redacting a production session. Any displayed paths
   must refer only to the disposable capture workspace.
7. Keep one canonical PNG per concept, meaningful alt text, correct dimensions,
   and an accurate caption. Update this provenance table and run `just site check`.
   Regenerate `og-image.png` with `swift landingpage/tools/render_social.swift`.
   Review desktop and phone layouts.
8. Disconnect owned screen sessions and quit the owned Mac app with `just mac quit`.
   Explicitly stop registered fixtures and preview targets; close an owned emulator
   with `just android emulator-stop`. Verify no owned Mac app remains. Never
   terminate the operator's daemon to clean up screenshots.
