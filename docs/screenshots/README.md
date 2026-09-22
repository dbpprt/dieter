# Native documentation screenshots

The canonical images live in
[`landingpage/static/images/screenshots`](../../landingpage/static/images/screenshots).
The website and root README share those assets. The
[product tour](../../landingpage/content/docs/tour.md) explains the concepts they show.

Captured on **22 September 2026**, from the repository's native debug builds.
These are actual rendered interfaces, not mockups or generated images. Only
whole-window capture and lossless PNG storage were used; no UI text or application
state was painted over. All eight images together are about 1 MiB.

| Image | Dimensions | Concept and source |
| --- | --- | --- |
| `macos-board.png` | 1380 × 870 | Four demo cards in the native Mac board |
| `macos-workspace.png` | 1380 × 870 | Card conversation and editable Markdown document |
| `macos-processes.png` | 1380 × 870 | Completed `git ls-files` execution and retained output |
| `android-activity.png` | 1080 × 2424 | Activity feed with sample task/chat activity |
| `android-chat.png` | 1080 × 2424 | Standalone conversation starting a mock agent |
| `android-task.png` | 1080 × 2424 | Board task conversation and its review tabs |
| `android-machines.png` | 1080 × 2424 | Compatible and intentionally incompatible fixture machines |
| `android-telemetry.png` | 1080 × 2424 | Host route and live telemetry viewed from Android |

## Capture environment

- Mac: the canonical `apps/mac/build/Dieter.app`, built with `just mac build`,
  light appearance, Monochrome design, transparency off. The conversation
  workspace panel was explicitly enabled in **Settings → Experimental**;
  it is off by default. Preferences and client state were isolated.
- Android: the visible `Pixel_9_API_37_1` emulator, `emulator-5554`, host GPU,
  native Compose UI in dark appearance. Activity and Machines integration
  fixtures supplied disposable account and project state.
- Backend: `scripts/isolated-gateway`, random loopback listeners, disposable
  credentials and repository, and the mock harness. The Mac sample project is
  **Orbit** on **Studio Mac**. Android retains the fixture's **Isolated E2E** names.
- The deliberately incompatible host demonstrates rejection of a mismatched
  application contract. It is not a connected second project host.
- Mock responses, token counts, startup timers, and telemetry are illustrative
  snapshots. They are not model recommendations or performance claims.

## Refresh the set

Read the repository's Mac and Android operation skills before capturing. Preserve
the operator's daemon, client state, credentials, and attached physical devices.

1. Run `just mac status` and `just android emulator-status`. Reuse healthy owned
   processes; do not launch a second Mac app beside an operator's app.
2. Build with `just mac build`. Use the isolated fixture and launch arguments
   documented in `apps/mac/Tools/DieterMacSmokeDriver/main.swift` for a disposable
   Mac account, preferences suite, and client state root. Seed demo projects,
   cards, files, and processes through the Dieter CLI, never by editing its store.
3. For Android, use `just android machines-test` and the isolated
   `ActivityEndToEndTest` fixture. Keep `ANDROID_SERIAL=emulator-5554` on connected
   tasks. Capture the observed Compose root at the relevant test checkpoints, or
   use `just android screenshot PATH` for a full-device capture.
4. Navigate the real native UI. Capture the verified Mac window with
   `screencapture -x -o -l WINDOW_ID PATH`. Check both the accessibility hierarchy
   and the resulting PNG, especially native text, materials, clipped controls,
   and document tables. AppKit view-cache exports can render materials badly;
   use the actual window capture for publication.
5. Inspect every image for private prompts, account identifiers, tokens,
   filesystem paths, notifications, and other applications. Replace data in the
   disposable fixture before capture instead of redacting a production session.
6. Keep one canonical PNG per concept, meaningful alt text, correct dimensions,
   and a caption that states any experimental setting. Update this provenance
   table and run `just site check`. Review desktop and phone layouts.
7. Quit the owned Mac app with `just mac quit`, explicitly stop the fixture, and
   close an owned emulator with `just android emulator-stop` so its snapshot is
   safely saved. Never terminate the operator's daemon to clean up screenshots.
