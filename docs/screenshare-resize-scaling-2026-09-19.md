# Mac screenshare blur during window resizing

The Mac viewer had two avoidable scaling artifacts. `setViewport` rounded the
requested stream up to 160×90-pixel buckets. A settled 832×468 viewport therefore
requested 960×540, requiring the viewer to shrink the encoded image again.
Separately, aspect-fit centering could place an otherwise 1:1 image on a
half-pixel boundary: a 640×360 image in a 641×360 drawable began at x=0.5.
Linear filtering then blended adjacent pixels.

The viewer now requests the settled backing dimensions rounded down to even
codec dimensions, retaining the existing bounds and 350 ms resize debounce.
Metal uses the actual drawable texture dimensions and an integer-pixel viewport.
When even encoder dimensions leave up to two spare pixels near an integer scale,
the renderer preserves that scale instead of slightly stretching the image.
The layer frame is aligned through AppKit's backing-coordinate conversion.
Pointer normalization, cursor placement and cursor hit regions share the rendered
rectangle. Resize still redraws the latest frame while the stream is idle.

This adds no shader pass, frame queue, timer, codec, protocol or host display-mode
change. Linear filtering remains appropriate for genuine scaling. Shrinking a
larger remote desktop, codec compression and chroma subsampling can still soften
text; arbitrary window sizes cannot all preserve source pixels exactly.

Regression coverage includes even stream sizing, 1×/2× backing scale, invalid
dimensions, odd letterboxes, portrait aspect fit and pointer alignment. The
authenticated native viewer fixture settles on 832×468 and checks that its
intermediate resize requests were coalesced. A disposable native window renders
one-pixel stripes through both BGRA and NV12 Metal paths, captures that window,
and measures contrast after resizing without submitting a new frame. It also
places the embedded native view at a quarter-pixel origin.

Validation on the final code:

- Native capture/input checks and `go test -race ./internal/remotedesktop` passed.
- `just mac screens-test`: 32 tests passed, including authenticated H.264/HEVC,
  resize, fullscreen/undocking and pixel alignment. The 832×468 resize reached
  the host and an actually presented decoded frame with one display-generation
  change. The final strengthened assertion passed in
  `native-viewer-presented-final.log`.
- Ten captured BGRA/NV12 cases retained exact black=0 / white=1 contrast,
  including odd window sizes, idle redraw and fractional view placement. These
  captures used a 1× display; 2× geometry is covered by unit tests.
- `just mac test`: 672 tests passed.
- The debug app built and signed successfully using the canonical
  `apps/mac/.build/dieter-local` cache. Tests used `dieter-tests` separately.
- Packaged core, board, machine, terminal, island and workspace smoke suites
  passed. The board accessibility-action
  probe was unavailable to the in-process accessibility bridge.
- The conversation smoke report has three failures outside screensharing:
  `live-tail`, `content-code-line-link` and `content-terminal-input` (110 other
  entries passed). Its export/history probes remain explicitly skipped by that
  fixture. This run does **not** establish a green repository-wide UI suite.
- The sidebar prepare phase also failed `project-actions-on-hover` and
  `project-name-before-host`. Existing conversation/navigation changes in the
  shared worktree were preserved; this task does not establish the cause of
  these separate failures.
- Android screen integration was unavailable: `emulator-5554` was absent. No
  Android source or protocol changed, and no device was started or reset.

Logs and pixel captures are retained at `/tmp/dieter-screen-scaling-20260919`.
`just check-changed --dry-run` selected the validation plan. The initial
`just check-changed` run caught a floating-point
boundary error at exactly two spare pixels, which was corrected and verified by
the native contrast regression. Checks after that failed stage were run directly
against the corrected code. All eight packaged UI suites were attempted; their
reports are summarized in `ui-reports-summary.json` in the evidence directory.
Final lifecycle check found zero `DieterMac` processes; disposable viewers and
smoke apps exited. No operator daemon or app was stopped or restarted.
