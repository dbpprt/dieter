# macOS Liquid Glass refactor: analysis and plan

Target: [`liquid-glass-target.png`](liquid-glass-target.png) (2644×1640 px, a 2× capture
of a window about 1322×820 pt). All `file:line` references are relative to
`apps/mac/Sources/DieterMac/` and reflect `codex/integrated-macos-privacy` at `c01c5d23`.

## 0. Scope

**In scope**

- **Shell:** window title band, the sidebar and all navigation, overlays, toasts,
  popovers, menus and the command palette.
- **Board:** top bar, lanes, cards and the conversation inspector.
- **Conversation pane:** the floating panel, header, tab control, transcript chrome,
  activity groups, user bubbles, banners and the workspace column chrome. This applies
  in every host: Board, Chats and Inbox.
- **Consistency pass on the remaining sections:** Chats and Inbox lists, Files, Changes,
  Schedules, Terminals, Screens, Archive and Settings, so nothing is left in the old style.

**Explicitly out of scope (your constraints)**

- **Composer:** the text input, the model selector, and the provider/settings controls.
  These files must not change:
  - `Features/Conversation/ConversationComposer.swift`
  - `Features/Conversation/ComposerControls.swift` (`ComposerSurface`, `AgentComposerMenus`,
    `ComposerProviderOptions`, `ComposerSendButton`)
  - `Features/Conversation/ConversationContextUsage.swift`
  - the option chips in `Features/Forms/HarnessFields.swift`
  - the composer's attachment strip in `UI/Attachments.swift`

  The composer also uses shared primitives: `DieterChipLabel`, `DieterIconButtonStyle`,
  `DieterTheme.raised`/`.elevated` and `dieterGlass`. Their current look stays frozen
  (see §4.4).

- **The "model details" grid** (Harness, Model, Effort, Machine, Branch, Worktree, Diff,
  Tool calls, Runtime, Usage). It doesn't exist today and won't be built.

**Out of scope because data is missing.** These need core, daemon or API work; see §6.

- card keys like `DTR-79`
- per-card and per-lane cost
- tool-call counts
- turn and step durations ("2m 14s", "4.2s")
- the Approve/Deny permission bar
- question text on cards

The new layouts leave room for these. No placeholder values ship.

---

## 1. The target design language

The screenshot uses four layers.

| Layer                  | What sits on it                                                                                      | Material                                                                                      | Shape                                                                                                                        |
| ---------------------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **L0 Canvas**          | Window background. Board lanes, list panes and section content sit directly on it.                   | The existing single behind-window blur (`DieterWindowBackdropView`), with a dark neutral tint | Full window                                                                                                                  |
| **L1 Floating panels** | Sidebar card, conversation inspector, machine popover, connection overlay, toasts                    | Real system glass with a 1 px rim highlight                                                   | Continuous corners, about 16 pt (sidebar) and 18 pt (inspector), inset about 10 pt from the window edges and from each other |
| **L2 Tiles**           | Board cards, list rows, the selected nav row, the machines inset, expanded tool panels, user bubbles | "Glass-lite": a translucent fill plus a hairline rim. No backdrop sampling.                   | 10 pt (cards), 8 pt (rows), 16 pt (bubbles)                                                                                  |
| **L3 Controls**        | Top-bar capsules, segmented tracks, search, icon groups, circular buttons, the primary action        | Native `.glass` / `.glassProminent`, grouped in `GlassEffectContainer`                        | Capsules and circles                                                                                                         |

**Color semantics.** These colors are fixed. Today they come from the palette, and
`primary` and `eyes` are gray in Monochrome.

| Meaning                                  | Color                 |
| ---------------------------------------- | --------------------- |
| Running dot, additions, ✓, progress line | Green (`systemGreen`) |
| Deletions, failure                       | Red/coral             |
| Needs you, warnings, callouts            | Amber                 |
| Primary action (New Task)                | Blue (accent)         |

Everything else is neutral gray. The palette only tints glass and selection, and adds
brand accents.

**Typography**

- **SF Pro** for all chrome: titles at 13–15 semibold, body at 13, meta at 11–12.
- **SF Mono** for card refs, branches, diff stats, costs, durations and latency.
- Section labels are sentence case ("Projects"), not uppercase. Counts are in tertiary.
- The current chrome uses Sora (`DieterFont.paneTitle/title/sectionLabel/control`).

**Approximate metrics** (pt, measured at 2×). Tune them against the reference during
implementation.

| Element           | Value                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| Title band        | about 56 pt tall. Capsules about 32 pt tall, vertically centered on the traffic lights at y ≈ 28 |
| Sidebar card      | about 220 wide, 10 pt inset from the window, about 16 pt radius                                  |
| Sidebar rows      | about 29 tall                                                                                    |
| Project tab tiles | 4 across, about 40 tall                                                                          |
| Lanes             | about 220 wide with a 15 pt gap. Header centered at about y 67.                                  |
| Cards             | 10 pt padding, 9 pt vertical gap                                                                 |
| Inspector         | about 360 wide. Top is just below the title band; 10 pt right and bottom margins.                |
| Segmented track   | about 28 tall, full panel width                                                                  |
| Machines inset    | about 17 pt rows, 10 pt radius                                                                   |

Starting color values for dark glass:

| Use               | Value                                   |
| ----------------- | --------------------------------------- |
| Canvas            | about #1B1C20                           |
| Panel glass       | Visually about #2A2B30                  |
| Card fill         | White at 4–5%                           |
| Card rim          | White at 8–10%                          |
| Selected card rim | White at about 22%                      |
| Selected segment  | White at about 14%                      |
| Text              | #F2F2F5 / about #A0A0A8 / about #6E6E76 |

---

## 2. Current state analysis

### 2.1 Theme and glass foundation

- **Theme files.** `UI/DieterTheme.swift` holds 8 palettes × light/dark tokens. When
  transparency is on, `UI/DieterTheme.swift:375-380` fades the tokens: `surface` 0.12,
  `raised` 0.38, `elevated` 0.55, `input` 0.25, and `background`/`sidebar` become
  `.clear`.
