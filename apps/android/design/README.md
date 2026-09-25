# Android design references

The PNG files in `reference/` are the transparent mockups embedded in the
current `Native Android PWA redesign1.pdf`. They are extracted without
rendering, cropping, or recompression. The first two pages define the new
Connections and Display settings tabs. The next three define the Dieter server
connection sheet, Android notification shade, and standalone-chat subagents
tab. The remaining pages cover Spaces, board switching, creation flows,
unfolded layouts, and the core phone destinations.

Regenerate them with the bundled Codex Python runtime or any Python environment
that provides `pypdf`:

```sh
python3 apps/android/design/extract_reference_images.py \
  "$HOME/Downloads/Native Android PWA redesign1.pdf"
```

The extractor assigns stable semantic filenames explicitly so a refreshed PDF
replaces the expected references and fails loudly if its page structure
changes.

Android uses Chats and Boards as primary destinations. Tools opens a compact
panel for Machines, Terminal, Files, Schedules, Screens, and Settings. The panel uses
opaque surfaces from the selected app palette.

## Tablet workspace

`reference/tablet/` contains all 17 pages rendered from the supplied `tablet.pdf`
(25 September 2026). Page numbers preserve the PDF's order. These references
illustrate layout, not the availability of every feature shown in their sample
data. The Android implementation reuses current operations and never adds cost,
budget, or server features merely because they appear in the mockups.

Render a replacement PDF with Poppler:

```sh
mkdir -p tmp/tablet-reference
pdftoppm -scale-to 1600 -png /path/to/tablet.pdf tmp/tablet-reference/page
```

The application uses the window's available width:

- Below 600 dp: existing phone navigation.
- 600–839 dp: existing Fold rail and resizable panes. Fold 7 at 420 dpi remains
  in this range in both orientations.
- From 840 dp: Inbox / Chats / Projects / Tools rail, connection and Settings
  controls at its foot, project navigator and scoped tabs, parallel board lanes,
  list-detail Inbox and Chats, an activity timeline in the sidebar, narrower file
  navigation, and Settings categories beside their content.

Activity and Projects always retain a sidebar with the selected content beside
it, including empty selections and the Activity timeline. Opening a board card
replaces the board in the content pane; Back returns to its lanes while the
project navigator stays visible. Drag the divider to resize the panes. Activity,
Projects, and Chats save their own split locally on the device across app
restarts; temporary window constraints do not overwrite the saved split. Existing
conversation, subagent, changes, merge, comments, creation, schedule, terminal,
screen, machine, and provider-quota controls remain the source of behavior.
Tablet colors follow the user's existing palette and system appearance.

`TabletWorkspaceTest` captures the real native compositions, including a light
appearance at 150% font size, using the separate `.e2e` application. Its virtual
1280 × 800 dp canvas and 840 dp portrait/resize case also fit the standard
phone emulator, so regression runs
do not depend on changing device resolution. Run:

```sh
just e2e run --case component.tablet-workspace-test --output tmp/tablet-ui
just e2e run --case activity.navigation --output tmp/tablet-navigation
```

The latter tests real fixture-backed card/chat navigation and back behavior at
the emulator's current window size. Results and native screenshots are retained
under each run's output directory. Use `just check-changed` for the complete
set of required checks.
