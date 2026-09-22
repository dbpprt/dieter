> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Mac screen-share windows and cursor ownership

## Implementation

The Screens expand button moves the selected share into a native macOS
full-screen window. Control–Command–F toggles full screen. Leaving full screen
keeps a movable, resizable window. Its auto-hiding native toolbar contains screen
options, control handoff, and Return to Dieter. Closing the window redocks;
closing the share's tab disconnects and disposes its window.

Each `ScreenShareSession` owns one `RemoteDesktopInputView` and Metal renderer.
Small SwiftUI host containers move that view between windows. A departing host
only removes a surface it still owns, so SwiftUI teardown cannot detach the
surface from its new window. The connection, decoder, frame mailbox, and session
identity survive. Clipboard focus follows the input surface. Return to Dieter
selects Screens again, including after navigation elsewhere. Native full-screen
transitions serialize a pending request to redock.

While controlling, the system pointer uses the host's shape and hotspot and
moves locally. Mouse hover suppresses the host-position overlay before keyboard
focus is acquired. Shape/state updates refresh cursor ownership immediately;
pointer movement never waits for a video frame or network acknowledgement.
View-only and explicitly embedded-cursor sessions use a transparent local cursor
within the video rectangle. There is no process-wide cursor hide counter.

Focus loss releases held input. Command–Shift–Escape also suspends pointer and
scroll forwarding until the viewer is focused again. Ordinary Escape goes to the
remote application. The capture helper retains the last valid cursor shape when
system cursor lookup temporarily fails, instead of silently burning a second
cursor into the video. Existing explicit embedded capture remains compatible.

## Validation design

- `ScreenShareViewTests` covers moving the same surface, switching another share
  while detached, repeated undock, window-close redock, tab-close disconnect,
  retained dimensions, and cursor ownership modes.
- `DIETER_TEST_SCREEN_UNDOCK=1 just mac screens-test` starts an authenticated,
  disposable daemon and native hardware video fixture. It enters actual native
  full screen, sends pointer input through the peer, checks the ACK, tests
  control handoff and input release, returns to the main window, and verifies
  one unchanged session ID. It records PNGs and 24 input-to-Metal presentation
  samples per mode. SwiftPM has no running NSApplication event loop, so this
  fixture explicitly supplies window activation for pointer delivery.
- The packaged app's core smoke clicks the real expand button and checks actual
  AppKit activation, single-cursor presentation before keyboard focus,
  view-only/embedded modes, Control–Command–F, and the native Return to Dieter
  action after navigating away from Screens. It uses the production activation
  predicate, complementing the transport fixture.

Local cursor-update time and remote application response time are separate
measurements. Full-screen video also requests a larger capture size than the
docked viewport. The synthetic timings verify a bounded complete path; they do
not establish that full screen reduces latency, or promise zero network latency.

The operator daemon and its saved sessions are never restarted or replaced by
these tests.

## Recorded results

`just check-changed --dry-run` and `just check-changed` were run. The affected Go
race suite and vet passed, as did the native capture/input suite and all 21 native
viewer tests. The final full Mac module run passed 631 tests in 28 suites,
including the regression reserving Control–Command–F in view-only mode.
The packaged core suite passed all screen assertions under real AppKit
activation, including the single local cursor before keyboard focus, leaving the
video, view-only/embedded modes, the full-screen shortcut, and return after
navigating to Settings. Board, machine, sidebar, terminal, Island, and workspace
suites also passed. After the final shortcut change, the rebuilt packaged core
suite passed all 88 checks again. No task-owned Mac app or emulator was left
running.

The authenticated undocking fixture retained session
`rd_I9fmcwiSoZlchkpL` throughout. A complete local pointer-event handler took
0.107 ms and updated the cursor before the remote ACK arrived. Video response,
measured from synthetic input dispatch to actual Metal presentation:

| Mode | Median | p95 | Samples |
| --- | ---: | ---: | ---: |
| Docked | 45.5 ms | 56.8 ms | 24 |
| Undocked full screen | 76.0 ms | 81.9 ms | 24 |

This journey adapted capture from 1120×630 to 1600×900 and exercised control
handoffs before the full-screen measurement. It is not a matched performance
comparison. Video response was higher in that measurement; the cursor improvement
comes from local presentation, not a claim that remote application response has
become instantaneous.

The broad conversation suite failed code-line selection/reveal and embedded
terminal output. On one retry the terminal passed, code-line reveal failed
again, and an attachment-markup gesture assertion failed. Those unrelated
surfaces were left unchanged. The full check therefore is not green.

Android regression testing was unavailable: the saved `Pixel_9_API_37_1` snapshot
failed to restore (`Missing section footer`, VM state error -22). No emulator
remained running; its snapshot and userdata were preserved. The pinned
`emulator-5554` screen test could not connect. The attached physical phone was
not used. Concurrent edits to ChatsView and its tests were preserved separately.

Evidence retained locally:

- `/tmp/dieter-undock-check-changed.log`
- `/tmp/dieter-undock-smoke-remaining.log`
- `/tmp/dieter-undock-conversation-retry.log`
- `/tmp/dieter-undock-emulator-start.log`
- `/tmp/dieter-undock-android-screens.log`
- `/tmp/dieter-undock-final-mac-tests.log`
- `/tmp/dieter-undock-final-core.log`
- Core UI screenshots/reports under
  `apps/mac/.build/smoke/core-20260917-213539-46817eb1-0f61-4cc4-ac69-6d53431c9167/`.
- Native video screenshots and `results.json` under the temporary
  `dieter-undocked-0F356553-F578-4A84-B4E3-647DD6E2B885` evidence directory printed
  by the integration test.