- **Single-backdrop rule.** One `NSVisualEffectView` backdrop sits behind the whole
  window (`UI/DieterTransparency.swift:63-181`). The stated rule (`DieterTheme.swift:373`)
  is to never stack materials.
- **Glass helpers.**
  - `dieterGlass` (`DieterTransparency.swift:185`) applies glass or an opaque fallback
    without changing view identity.
  - `DieterGlassButtonStyle` (`:191`).
  - `dieterToastChrome` / `dieterOverlayChrome` (`:212-291`).
- **Glass is sparse.**
  - `dieterGlass` is used about 7 times: command palette, quick help, capture window,
    search field, composer, working indicator, jump-to-latest.
  - `DieterGlassButtonStyle` is used in a few headers and sheets.
  - There is **no** `GlassEffectContainer` anywhere.
- **Modes.** Solid mode and Reduce Transparency are routed through
  `DieterTheme.usesTransparency`. In solid mode the window, root, sidebar and content are
  all `opaqueSurface`, so a floating card would currently disappear.

### 2.2 Shell (`UI/DieterRootView.swift`, `UI/WorkspaceSplit.swift`)

- **Window.** A single SwiftUI `Window("Dieter")` with `.windowStyle(.automatic)`
  (`DieterMacApp.swift:33-128`).
- **Split.** `WorkspaceSplitController` is an `NSSplitViewController` with two regular
  items and a `.thin` system divider (`WorkspaceSplit.swift:42-70`). It deliberately avoids
  `NavigationSplitView` and the sidebar behavior.
- **The title band is inconsistent.**
  - Inbox, Board, Chats, Files and Changes hide the window toolbar and draw headers in the
    band (`DieterRootView.swift:44-46`).
  - Terminals, Screens, Schedules, Archive and Settings show a toolbar with a sidebar
    toggle and Quick Task (`:171-191`).
  - So the titlebar height changes from section to section.
- **Traffic lights are custom-drawn** (`UI/DieterWindowTrafficLights.swift`). SwiftUI
  removes the standard buttons when it hides the toolbar.
  - They show only in Inbox, Board and Chats (`:400-406`). Other sections show a brand
    header instead.
  - They disappear when the sidebar collapses.
  - They have no hover glyphs, no inactive (gray) state and no Option-click.
- **Sidebar** (`AppSidebar`, `:385-738`) is a flat full-height column, from top to
  bottom:
  1. Traffic lights or brand header
  2. A ⌘K search launcher
  3. Inbox, All chats, Terminals and Screens rows (`SidebarDestination`, `:1412-1456`,
     selection fill at radius 5)
  4. An uppercase "PROJECTS" header
  5. Project rows with initials avatars and hover gear/plus
  6. Expanded projects showing a **vertical** list: one row per board, then Files,
     Changes, Schedules (`:1161-1234`)
  7. Filled folder boxes
  8. A "MACHINES" card and a "QUOTAS" card
  9. A Settings row and an "Add a Git project" footer

  The sidebar has no per-project activity, no project-level active cards and no legend.

- **Overlays.**
  - `MachinePopover` is a custom overlay. Its x-offset is computed from the sidebar width
    (`:218-241`).
  - Toasts sit at the top trailing corner (`:242-246`), where they will collide with
    top-bar capsules.
  - `ConnectionOverlay` is an opaque card.
  - `WorkspaceFreshnessBanner` is a full-width strip. Its timestamp capsule is invisible
    in glass mode.
- **Menus.**
  - These are native and stay native: `.contextMenu`, `Menu` and raw `NSMenu`. macOS 26
    already renders them as glass.
  - Some popovers paint over the system glass: `ProjectQuickNav` uses `.background(surface)`
    (`:1312`), and `QuickTaskPopover` uses `.quaternary` fills.

### 2.3 Board (`UI/BoardView.swift`, `BoardChrome.swift`, `KanbanView.swift`, `BoardCardView.swift`, `BoardConversationOverlay.swift`)

- **Header.** `FluidPaneChrome` holds the board name, a summary line and a row of
  `.bordered` buttons.
  - There is **no board picker**; boards are switched from the sidebar.
  - There is no search field, although `store.query` is already wired to the core
    (`CoreSession.swift:265-272`).
  - There is no layout button.
  - Label chips are `.draggable` onto cards (`BoardChrome.swift:327-329`).
  - "Quick task" is `.borderedProminent` (`board.quick-task`).
- **Lanes** (`KanbanView.swift:59-128`):
  - Each lane is a panel at radius 8. With glass on, only its border shows.
  - Header: a tint dot, name and plain count, then a sort toggle (test IDs) and a
    borderless "+". The "+" doesn't pass the lane.
  - `BoardPolicies` 14/9/264 is pinned by unit tests.
- **Lane lists.** Each lane is a native `NSTableView` (`BoardLaneList.swift`). The
  board-stress smoke requires exactly 4 tables, no reloads and fewer than 40 mounted rows.
- **Cards** (`BoardCardView.swift:245-420`):
  - Radius 7 with palette fills.
  - Contents: a 3-line title with a status dot on the **right**, a 3-line summary, label
    capsules, and a footer of runtime `StatusPill`, machine capsule, age and subagent
    count.
  - Not shown on the card today, although the data exists:
    - harness·model (only in the tooltip)
    - branch (only in the tooltip)
    - diff stats: `card.workspace.additions/deletions/changedFiles` exist and are unused
- **Inspector.** `BoardConversationSplitController` is a mirrored native split. The
  conversation is item 0 on the right, with `.default` behavior (unit-tested).
  - It sits beside the board header, not below it.
  - Its 40 pt titlebar rail holds the Kanban toggle, tabs, "+", split and close.
  - The board pane stacks `DieterTheme.surface` three times (`BoardView.swift:31,49,64`).

