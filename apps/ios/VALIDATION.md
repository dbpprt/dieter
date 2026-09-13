# iOS remote client validation

13 September 2026. Developed in the separate `codex/ios-remote-client` worktree;
updated with `main` at `28352cd`, including the dedicated Apple release signing
setup.

## Delivered scope

The iOS 18+ app uses native SwiftUI navigation on iPhone and iPad and the existing
Dieter API and authenticated connection manager. It browses enrolled nodes,
projects, boards, tasks, and chats; creates drafts or starts tasks immediately;
sends follow-ups in the same conversation; displays live transcripts; and reads
and saves remote text files with revision checks. The daemon remains responsible
for execution and durable data.

Authentication uses the gateway's existing PKCE callback and device-only
Keychain items separated by gateway origin. Reconnection preserves the readable
conversation for the same node, rejects stale replies, and resumes observation.
Direct routes require the enrolled daemon's CA and exact URI identity. Remote
plaintext endpoints are rejected; only the Debug smoke fixture permits loopback
plaintext.

This is a basic remote client. New tasks use the selected project's checkout.
Draft text and mutation retry identities remain in memory, and transcript
retention is bounded to 240 messages. Files currently use a text editor or image
viewer; the Mac app's full workspace tabs and rich document tools are not part
of this initial iOS scope.

## Completed checks

- Xcode 26.6 (`17F113`), iOS Simulator 26.5.
- All 562 Swift tests in 25 suites passed, including shared certificate,
  routing, authentication ownership, conversation continuity, and pagination
  cases.
- Check-planner, Just recipe validation, Swift formatting, and diff checks passed.
- The ad-hoc signed Simulator app built successfully. Its embedded
  `DieterIOS.framework` exists and `codesign --verify --deep --strict` passed.
- The unsigned physical-device Release build passed with `just ios build-device`.
- The native iPhone journey verified Run, same-conversation follow-up, remote
  file edit/save/reopen, relaunch persistence, Add then Start, foreground
  reconnection, incompatible-node rejection, and return to a compatible node.
- Native application-hosted Keychain and iOS certificate tests passed.

The final iPhone run passed **9 tests, 0 failures**, with the optional public
HTTPS probe explicitly skipped. Its result and screenshots are in
`.build/smoke/20260912-231739-c9f95660/`.

The local result bundle includes screenshots of the iPhone conversation.

A fresh recording run of the iPhone remote journey also passed with 1 test and
0 failures (`.build/smoke/20260913-072912-85eee2e1/`). A 78-second walkthrough
uses that native recording at 1.5× playback, covering task creation, chat,
remote file editing, starting a draft, and foreground reconnection.

The landscape iPad run also passed **9 tests, 0 failures**, with the same
optional HTTPS skip. Its full remote journey and accessibility hierarchy
verified the three-column layout at 1210 × 834 points. Results are in
`.build/smoke/20260912-232848-2fc2493b/`. Native attachments are retained unchanged.
The native PNGs contain landscape pixels at 2420 × 1668 with EXIF orientation 8;
their exported presentation has an orientation/rendering issue. This does not
establish an app layout defect. These exports are not used as presentation images.

The tablet test scrolls its provider picker fully above the footer before
tapping it and selects the mock provider while the form is empty. This fixes
the initial test's offscreen tap without changing the app's native picker.

## Signing integration checks

The setup helper supports `macos`, `ios`, and `all`, retaining the Mac default.
It validates dedicated Apple Distribution credentials, exact App Store profile
identity, and the separate upload API key before configuring any GitHub secrets.
The manual TestFlight workflow has an explicit upload switch; pull requests and
pushes do not upload builds.

- All 66 release-tool tests passed: 32 signing tests, 11 installer tests, and
  23 iOS archive/export/upload tests. Tests cover invalid credentials, version
  validation, scoped signing, upload opt-in, and cleanup after failures.
- All 29 check-planner tests, Just formatting, and workflow lint passed.
- The updated Simulator app built successfully with app-scoped signing settings.
- `just ios archive-unsigned 0.1.0 1.1` produced a valid ARM64 iOS archive.
  Both archive and app metadata match the requested version/build and bundle ID;
  the app supports iPhone/iPad and embeds `DieterIOS.framework`.
- Every app-icon entry has the expected size and opaque RGB pixels; the artwork
  has a square background for the operating system's icon mask.

The updated iPhone suite passed **9 tests, 0 failures**, with the optional public
HTTPS probe skipped (`.build/smoke/20260913-115651-11b12238/`). The iPad suite
passed the same **9 tests, 0 failures** on an unchanged focused rerun
(`.build/smoke/20260913-121000-1f7aab03/`). Its first run stopped when a tap on
Browse files left the menu open; captured accessibility evidence showed no file
sheet had opened. The retry completed file edit/save/reopen and the rest of the
journey. This intermittent menu interaction remains a smoke-test limitation.

## PR CI follow-up

The failed CI run `34758195699` exposed two separate native issues. The iPad
composer's narrow text field included a horizontal scroll indicator at its
center, and the first follow-up tap did not focus text input. The whole padded
composer now accepts a simultaneous tap to focus without replacing native text
selection gestures. The UI journey also waits for the keyboard before typing.
The updated iPad suite passed **9 tests, 0 failures**, with the optional HTTPS
probe skipped (`.build/smoke/20260913-135120-55132493/`).

The Mac grouping fixture injected a synthetic machine that the real gateway
directory poll could remove before its assertion. Polling is now paused only
around that fixture and restored afterward. The failing grouping assertion
passed locally. All **572 Mac tests in 27 suites** and the isolated gateway
package tests passed. Disposable fixture commits also explicitly disable Git
signing so they cannot open the operator's signing agent.

The local core smoke reported **66 passed, 3 failed, 4 diagnostics**: the three
remaining assertions required an active/key window while the host desktop was
locked. The board suite therefore did not run locally; CI must validate those
native focus journeys. The smoke app and its disposable gateway were cleaned up.

## Environment limits

The optional public HTTPS probe did not complete in this Simulator environment.
Both Dieter's gRPC transport and native `URLSession` timed out; a native request
to Apple's website also timed out, while host requests succeeded. This prevents
claiming a verified public-gateway OAuth journey on this host. TLS verification
was preserved and temporary transport diagnostics were removed.

Physical-device installation requires a development team selected in Xcode.
The device build recipe compiles Release without signing. Dedicated iOS GitHub
secrets are now configured and validated; see the
[completed Apple setup](APP_STORE_PREPARATION.md#completed-release-setup).
Actual Apple Distribution signing, App Store Connect upload, processing, and
TestFlight tester availability have not been exercised.
The new release tests use synthetic credentials and mocked Apple operations.
The running operator
Mac app and daemon were preserved; native Mac smoke tests were unavailable
because that operator app was active. Preparation of a separate Mac smoke build
was stopped before launching another Mac app.

The affected-check sequence passed its script, recipe, Swift unit, Simulator
build, and phone stages. Its initial tablet selector failure was corrected and
the full tablet suite passed on the focused rerun. No production code changed
between the passing phone and tablet runs.

## Reproduce

See [setup and commands](README.md). `just check-changed --dry-run` describes the
affected checks; `just check-changed` runs them. The iOS smoke driver uses a
disposable simulator, gateway, enrolled daemon, mock harness, and Git repository.
It exports XCTest results and screenshots under `apps/ios/.build/smoke/` and
shuts down only the resources it created.
