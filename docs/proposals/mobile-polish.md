# Mobile polish spike: motion, the chat window, foldables and the desktop shell

Status: approved by the owner on 2026-11-26 from the captures below and shipped as is through
pull request #234 (branch `spike/mobile-ui-polish`). Every change is presentation in `apps/kotlin/ui`:
nothing touches the core, the wire contract or iOS behaviour (iOS keeps its even bubble and its
spinner; the shared structure, such as grouped tool steps, applies there too).

## What the spike changes

### One motion system (`design/Motion.kt`)

A small file every animated surface shares, so motion feels like one material:

- Four named springs (`emphasized`, `quick`, `bouncy`, `settle`) and the transitions built from
  them: `pushTransition` (shared axis: the new page slides in a fifth of the width while it grows
  from 96 %, the old one slides further and fades), `tabTransition` (pages pass each other in tab
  order), `detailTransition` (a detail lifts in beside its list), `modalEnter`/`modalExit` (a
  sheet rising and growing), `popIn`/`popOut` (pills and buttons).
- `Modifier.pressScale` (cards and buttons shrink 2.5 % under a finger; Android gets what iOS
  had), `Modifier.popOnChange` (a selected tab icon or a send button that just became available
  dips and springs back).
- `Modifier.workingGlow`: a soft light travelling along an outline while the agent works.
- `TextStyle.shimmer`, `TypingDots` and `Pulse` for live status.

Where it is used: the single-pane route stack and tab switches (`MobileApp.kt`), the two-pane
detail and the modal creation sheet, the desktop detail panel and modal (`DesktopShell.kt`),
list rows and board cards (`animateItem`), the floating navigation's selected icon, every
`ContentCard`, the composer's send button, empty states (the tile settles in).

### The chat window (`conversation/Timeline.kt`, `ConversationScreen.kt`, `Composer.kt`)

- **Grouped tool steps.** A run of consecutive tool calls is one card with a rail joining the
  steps. Each step shows a glyph for what the tool does (read, search, edit, shell, web, agent,
  git), its title, and its state: a spinner while running, a green check when done, the status in
  red when it failed or waits for approval. One tap still opens the tool's input and output.
- **Thinking.** Reasoning sits behind a "Thinking" disclosure (open by default, so nothing is
  hidden) with a rail; while the turn is live the label shimmers.
- **Activity disclosures** ("Reasoning · 2 file reads · 1 edit · 1 command") are soft chips; the
  one on the running turn pulses.
- **User bubbles** grow a tail toward the sender's edge, a tinted gradient and a soft shadow in
  light mode; unconfirmed messages render dimmed.
- **Live turn.** Typing dots and a shimmering activity line replace the spinner; new rows fade and
  settle into place; the composer card glows while the agent works; the send button eases
  between its states and pops when a draft makes it available.
- **Jump to latest** is a raised pill (glass over the transcript when the glass composer is on)
  that says "New output" while the agent writes.
- **Desktop** uses the floating card composer in the conversation panel (glass stays a touch-only
  choice) and keeps the panel's hairline rim.

### Foldables and tablets (`app/PaneSplit.kt`, `MobileApp.kt`)

Two panes are now two rounded panels on a tinted canvas with a gutter between them, as a large
screen deserves: the canvas keeps the status bar clear, each panel carries its own page, the drag
handle lives in the gutter, and the floating glass navigation floats beneath the list panel. In
dark mode the canvas is deeper than the page and the panels carry a faint rim. Landscape keeps the
side rail in its gutter. The detail panel's content lifts in when something opens and the empty
detail tile settles in.

### Everything else

- Project avatars carry a light (gradient and inner rim); empty-state tiles are gradient tiles.
- Board cards show a tone rail on their leading edge while running, waiting or failed.
- Hidden behind no setting: the polish applies to every navigation and composer style.

## Evidence

Captured on 2026-11-26 from the E2E build on a headless emulator (AOSP API 35) against the
fixture gateway (`-inbox-fixture -showcase-fixture`), plus the offscreen Compose test
`PolishUiTest` for the states the live fixture cannot hold still. Contact sheets live in
`assets/mobile-polish/`; the full-size captures, the before/after sets and two screen
recordings of the motion (`motion-phone.mp4`, `motion-fold.mp4`) are in
`/Volumes/External/dieter-mobile-polish-c_e1ec/evidence/`.

| Sheet                        | What it shows                                                                                                                                               |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `phone-before-after.jpg`     | The live conversation before (main), after, after in dark, and a short conversation with the tailed bubble and the "Move to Review" chip                    |
| `transcript-states.jpg`      | The offscreen fixture: a live turn, then the opened activity with the thinking disclosure and the grouped tool steps (a failed call in red), light and dark |
| `phone-lists.jpg`            | Inbox, a board with tone rails on running cards, chats in dark, a chat                                                                                      |
| `fold-before-after.jpg`      | The unfolded Fold before (one flat window) and after (panels on a canvas), and the board beside a conversation in dark                                      |
| `fold-landscape-desktop.jpg` | Landscape with the side rail in its gutter; the desktop shell's conversation panel with the card composer, light and dark                                   |

Checks run: `:ui:compileKotlinJvm`, the whole `:ui:jvmTest` (every existing UI test plus the three
new `PolishUiTest` cases, green), `:android:assembleE2e`, `just fmt`. Not run: the Maestro device
flows (`just e2e android`), the iOS build, and the Mac app (which does not link `:ui`). The
hand-over build is `~/Desktop/Dieter-mobile-polish-spike-e2e.apk` (installs beside the real app).

## Open questions

1. **Panels on every two-pane window?** The spike panels the two-pane layout whenever the window
   is at least 600 × 480 dp. A list that was dragged away still shows its single pane as an
   inset panel, which keeps the insets stable while dragging; the alternative is full-bleed for
   a lone pane.
2. **Thinking open by default.** Reasoning already hides behind the activity disclosure; the
   spike opens the "Thinking" block inside it by default. Collapsed by default would make long
   turns shorter to scan.
3. **The glow.** It runs while the agent works and the field is not focused. If it reads as
   noise on a long turn, it could run only during the first seconds after a send.
4. **iOS.** The grouped tool steps, thinking disclosure, activity chips and typing indicator
   structure are shared; iOS keeps its bubble shape and spinner. Worth a look on the simulator
   before this ships, which the spike did not do.
5. **Maestro.** No flow selects the pieces that changed shape, but the smoke tags (`composer-chips`,
   `message-input`, `send-message`, `move-review`, `conversation-timeline`) are unchanged. Run
   `just e2e android tags:smoke` on the 320 × 640 CI size before merging.