### 2.4 Conversation pane (`Features/Conversation/*`)

- **Structure.** All hosts go through `ConversationPaneOwnedSplit`. That is a chat column
  plus a workspace column, each with a fixed 40 pt `ConversationPaneTitlebar`
  (`surface` fill and a bottom `Divider`, `:332-342`).
- **Tabs.**
  - The live tab bar is `ConversationWorkspaceTabBar` (`ConversationContentPane.swift:168-315`)
    inside the rail. It holds Conversation, Changes n, Subagents n and the dynamic
    file/terminal/browser/process/review tabs, using three different label styles.
  - The underline `ConversationTabBar` (`ConversationChrome.swift:312-342`) is dormant
    in production, because `conversationWorkspaceTabsInTitlebar` is always true.
- **Header.**
  - Title at 15 semibold.
  - `ConversationModelIdentityLabel` ("Last reply model · …", `:167-197`).
  - A `StatusPill` with the core wording "Waiting for you".
  - A borderless "…" menu.
  - Chats has no actions menu at all.
- **Transcript** (an eager `VStack`; scroll is owned by `ConversationScrollController`):
  - Assistant text is already plain.
  - User bubble: `userMessageBackground` at radius 14 with a `strongBorder` stroke
    (`ConversationTimelineRows.swift:168-225`).
  - Activity disclosure: a chevron plus the core summary (`ConversationActivityDisclosure.swift`).
    When expanded, each `ToolCallView` draws **its own** `surface` card at radius 8
    (`MessageParts.swift:144`) and there is no shared inset panel.
  - The ✓ uses `eyes`, which is gray in Monochrome.
- **Approvals.** There is no Approve/Deny UI and no API for it. Only the amber "needs
  approval" status label on tool steps exists.

### 2.5 Tests that encode today's structure

These must be updated deliberately; the full list is in §5.

- **No system glass on the sidebar.** `WorkspaceChromeTests` forbids `NSGlassEffectView`
  as an _ancestor_ of `sidebarHost`. A SwiftUI glass card _inside_ the host is fine.
- **Sidebar and chats touch.** `SidebarNavigationUISmokeRunner` "navigation-boundaries"
  requires the chats browser to touch `sidebar.main-pane` within 1.5 pt.
- **Rail positions.** `ConversationPaneFeatureSmoke:672-689` requires `conversation.status`
  and `conversation-tab-kanban` in the chat pane's top 40 pt, and the fixed tabs 6–80 pt
  from the workspace pane's leading edge.
- **Inspector structure.** `BoardConversationOverlayTests` pins `behavior == .default`,
  the board host filling its frame, and widths of 460/480/560.
- **Fixed sizes and contrast.**
  - `LiquidGlassLayoutTests` pins the 38 pt working indicator and the header's stable
    height.
  - `MessageFooterTests` pins 24 pt.
  - `DieterThemeTests` requires user-bubble contrast of at least 7:1.

### 2.6 Data available vs missing

| Target element                                                                                                                          | Status                                                      |
| --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Branch, diff stats, harness·model, labels, machine, running/waiting/failed tone, age                                                    | **Available**                                               |
| Activity rows per card (`ActivityRow`: kind, needs_you, project, title, shown_at)                                                       | **Available**; can drive the sidebar's per-project activity |
| Card key `DTR-79`, card cost, lane cost, tool-call count, step durations, approval text, question text, progress fraction, Approve/Deny | **Missing** (§6)                                            |

---

## 3. Architecture decisions

**D1. The floating sidebar is a SwiftUI glass card inside the existing
`WorkspaceSplitController`. It does not use the native sidebar split item.**

- The native `NSSplitViewItem(sidebarWithViewController:)` glass samples whatever content
  extends beneath it. Its tint would shift as sections change, which is exactly why
  `WorkspaceChromeTests` forbids it.
- A card drawn inside `sidebarHost` samples only the static window backdrop, so its tint
  stays stable. It also keeps resizing, collapse, persisted width, `sidebar.main-pane`
  adjacency and full control over the inset, radius and traffic lights.
- The divider becomes invisible (`dividerColor = .clear`). Its hit area widens through
  `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)`, so dragging happens in the gap
  between the panels.

**D2. One title band in every section.**

- Hide the window toolbar everywhere. `usesPaneTitlebar` becomes constant and is deleted.
- Each section draws a floating capsule top bar in the band, centered on the traffic
  lights.
- The sidebar toggle moves to a View ▸ Toggle Sidebar command (⌃⌘S, available everywhere)
  and to a circular glass button in the sidebar card's top band.
- When the sidebar is collapsed, a compact glass capsule at the top leading edge holds the
  traffic lights and a show-sidebar button. Top bars shift right by a
  `titleBandLeadingInset` environment value.

**D3. Keep owned traffic lights, but make them match the system.**

- Add hover glyphs, the gray inactive-window state, Option-click zoom and correct
  accessibility.
- Draw them inside the sidebar card in every section.
- Hiding the toolbar removes the standard buttons. Moving the system ones is fragile.

**D4. Material budget.**

- Real glass is used **only** for L1 panels (2–4 on screen) and L3 controls, with one
  `GlassEffectContainer` per bar.
- Never use glass inside lists: board cards (native tables, stress-gated), transcript rows
  (eager), sidebar rows or chat/inbox rows. Those use L2 glass-lite tiles.
- This keeps the existing single-backdrop rule for content.

**D5. The board top bar spans the full width; the inspector is a panel below it.**

- `BoardView` becomes `VStack { BoardTopBar; BoardConversationOverlay }`.
- The split stays native, with `.default` behavior.
- The conversation item hosts the existing `ConversationPaneOwnedSplit` inside a
  `DieterPanelView`: an AppKit `NSGlassEffectView` with `cornerRadius` and a solid
  fallback. The panel has 10 pt margins and an invisible divider.
- Chats and Inbox use the same panel, so all three hosts look identical.

