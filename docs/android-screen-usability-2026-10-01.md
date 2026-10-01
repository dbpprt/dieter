# Android screen interaction notes

Research inspected RustDesk at commit
[`fada664df7a294d1d1a9ca3e7cd3637069122f17`](https://github.com/rustdesk/rustdesk/tree/fada664df7a294d1d1a9ca3e7cd3637069122f17).
These are interaction references, not imported code or a transport replacement.

- [`remote_input.dart`, `onTwoFingerScaleUpdate`](https://github.com/rustdesk/rustdesk/blob/fada664df7a294d1d1a9ca3e7cd3637069122f17/flutter/lib/common/widgets/remote_input.dart#L450)
  updates local canvas scale by successive scale ratios and pans by the focal-point delta.
- [`model.dart`, `CanvasModel.updateScale`](https://github.com/rustdesk/rustdesk/blob/fada664df7a294d1d1a9ca3e7cd3637069122f17/flutter/lib/models/model.dart#L2730)
  preserves the desktop point under the gesture. Its mobile viewport code separately
  accounts for keyboard, safe-area and key-help overlays. RustDesk does adjust available
  canvas space; Dieter deliberately preserves its desktop measurement when the IME opens,
  matching the requested behavior. Users can pan obscured content into view.
- [`remote_page.dart`, `getBodyForMobile`](https://github.com/rustdesk/rustdesk/blob/fada664df7a294d1d1a9ca3e7cd3637069122f17/flutter/lib/mobile/pages/remote_page.dart#L657)
  layers video, a quality monitor, key-help tools and a hidden multiline editor.
  Keyboard visibility is observed, and the controls include an explicit Enter key.
- [`input_model.dart`, mobile key handling](https://github.com/rustdesk/rustdesk/blob/fada664df7a294d1d1a9ca3e7cd3637069122f17/flutter/lib/models/input_model.dart#L866)
  calls out Android IMEs supplying unreliable physical HID identifiers for Enter and
  Backspace, particularly for CJK input. Dieter normalizes committed newline/CRLF,
  editor actions, and Android hardware key events into its existing HID operations.

Dieter's screen list and terminal machine picker sort by case-independent name and
stable machine ID. Presence, route latency, selection and incoming directory order do
not participate in sorting. A session starts only on an explicit row tap or retry;
refreshing the machine directory neither reconnects nor changes the selected machine.

The session header has bounded dimensions. Status, codec, FPS and route changes cannot
change the desktop viewport. Keyboard and special keys occupy a separate overlay. IME visibility is distinct from
its bottom inset, so floating keyboards and hardware-keyboard toolbars can also be hidden.
The screen temporarily requests resize-mode inset delivery and restores the previous
window mode when leaving; the edge-to-edge desktop itself ignores IME padding.
Connection details shows the existing signaling route separately from the media route;
no guessed latency or encryption claims are added. Recovery preserves the local zoom and
pan. Fit remains explicit. Zoom controls recompose independently of the desktop, and
unchanged surface dimensions no longer cancel zoom animations. The optional direct
surface path transforms fixed-size video storage instead of relaying out on each pinch.

No RPC, signaling, ICE selection, codec negotiation, session retry policy or data-channel
format changes are included. Terminal selection uses the existing machine terminal scope.

Verification includes common-core key normalization tests, device IME tests, real Android
pinch/button gestures, machine ordering under shuffled and offline updates, a real soft
keyboard show/hide with unchanged desktop geometry, and the authenticated terminal-to-shell
journey. The native screen video/input fixture remains a separate macOS-host qualification;
Linux cannot execute that fixture and must report it as unavailable.

## Verification on 2026-10-01

- `just core test`: 320 tests passed, including the input regression and isolated
  daemon/gateway integration cases. `just core android-test` passed.
- `just android check`: Android JVM tests, lint and debug/E2E/performance APK builds
  passed. Production transport code and schemas are unchanged.
- `tmp/e2e-428879260`: screen capability/picker, input connection and authenticated
  terminal shell cases passed on the visible Pixel_9_API_37_1 (`emulator-5554`).
  Screen navigation also passed in `tmp/e2e-2645171979`.
- The viewport test uses a real, docked `InputMethodService` shipped only in the
  instrumentation APK. It restores the original input method and disables the
  fixture afterward. It asserts unchanged width, height, scale and pan through
  keyboard show/hide, and requires the accessory bar to move above the keyboard.
  Gboard's floating physical-keyboard toolbar was also observed manually; its
  visible state has a zero bottom inset, which is why visibility and height are
  handled independently. The controlled IME avoids changing Gboard preferences
  to make this test reproducible.
- The broader affected functional run (`tmp/e2e-1756564839`) passed 33 of 44 cases.
  Its keyboard case was subsequently fixed and passed in the focused run above.
  Ten failures remain outside the changed flows: navigation folders, tablet
  workspace, conversation creation outbox/preferences, draft queue, task capture
  store/sharesheet, project overview, workspace administration and workspace
  changes. This is not a green repository-wide qualification.
- `just check-changed` passed E2E catalog checks, Android JVM tests, common-core
  tests and core Android integration, then stopped at `just core apple-test`:
  Apple native frameworks/tests cannot be built or run on this Linux host.
  Full screen video/codec/recovery qualification likewise requires a macOS
  capture host; these unavailable tests are not counted as passes.

## Follow-up: zoom changed geometry but left old pixels on screen

The original gesture test checked the canvas model and its transform, but did not
check video pixels. A new renderer test submits one real I420 frame through the
Android EGL renderer, then stops delivering video. Before the fix, the first zoom
out changed the model to 50% while PixelCopy still captured the previous fitted
image (`tmp/e2e-1617533769`). Making the TextureView non-opaque alone did not fix
this (`tmp/e2e-2559153852`).

The video now uses the view layer's scale and translation, instead of
`TextureView.setTransform`. Android's compositor applies these properties on UI
frames, independently of new decoded buffers, and correctly exposes the canvas
background as the image shrinks or moves. Layout/buffer dimensions, input
coordinates, decoding and transport remain unchanged.

`screens.canvas-rendering` samples the actual composited pixels after repeated
zoom in/out, two-finger pinch with pan, and Fit, all without receiving another
video frame. It checks both the displayed image and newly exposed background.
The earlier gesture/keyboard/session tests remain in place. The first fixed
renderer and canvas-controls run passed in `tmp/e2e-4095952655`.
