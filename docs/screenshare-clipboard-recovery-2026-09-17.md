# Image/file clipboard and persistent screen recovery

## Plan and implementation

1. Extend the existing clipboard operation with typed image/file items and capability negotiation. Keep the same daemon RPC, native backend interface and dedicated encrypted WebRTC channel, preserving CLI parity and future non-macOS backends.
2. Read/write native macOS image pasteboard types and file URLs. Transfer file bytes rather than source paths. Android reads granted content URIs and publishes received files through a separate FileProvider.
3. Keep transient recovery alive while the tab is intentionally open. Reopen the authenticated route and WebRTC session after peer failure, lease expiry, input/clipboard channel failure or system resume. Stop on explicit disconnect/tab close and permanent trust, permission or policy failures.
4. Verify native clipboard bytes, CLI transport parity, interrupted transfers, more than three failed reconnect attempts, sleep/wake and explicit cancellation.

Implemented on the daemon, macOS helper, Mac viewer, Android viewer and CLI. Protocol schemas and checked-in clients were regenerated. Existing local screen latency/quality work was preserved.

## Behavior and bounds

- Text: UTF-8 up to 1 MiB, including empty text. Images: PNG, JPEG, TIFF and WebP. Files: up to 64 regular files and 8 MiB total per transfer. Folders, symbolic links, path traversal, duplicate/colliding filenames and rich-text formatting are rejected or unsupported.
- Binary transfers use 16 KiB chunks with bounded buffering and a 30-second transfer deadline. Incomplete transfers never reach the clipboard backend. Copy/paste shortcuts are never automatically replayed, including after reconnection.
- File staging uses `DIETER_HOME/clipboard` on macOS and the Android app's private files directory. Source paths never cross the network. Files remain usable after disconnect. Each new file transfer prunes batches older than 24 hours and keeps at most eight batches, bounding retained file payloads to 64 MiB. Files are not stored in Dieter conversation history or logs.
- Synchronization remains restricted to the focused controller and current control grant. Capability negotiation prevents silently pasting empty text into older daemons when binary content was requested.
- Recovery starts after 250 ms and backs off to at most five seconds between attempts, without an attempt limit. Each Mac connection attempt is watched for a stall; disconnected peers get three seconds to resume before replacement. Android route discovery has a 20-second deadline and peer recovery follows the same three-second rule.
- Mac workspace wake notifications immediately replace the connection. Sleep pauses optional inactivity disconnection, and wake resets the timer. Inactivity timeout is disabled by default; explicit saved preferences remain honored. Android backgrounding releases input while retaining connection intent; resume refreshes the connection. Explicit disconnect never reconnects on wake.

CLI examples:

```sh
dieter screen clipboard paste SESSION --image screenshot.png
dieter screen clipboard paste SESSION --attach report.pdf --attach diagram.png
dieter screen clipboard copy SESSION --output-dir ./received-files
```

`--file` retains its existing UTF-8 text semantics. `--output-dir` must be a new directory and never overwrites existing output.

## Validation

- Native macOS screen integration: all 11 tests passed with actual WebRTC, hardware decoding and Metal presentation. Image and multi-file round trips included a 2 MiB binary file and an empty file. A forced lease expiry survived five consecutive unavailable route attempts, recovered native capture, and reconnected on simulated wake. Explicit disconnect canceled further recovery. Log: `/tmp/dieter-binary-mac-e2e.log`.
- Real ScreenCaptureKit/native input integration: all 11 tests passed. An owned macOS application consumed actual image and file paste shortcuts, verified received bytes with SHA-256, and copied the identical bytes back. Log: `/tmp/dieter-binary-mac-real.log`. Viewer evidence: `/var/folders/nk/8324zqs10fq249x2ythzxc540000gn/T/dieter-screen-viewer-2BDDBC90-8E95-4E47-A2F6-5A533BCBA4A4`.
- Android emulator integration passed on the visible `Pixel_9_API_37_1` / `emulator-5554`, using Apple host GLES. The journey exercised images and multiple files in both directions, five unavailable routes, resume recovery, control, canvas gestures and disconnect cancellation. Evidence: `/tmp/dieter-android-screens.09V2Ez`; log: `/tmp/dieter-binary-android-e2e-final.log`.
- The complete Mac unit suite passed 612 tests. A subsequently added workspace sleep/wake notification test also passed, including an enabled inactivity timer and explicit disconnect. Logs: `/tmp/dieter-binary-all-mac-tests.log`, `/tmp/dieter-binary-wake-notification.log`.
- All 299 Android unit tests passed, including binary limits, empty files, path rejection and portable filename collision checks. Log: `/tmp/dieter-binary-android-unit-final.log`.
- Actual WebRTC clipboard framing was tested with a successful baseline exchange followed by a disconnected partial 8 MiB paste: no clipboard mutation or paste occurred. Go race regression log: `/tmp/dieter-binary-final-clipboard.log`.
- Go race tests across the affected repository packages, vet, and the native capture/input suite passed during `just check-changed`. CLI integration covers local, authenticated direct TLS and relay fallback. Logs: `/tmp/dieter-binary-check.log`, `/tmp/dieter-binary-cli-server.log`. Final CLI route, help and TIFF/image tests also passed under the race detector (18.980s): `/tmp/dieter-binary-final-cli.log`.

The full `just check-changed` run then stopped at its native Mac viewer stage because another task/operator launched Dieter. The [mac-app skill](../.agents/skills/mac-app/SKILL.md) says: “If another bundle or task owns a process, do not terminate it or launch a second copy.” Those app processes were preserved. Subsequent broad UI/iOS/connected checks were not run by that command. The separate Mac and Android screen integration runs above had already passed. The additional Mac UI scenario that interrupts a transfer mid-flight was added but could not be rerun after that lifecycle conflict; its wire-level invariant passed in the Go WebRTC test.

## Environment and release state

Tests used disposable daemons, pasteboards, file staging roots and credentials. No operator daemon or app was stopped, replaced or upgraded. The owned Android emulator was gracefully stopped and its snapshot saved; the physical Android phone was untouched. Canonical SwiftPM test caches were reused. The existing operator app at `/Applications/Dieter.app` was left running.

Main advanced externally to `201115a4` during this work, including the additive schema fields and earlier screen work. This task made no commit, push or deployment. The complete implementation still has working-tree changes and needs a release of the daemon/helper and native clients.

Final focused Mac tests passed after the sleep-notification and default-inactivity UI check updates (five tests, 0.405s): `/tmp/dieter-binary-final-mac-focused.log`. `git diff --check` passed.