**D6. One conversation header layout replaces the 40 pt rail and `ConversationChrome`.**

- **Row 1 (40 pt):** status dot, title, status capsule (core wording), then circular glass
  buttons: workspace split, "…", close.
- **Row 2:** a breadcrumb.
- **Row 3:** one scrollable glass segmented track:
  `Conversation | Changes n | Subagents n │ <workspace tabs> │ +`.
- The Kanban toggle moves to the board top bar's layout button.
- In split mode, the workspace column gets its own track, so the fixed tabs stay inside
  the workspace pane as they do today.
- Delete these (clean break):
  - `conversationWorkspaceTabsInTitlebar`
  - `ConversationChromeLayout`
  - the dormant `ConversationTabBar`
  - the three rail label styles
  - `ConversationPaneSurfaceBar` / `ConversationPaneWorkspaceBar`
- Also delete the test-only `ConversationContentSplit` path once its callers are checked.

**D7. Typography and semantic colors.**

- `DieterFont` switches to SF Pro and SF Mono. Sora remains only in brand marks.
- New fixed status tokens: `running` (systemGreen), `attention` (amber), `failed` (coral),
  `action` (accent blue).
- `toneColor(.active)` becomes green.

**D8. Menus and popovers stay native.**

- Remove custom fills that paint over the popover glass (`ProjectQuickNav`, the
  QuickTask `.quaternary` blocks).
- Menu triggers inside bars become glass buttons.
- Custom overlays move to the L1 panel primitive: machine popover, connection overlay,
  toasts, freshness notice and command palette.

---

## 4. Design system (Phase 1 deliverable)

### 4.1 Tokens: new `UI/DieterGlassTokens.swift`

Tokens are defined by role, not by palette slot. Each token resolves for
{glass, solid} × {dark, light} × palette. Glass mode applies to the token values only;
it never switches views with `if/else`, so view identity is preserved.

| Token                                                   | Glass dark                                                                  | Glass light                  | Solid dark                           | Solid light               |
| ------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------- | ------------------------------------ | ------------------------- |
| `canvasTint`                                            | palette `darkBrand` 10% over the backdrop                                   | palette `light` 6%           | `darkBackground`                     | `light`                   |
| `panel` (glass tint)                                    | `.regular.tint(darkBrand 35%)`                                              | `.regular.tint(white 30%)`   | `darkRaised`                         | `lightSurface`            |
| `panelRim`                                              | gradient, white 12% → 4%                                                    | black 8%                     | white 8%                             | black 8%                  |
| `tile` / `tileHover` / `tileSelected`                   | white 4.5% / 7% / 10%                                                       | white 55% / 70% / 85%        | `darkSurface` / mix / `darkElevated` | white / mix / `paneStart` |
| `tileRim` / `tileRimSelected`                           | white 8% / 22%                                                              | black 7% / accent 35%        | `border` / `strongBorder`            | same                      |
| `inset` (machines, expanded tools)                      | black 22%                                                                   | black 4%                     | `darkInput`                          | `lightRaised`             |
| `segmentThumb`                                          | white 14%                                                                   | white 90% plus a 1 pt shadow | `darkElevated`                       | white                     |
| `hairline`                                              | white 8%                                                                    | black 8%                     | `border`                             | `border`                  |
| `text` / `secondary` / `tertiary`                       | existing `text` / `subtle` / `tertiary`, re-checked for contrast on `panel` | same                         | same                                 | same                      |
| `status.running` / `.attention` / `.failed` / `.action` | systemGreen / amber / coral / accent                                        | same                         | same                                 | same                      |
| `diffAdd` / `diffDel`                                   | existing `diffAddition` / coral                                             | same                         | same                                 | same                      |

The fade-on-transparency behavior of `surface`/`raised`/`elevated`/`input`
(`DieterTheme.swift:375-380`) is removed once its last non-composer caller migrates.
See §4.4 for the composer.

### 4.2 Metrics and type: extend `DieterMetrics` / `DieterFont`

**Metrics:**

| Name                | Value |
| ------------------- | ----- |
| `windowInset`       | 10    |
| `panelGap`          | 10    |
| `sidebarCardRadius` | 16    |
| `panelRadius`       | 18    |
| `tileRadius`        | 10    |
| `rowRadius`         | 8     |
| `bubbleRadius`      | 16    |
| `titleBandHeight`   | 56    |
| `capsuleHeight`     | 32    |
| `segmentHeight`     | 28    |
| `rowHeight`         | 29    |

**Fonts:** `DieterFont.title` / `.paneTitle` / `.body` / `.meta` move to SF. Add
`DieterFont.mono` (SF Mono 11) and `.monoSmall` (10).

### 4.3 Primitives: new `UI/DieterGlassComponents.swift`

| Primitive                                                                    | Purpose                    | Implementation notes                                                                                                                                                                                                                           |
| ---------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.dieterPanel(radius:)` / `DieterPanelView` (AppKit)                         | L1 panels                  | `glassEffect(.regular.tint(...), in: RoundedRectangle(.continuous))` plus `panelRim`. In solid mode: the `panel` fill, rim and a soft shadow. AppKit twin: `NSGlassEffectView` with `cornerRadius`, swapped to a layer-backed view when solid. |
| `.dieterTile(_ state:)`                                                      | L2 cards and rows          | `rest`/`hover`/`selected`/`targeted`/`pending`. Fill plus rim. No backdrop sampling. Decoration only, so identity is stable.                                                                                                                   |
| `.dieterInset(radius:)`                                                      | Darker wells               | Machines footer, expanded tool lists, code blocks                                                                                                                                                                                              |
| `DieterGlassBar { }`                                                         | Top bars                   | `GlassEffectContainer(spacing: 8)` around an `HStack` of groups                                                                                                                                                                                |
| `DieterCapsuleGroup`                                                         | Joined capsules            | One glass capsule holding several borderless items with a selection thumb                                                                                                                                                                      |
| `DieterSegmentedControl<ID>`                                                 | Tabs and filters           | Items carry an optional count, symbol, close action, dirty dot and drag payload. The thumb uses `matchedGeometryEffect` inside the container. Scrollable overflow. Accessibility identifiers per item. Replaces 5 tab or picker styles.        |
| `DieterCircleButton`                                                         | Icon actions               | `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)`                                                                                                                                                                                         |
| `DieterPrimaryCapsuleButton`                                                 | "+ New Task"               | `.glassProminent` tinted `status.action`                                                                                                                                                                                                       |
| `DieterSearchCapsule`                                                        | Search / palette launcher  | Evolves `DieterSearchField`; shows a shortcut hint                                                                                                                                                                                             |
| `DieterCountBadge`, `DieterStatusDot`, `DieterStatusCapsule`                 | Counts and tone            | The status capsule shows the core's wording ("Waiting for you") and is never hard-coded                                                                                                                                                        |
| `DieterCallout(tone:)`                                                       | Amber or red inline blocks | Waiting state on cards; approvals later                                                                                                                                                                                                        |
| `DieterNavRow`                                                               | Sidebar and list rows      | Symbol, title, trailing count or dot, `dieterTile(.selected)` thumb                                                                                                                                                                            |
| `DieterSectionHeader`                                                        | "Projects" and similar     | Sentence case, tertiary, trailing accessory                                                                                                                                                                                                    |
| `DieterDiffStat`, `DieterBranchLabel`, `DieterHarnessChip`, `DieterMetaText` | Card and footer metadata   | Mono, semantic colors                                                                                                                                                                                                                          |

### 4.4 Composer freeze

These must keep their **current** visuals because the composer uses them:

- `DieterChipLabel` (2 composer uses)
- `DieterIconButtonStyle` (1)
- `DieterTheme.raised` / `.elevated` (1 each)
- `dieterGlass`, as used by `ComposerSurface`

Every other caller migrates to the new primitives. These symbols then remain only as
composer dependencies, with a comment stating that, and their values are unchanged. The
composer files are not edited. `StandaloneChatStartView` reuses the composer pieces and is
left as it is.

---

## 5. Implementation phases

The work is staged so each phase compiles. Following the repo's practice, focused unit
tests run per phase and the slow native suites run once at the end.

### Phase 0: Baseline (small)

- Capture "before" evidence:
  - `DIETER_CHROME_EVIDENCE=<dir>` with `WorkspaceChromeTests` (every section, glass and
    solid)
  - the board-stress smoke (idle CPU, mounted rows)
  - the conversation smoke screenshots
  - dark and light
- Record the chat-list and transcript performance numbers as the baseline for §7.

### Phase 1: Design system (medium)

- Add the token, metric, font and primitive files (§4).
- Unit tests:
  - token contrast per palette × scheme × mode: text ≥ 7:1 on `panel` and `tile`;
    `tertiary` ≥ 4.5:1 on `panel`
  - in solid mode, `panel` must differ from canvas
  - primitives must keep view identity when transparency toggles
  - `DieterSegmentedControl` keyboard and accessibility behavior

### Phase 2: Shell (large)

1. **Title band (D2).**
   - Delete the `.toolbar` block and `usesPaneTitlebar` (`DieterRootView.swift:44-46,171-191`).
   - Make `DieterWindowBackdrop.paneTitlebarEnabled` permanent and drop the parameter.
   - Add View ▸ Toggle Sidebar (⌃⌘S) through a `CommandGroup`. This requires lifting
     `sidebarVisibility` into the store or a `FocusedValue`.
   - Make `WindowTitleBarDoubleClickHandler` independent of whether the standard zoom
     button is visible, and fix its stale comment.
2. **Sidebar card (D1).**
   - Wrap `AppSidebar` in `.padding(windowInset)` plus `.dieterPanel(radius: 16)`.
   - Keep `sidebar.main-pane` on the full-bleed host.
   - Make the divider invisible with a widened hit area.
   - Re-tune `SidebarSizing` so the card is about 220 pt inside the host.
3. **Sidebar content**, from top to bottom:
   - **Top band:** traffic lights (D3, every section) and a trailing sidebar-toggle circle.
     Delete the brand header and the search launcher; ⌘K moves to the top bars.
   - **Primary nav:** `DieterNavRow` for Inbox (amber dot plus count), Chats, Terminals
     and Screens. Keep the IDs `sidebar.inbox|all-chats|terminals|screens`.
   - **"Projects" header** with a running/waiting legend. The hover-only add and folder
     buttons keep `sidebar.project-folder.new`; the `+` gets an ID.
   - **Project row:**
     - name, a per-project activity strip (running/waiting/review/idle segments) and the
       card count
     - avatars are removed
     - selection uses the `tileSelected` thumb
     - the expand toggle and IDs are kept
     - the activity grouping is a **core rule** over the existing `ActivityRow`s (a small
       `SharedRules` addition), not a Swift computation
   - **Selected project:**
     - A 4-tile icon strip: Board, Files, Changes, Schedules (`DieterSegmentedControl`,
       icon-over-label variant). New IDs: `sidebar.project.<pid>.tab.board|files|changes|schedules`.
       This replaces the per-board rows; multi-board switching moves to the board picker
       capsule (Phase 3). For a boardless project, Board opens the empty state with
       "Create board".
     - Below the strip, the project's active conversations (status dot, title, mono age),
       capped at about 8, with a "Show all" link to Inbox filtered by the project.
   - **Folders:** a flat disclosure header instead of a filled box.
   - **Footer inset (`dieterInset`):**
     - machines: green or gray dot, name, mono latency or "offline"; still opens the
       machine popover
     - a compact quotas row that keeps the `sidebar.quota.*` IDs
     - a gear button that keeps `sidebar.settings`
     - "Add a Git project" is deleted; it duplicated the header `+`
   - **Delete:** `ProjectQuickNav` (replaced by the strip), `SidebarFooterButton`,
     `ProjectAvatar`, `SidebarProjectDestinations` and their unused compact parameters.
4. **Collapsed sidebar:** the top-leading glass capsule (traffic lights plus
   `workspace.sidebar.show`) replaces the 38 pt bottom-left button.
5. **Overlays:**
   - `MachinePopover` uses `dieterPanel`. Anchor it to the sidebar card frame through a
     preference key instead of `sidebarWidth` arithmetic, with a lighter scrim.
   - Toasts use the panel style and are placed below the title band.
   - `ConnectionOverlay` uses a panel.
   - The freshness notice becomes a glass capsule under the top bar.
   - In the command palette, selection uses `tileSelected`.
   - In the QuickTask popover, the `.quaternary` blocks become tiles.
6. **Other windows:**
   - The menu-bar extra's inner cards become tiles.
   - The capture window gets `.dieterThemeRoot` and a panel.

### Phase 3: Board (large)

1. **Structure (D5).**
   - `BoardView` becomes `VStack { BoardTopBar; BoardConversationOverlay }`.
   - Remove the three stacked `surface` fills.
   - Delete the unused `usesTitlebarSpace` plumbing (about 10 structs).
2. **`BoardTopBar`** (one `GlassEffectContainer`):
   - **Board picker capsule "Main 75":** a `Menu` listing the project's boards, plus
     New board, Rename and Board settings. Keep `board.settings` reachable; the smoke
     test path changes.
   - **Filter track: All · #label… · Needs you.**
     - Uses `DieterSegmentedControl`.
     - Label segments stay `.draggable` onto cards.
     - "Needs you" sets `stateFilter = .waiting`.
     - Overflowing labels scroll inside the track.
   - **"Search ⌘K" capsule:** launches the command palette. This replaces the sidebar
     launcher and is the same capsule in every section.
   - **Icon group:**
     - Filters menu: state plus machine
     - Labels sheet
     - Layout, which toggles the Kanban/inspector and replaces `conversation-tab-kanban`
       with `board.layout-toggle`
   - **"+ New Task":** prominent; keeps `board.quick-task` and its popover.
   - **Conditional amber capsules** for shared conflicts and retirement-blocked notes.
   - The summary line is dropped. The counts live in the picker and filter track.
3. **Lanes:**
   - No panel fill or border.
   - Header: title (SF 13 semibold), `DieterCountBadge`, spacer, a cost slot (empty until
     §6), the sort toggle (still visible, keeps its `lane-sort.*` IDs) and a circular
     glass "+". The "+" now opens New card **with that lane preset**.
   - While dragging, a dashed `tileRim` outline appears only on the targeted lane. Keep a
     `contentShape(Rectangle())` so the whole column remains a drop target.
   - Empty lanes keep a subtle dashed outline.
   - Re-tune the `BoardPolicies` minimum lane width (264 → about 232) and update its
     pinned test.
4. **Card** (`dieterTile`, radius 10; each new element is its own observing subview,
   following the existing `BoardCardMachineBadge` pattern):

   | Row     | Contents                                                                                                                                     |
   | ------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
   | 1       | Leading status dot (only when running or waiting), title (2 lines), and a trailing mono ref slot (empty until §6)                            |
   | 2       | Brief, 2 lines, secondary                                                                                                                    |
   | 3       | `DieterHarnessChip` ("Codex · gpt-6.1-sol", from `provider`/`model` plus machine metadata), labels as colored `#text`, machine name trailing |
   | 4       | `DieterBranchLabel` (branch glyph plus mono branch), or the core's "not started" state                                                       |
   | 5       | Mono footer: `+add −del Nf` (semantic colors) leading; age trailing, driven by one shared minute clock instead of a timer per card           |
   | Running | A 2 pt static green line along the bottom edge (any animation must be Core Animation only)                                                   |
   | Waiting | A `DieterCallout(.attention)` with the core's waiting text. It shows the question or approval text once §6 lands.                            |
   - **Selected:** `tileRimSelected`.
   - **Overlays restyled with tokens:** merge-ready, merged link, label drop, pending
     outbox and the hover run button (as a circular glass button).
   - **Removed:** the runtime `StatusPill` and the separate subagent count (shown in the
     mono footer as "3 agents" when greater than 0).
   - Card height must still equal the measured content
     (`BoardLaneListLayoutTests:422-447`).

5. **Inspector panel:**
   - The conversation item content is inset by `panelGap` (leading), `windowInset`
     (trailing and bottom) and 0 (top, since it sits below the top bar).
   - The panel is a `DieterPanelView`.
   - The divider is invisible and is dragged in the gap.
   - The default width is re-tuned (about 380–420) and the overlay tests' width constants
     are updated.
6. **Archive view and board sheets:** tokens only. Sheets stay native.

### Phase 4: Conversation pane (large)

1. **The panel is the same in all hosts.**
   - Board: Phase 3.5.
   - Chats and Inbox: the list pane sits on the canvas, and the conversation is a floating
     panel on the right.
   - Delete `ConversationView`'s `surfaceStyle` canvas/inherited split.
2. **Header (D6).**
   - **Row 1:** `DieterStatusDot`, title (SF 15 semibold, tail truncation),
     `DieterStatusCapsule` (core wording, amber on attention), spacer, then
     `DieterCircleButton`s:
     - workspace split (`conversation.content.close`)
     - "…" with Fork, Halt and Archive (now in Chats too)
     - close (`board.conversation-close`; `board.conversation-maximize` stays absent)
   - **Row 2:** a tertiary breadcrumb. Board: `project › board › ref`. Chats:
     `project › Chat`. The ref is a short ID until §6 adds keys.
   - **Removed:** `ConversationModelIdentityLabel`. It's a model detail, and the composer
     already shows the selected model.
   - Keep `conversation.status`. The header height must stay stable for long titles
     (`LiquidGlassLayoutTests:62-92`).
3. **Segmented track.** One `DieterSegmentedControl` in a `GlassEffectContainer`:
   - Conversation, Changes (count), Subagents (count), then a separator, then the
     workspace tabs (file, terminal, browser, processes, review; close on hover, dirty
     dot), then "+".
   - Horizontally scrollable, auto-revealing the selection (keep "content-tab-scroll-to-reveal").
   - Keep these IDs: `conversation-tab-conversation`,
     `conversation.content.fixed.changes|subagents`, `conversation.content.tab.<id>(.close)`,
     `conversation.content.add`.
   - In split mode the workspace column has its own track, so the fixed tabs stay in the
     workspace pane.
   - Delete everything listed in D6.
4. **Transcript** (styling only).
   - **Rules:**
     - The header stays above the `ScrollView`.
     - No top `safeAreaInset`.
     - No `LazyVStack`.
     - No `scrollPosition`, `onScrollGeometryChange` or `ScrollViewReader`.
     - No glass rows.
     - No `glassEffectID` in the transcript.
     - Decorations change through modifiers, never through `if/else` (to keep the
       `MessageTextView` identity and selection).
   - **User message:** a right-aligned `dieterTile` bubble at radius 16, which reads as a
     capsule on single-line messages. It must keep ≥ 7:1 contrast.
   - **Activity group:**
     - Label: a tertiary chevron, the core summary, and a trailing duration slot (empty
       until §6).
     - Expanded: **one** `dieterInset` panel at radius 10, listing the steps as compact
       rows:
       - status glyph: ✓ `status.running` green, ⚠ amber, ✕ coral, or a spinner
       - mono title
       - trailing status or duration
     - Remove the per-step `surface` cards (`MessageParts.swift:144`).
     - Expanding a step's input and output nests inside the inset.
     - Keep the `conversation.activity.<id>.*` IDs and the "content height > 30" behavior.
   - **Tiles and tokens:** plans, subagent groups and cards, pending tools, failure
     banners (coral-tinted tile), creation failure, the empty-state prompt and the queued
     message tray. The tray's styling lives in `QuickTaskQueue.swift`, outside the composer.
   - **Unchanged sizes:** the working indicator (38 pt) and jump-to-latest are already
     glass and only get aligned tokens. The footer stays 24 pt.
   - **`SelectableMessageText`:**
     - Code-run and table backgrounds use `inset`/`tile`.
     - Set `selectedTextAttributes` so the selection stays legible on glass when the
       window is inactive.
     - Invalidate the cached attributed backgrounds when the theme changes.
5. **Workspace column.**
   - The file tree, browser bar, processes, Changes inline/split picker
     (`DieterSegmentedControl`) and review all move to tokens.
   - The terminal keeps its opaque `terminalBackground` inside the rounded panel clip.
6. **Composer:** no code change. Check visually that the composer glass reads well on the
   panel. If it doesn't, report it rather than change it.

### Phase 5: Remaining sections (medium)

Each section gets the same title-band `DieterGlassBar` (section title or picker, search
⌘K, contextual icon group, "+ New Task"), canvas content and a panel for detail content.

| Section                         | Changes                                                                                                                                                    |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Chats**                       | `ChatGroupCard` boxes become flat sections with `DieterNavRow` rows. Pinned chats use tiles. The header controls (new folder, new chat) move into the bar. |
| **Inbox**                       | Feed rows use tiles. Project and range filters become `DieterCapsuleGroup` menus. The section filter uses `DieterSegmentedControl`.                        |
| **Files / Changes / Schedules** | The navigator or list sits on the canvas. The editor, diff or schedule editor sits in a panel. `FluidPaneChrome` headers become bars.                      |
| **Terminals / Screens**         | The tabs become a segmented track. Terminal and viewer surfaces sit in a panel; the terminal stays opaque.                                                 |
| **Archive / Settings**          | Tiles, and a panel around the native `Form`.                                                                                                               |
| **Machines popover internals**  | Tiles and insets.                                                                                                                                          |

### Phase 6: Delete superseded code

Delete these, keeping only what the composer still uses (§4.4):

- `FluidPaneChrome`
- `DieterPaneBackground`
- `SurfaceModifier` / `dieterSurface`
- `DieterSecondaryButtonStyle` / `DieterPrimaryButtonStyle`, if fully replaced
- `PaneTitleBlock`, if fully replaced
- `DieterFloatingGlassChrome`, which is folded into `dieterPanel`
- the fade-on-transparency token opacities
- `StatusPill`, once every caller uses the dot and capsule
- everything listed in D6 and Phase 2.3
- stale comments

### Phase 7: Tests and verification (once, at the end)

**Unit tests to update or add**

| File                                           | Change                                                                                                                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `WorkspaceChromeTests`                         | Keep the "no `NSGlassEffectView` ancestor" assertion, which still holds. Add an assertion that the traffic lights sit inside the card in every section and in both modes. |
| `LiquidGlassLayoutTests`                       | Replace `conversationSidebarChromeKeepsNavigationInTheNativeTitlebar` with a header and track structure test. Keep the stable-height and 38 pt tests.                     |
| `BoardConversationOverlayTests`                | Width constants; the inset panel inside the item. Keep `.default` behavior and the board-fill assertion.                                                                  |
| `DieterMacTests`                               | `BoardPolicies` constants.                                                                                                                                                |
| `ConversationContentSplitTests`                | The 10 pt rail inset becomes the header layout.                                                                                                                           |
| `DieterThemeTests` / `DieterTransparencyTests` | New token contrast and solid-panel tests. Window opacity semantics are unchanged.                                                                                         |

**Smoke tests and e2e catalogs to update**

| File                                                               | Change                                                                                                                                              |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SidebarNavigationUISmokeRunner`                                   | Project tab-strip IDs replace `sidebar.board.<id>`, `sidebar.files.<pid>` and so on. Hover-only actions. "navigation-boundaries" should still pass. |
| `WorkspaceChromeUISmoke`                                           | Quotas ordering is now relative to the footer gear.                                                                                                 |
| `NativeUISmokeRunner`                                              | The `board.settings` path through the picker menu; titlebar double-click; Quick Task position.                                                      |
| `ConversationPaneFeatureSmoke:672-689`                             | New header and track geometry. Kanban becomes `board.layout-toggle`.                                                                                |
| `tests/e2e/cases/mac/{navigation,sidebar,board,conversation}.yaml` | ID changes.                                                                                                                                         |

**Performance gates.** Compare against the Phase 0 baseline.

- Board stress:
  - 4 tables
  - 0 creates and reloads
  - fewer than 40 mounted rows
  - idle CPU no worse than the baseline
- Chat-list layout budget (`DieterThemeTests:200-240`)
- Transcript refresh performance tests
- One Instruments pass to count backdrop layers (expect only panels and bar groups)

**Visual matrix.**

- dark/light × glass/solid × Reduce Transparency × {Monochrome, one colored palette}
- every section, sidebar expanded and collapsed, board with and without the inspector,
  conversation split and unsplit
- each compared side by side with `liquid-glass-target.png`

**Commands**

- `mise exec -- just pipeline mac test_unit`
- `mise exec -- just pipeline mac build`
- `mise exec -- just check-changed --native --dry-run`, then the selected `mac.*` cases
  one at a time
- Push CI gates only `mac.core` and `mac.board`; dispatch the full smoke run.

---

## 6. Data track: separate from the glass refactor

Each item needs proto, `grpcAPI`, CLI parity (AGENTS.md "Daemon CLI feature parity"),
core and UI work. The layouts above already reserve a slot for each.

| Element in target                    | Needs                                                                                                | Notes                                                                                                                                                                                           |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Card key `DTR-79`                    | Per-project key prefix plus a monotonic sequence in the daemon store, a `Card` field and CLI display | IDs today are `c_` + random hex (`internal/store/store.go:287-293`)                                                                                                                             |
| Card cost `$2.31`, lane cost `$8.66` | Usage → cost pricing in the core, a card aggregate and a lane sum                                    | `TokenUsage` has tokens only; `cost` exists only on `Subagent` (`dieter.proto:723`)                                                                                                             |
| "46 calls"                           | A per-card tool-call counter                                                                         | Only `Subagent.tool_count` exists                                                                                                                                                               |
| Durations "2m 14s", "4.2s"           | Start and end timestamps on message parts and tool steps                                             | `MessagePart`/`UiMessage` have no timestamps                                                                                                                                                    |
| Approve/Deny bar                     | A harness approval round trip: a proto command, a core pending-decision state, the CLI and UI        | The harness emits `tool-approval-request` (`internal/harness/runtime/claude-resilience.mjs:29`), but nothing answers it. It's also a product question, because harnesses run unsandboxed today. |
| Question and approval text on cards  | A core `BoardCardFlags` attention-text field                                                         | Today the card only shows "Waiting for you"                                                                                                                                                     |
| Running progress                     | Optional progress fraction                                                                           | The static line works without it                                                                                                                                                                |
| Project card total                   | A per-project count across boards                                                                    | The board total exists                                                                                                                                                                          |

---

## 7. Risks and mitigations

| Risk                                                           | Mitigation                                                                                                 |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Glass cost and backdrop stacking                               | D4 budget: no glass in lists; one container per bar; Instruments check; stress gates                       |
| Legibility of tertiary text on glass, especially in light mode | Contrast unit tests per palette and mode; palette tint under every panel; tune `tertiary` for panels       |
| Solid mode and Reduce Transparency hide the floating cards     | A distinct `panel` token plus rim and shadow; tested                                                       |
| Test churn hides a regression                                  | Tests change only where they encode the old layout; behavior assertions (IDs, perf, scroll, identity) stay |
| The invisible divider is hard to discover                      | A widened hit rect plus the resize cursor in the gap                                                       |
| Composer glass on panel glass looks heavy                      | Not changed (your constraint); reported if it's a problem                                                  |
| Owned traffic lights drift from system behavior                | Hover glyphs, inactive state, Option-click, accessibility labels and a unit test                           |
| `AnyView` root churn plus more glass in retained panes         | Decorations through modifiers; observing subviews for new card fields; no glass in retained list content   |
| Board picker hides multi-board switching                       | The menu lists boards with attention counts; the sidebar Board tile opens the last board                   |

---

## 8. Decisions and implementation notes

Decisions (2026-10-07):

1. **Data track:** left out. Elements without data (card keys, costs, call counts,
   durations, Approve/Deny) are not drawn, and no placeholder slots ship.
2. **Typography:** Sora stays for pane titles; SF Mono is added for metadata.
3. **Sidebar:** avatars, the search launcher and the Settings row are gone (Settings
   is the footer gear). "Add a Git project" stays. Quotas live under the machines.
4. **Header model line:** removed.
5. **"Search ⌘K":** opens the command palette in every top bar.
6. **Remaining sections:** done as a shell-level pass (top bar plus floating panel).

As built:

- **Glass roles and primitives:** `UI/DieterGlass.swift` (panels, tiles, insets,
  capsule bars, segmented tracks, the section scaffold). The role tokens are in
  `DieterTheme.swift`.
- **Title band:** every section hides the window toolbar. `DieterTitleBandRegion` sits
  behind each top bar: dragging moves the window and a double-click performs the
  system's title-bar action. It replaces the window-wide double-click monitor.
- **Quota fix:** the subscription now starts when the workspace connects. The
  shared-core migration (34c0a98b) had left it to the popover alone.
- **Width minimums:** pane minimums grow by `DieterMetrics.panelHorizontalInset`, so
  the unchanged composer keeps its designed width inside a floating panel.
- **Recursive view searches** use `NSView.firstSubviewResult`. A recursive
  `subviews.lazy.compactMap { … }.first` re-evaluates its matching branch at every
  level, and the deeper glass hierarchy made those searches take minutes.
