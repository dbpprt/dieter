# Proposal: mobile navigation and layout overhaul

Status: implemented 2026-10-31 · scope: shared Compose UI (`apps/kotlin/ui`),
the iOS shell (`apps/apple/ios/Host`), the core's shared KV delivery
(`apps/kotlin/core/runtime`), Maestro flows and the user guide

## TL;DR

The phone apps had grown one tab per feature: Inbox, Projects, Chats, Mail,
Tools and Channels. iPhone could show only five, so Channels silently
disappeared there. **Tools** was a grab bag. It listed machine pages that
weren't tied to a machine. Its project pages used whichever project the app had
touched last, falling back to the first one, so Files or Changes often showed
the wrong project with no hint why. Unfolded foldables (Galaxy Z Fold7: about
750 × 830 dp) never got the list-beside-detail layout, because two panes
started at 840 dp and the split had a fixed width. Separately, pins made on a
phone never reached the account.

This change:

1. **Four destinations.** Every platform shows Inbox, Projects, Chats and
   **More**. On Android, More opens a slide-up sheet with the bar docked below
   it, like the original Android app's Tools panel. The sheet holds Mail and
   Channels (with their unread badges), Terminals, the machines, Usage, Devices
   and Settings. On iOS, More is a tab whose page lists the same entries.
2. **Tools in context.** The Tools tab is gone. Files, Changes and Schedules
   open from a project and always carry its ID. Files and Changes also carry a
   checkout ID. A machine's page shows its screen, its terminals and the
   project checkouts on it. Nothing uses "the last project" any more.
3. **Two panes from 600 dp, with a draggable divider.** List beside detail
   starts at 600 dp wide (and 480 dp tall, so a landscape phone stays single
   pane). The divider can be dragged and double-tapped to reset. The split is
   saved per device.
4. **Pins sync.** The core's shared-KV delivery no longer stalls behind a
   machine whose copy of the account lags.

## 1. Findings

### 1.1 Navigation

- `MobileTab` had six entries. The Android bar and rail drew all six.
- The iOS shell drops `channels` in compact width (`ComposeHost.swift`
  `rebuildTabs`) and maps UIKit tab indices to `MobileTab.entries` by
  position. `openChannel` selected a tab iPhone doesn't have, so tapping a
  channel message in a conversation did nothing visible there.
- iOS copies the list-column rule from Kotlin by key prefix (`root/`,
  `project/`, `board/`) instead of reading it from the route.
- The Tools tab mixed three scopes: account-wide lists of machines, terminals
  and screens; project tools (Files, Changes, Schedules); and account pages
  (Usage, Devices, Settings).

### 1.2 Tool scope ("recently opened")

- `BoardsModel.currentProjectId()` = `selectedProject` → the selected board's
  project → **the first project**. `syncNavigation` set it from whatever
  `Project`, `Board` or `Tool` route came last. Nothing cleared it.
- `MobileRoute.Tool.projectId` was applied once, when the route became the
  top. The screens themselves read `currentProjectId()` while they rendered.
- The Files and Changes "Project" menu wrote the global selection. The next
  navigation event set it back from the route.
- The checkout came from a global `selectedCheckout`, then the remembered
  creation default, then the only checkout. With several checkouts and no
  default, the bind returned early, so the screen kept showing its previous
  target. That could be another project, or a conversation's workspace.
- The Processes pane bound the global current project instead of the card's
  project.

### 1.3 Foldables

- `MobileApp.kt`: rail at ≥ 600 dp, two panes at ≥ 840 dp, list column a
  fixed 400 dp. The Fold7 inner display is narrower than 840 dp in both
  orientations, so it always showed one pane with a rail.
- There is no foldable-specific code (no `androidx.window`), and none is
  needed: the window size already describes the posture we care about.

### 1.4 Pins

Inbox, project and chat-order pins are records in the account-wide
`navigation` SharedKV namespace. A client delivers each edit to a reachable
machine. It must wait when that machine hasn't yet seen the value the client
shows, so a lagging machine can never roll a change back.

- A phone has no local machine, so its first choice is the first machine by
  name. In the operator's account that was `mbp-office`, whose replica had
  received only 3 of the namespace's records.
- `SharedKv.prepare` waited on that machine forever. Delivery is strictly in
  order, so every later navigation edit from the phone queued behind it. The
  phone's own view looked right because it overlays its pending edits.
- The Mac never noticed, because it writes to its own complete daemon first.
- The root cause of the lagging replica is separate: peer pulls into
  `mbp-office` and `workbench` reject whole pages because one record from an
  offline 0.4 machine fails provenance. That needs its own daemon change (§5).

## 2. Design

### 2.1 Destinations

```
MobileTab   INBOX · PROJECTS · CHATS · MORE
More        Mail (unread) · Channels (unread) · Terminals · Usage (lowest left)
            Machines: one row per machine (status, detail; screen shortcut)
            Devices · Settings
```

- New list routes: `Mailbox` (the mail folders and list) and `Channels` (the
  channel list). The new `More` root lists the More entries. These replace
  `Root(MAIL)` and `Root(CHANNELS)`.
- `store.openMore(route)` selects More with `[Root(MORE), route]`, so back
  returns to the More page. Re-selecting More resets it to its root, like
  every tab.
- `openChannel` pushes the channel onto the current stack. Back returns to the
  conversation the link was in, on every platform.
- Mail is active (polling, read receipts) while a Mailbox route is on the
  visible stack. The selected message is whatever MailMessage the More stack
  holds.
- The More badge is unread mail plus unread channel messages. The label is
  capped at "99+".
- `MobileRoute.list` is the only list rule. The iOS shell reads it from
  `MobileRouteHandle.list`.

### 2.2 The More sheet (Android)

- A `ModalBottomSheet` with a drag handle and these sections:
  - a tile grid: 4 columns, adaptive to font scale; tiles show a badge or a
    value;
  - **Machines**: rows with an online dot and the machine's detail line, plus
    a screen button when screen sharing is possible;
  - **Account** tiles.
- The navigation bar is docked at the bottom of the sheet. Its More item shows
  a chevron pointing down and closes the sheet. Choosing a primary tab there
  closes the sheet and switches tabs.
- On the rail (≥ 840 dp), More opens the same sheet.
- Tags: `nav-more`, `more-<entry>` and `more-machine-<id>`. The More page uses
  the same tags, so flows don't need to know the platform.

### 2.3 Contextual tools

| Tool                          | Opens from                                                                                                          | Scope it carries                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Files                         | project page (Workspace, or a checkout row), machine page (Projects on this machine), conversation pane, mail links | `Tool(FILES, projectId, checkoutId)` or the card   |
| Changes                       | project page                                                                                                        | `Tool(CHANGES, projectId, checkoutId)` or the card |
| Schedules                     | project page                                                                                                        | `Tool(SCHEDULES, projectId)`                       |
| Terminals                     | More (every machine, grouped by machine), machine page (that machine's), conversation pane                          | none / the machine / the card                      |
| Screen                        | machine page, machine row in More                                                                                   | `ScreenSession(machineId)`                         |
| Machine telemetry and actions | machine page                                                                                                        | `Machine(machineId)`                               |

- Files and Changes resolve the checkout from the route, in this order:
  1. `route.checkoutId`;
  2. the checkout the core remembers for the project (`creation.defaults`);
  3. the only attached checkout;
  4. the first attached checkout whose machine is available;
  5. the first checkout.
- When the project has more than one checkout, a **Checkout** menu replaces
  the route instead of writing global state. The subtitle always names the
  project and the machine.
- `BoardsModel.selectedCheckout` and `projectScopeMenu` are deleted.
  `selectedProject` remains only as the new-task default, and the Processes
  pane uses the card's project.
- The machine page gets new sections ahead of its telemetry:
  - **Screen**, when it can share;
  - **Terminals** on this machine, with New terminal preset to it;
  - **Projects** on this machine: its checkouts, each opening Files.
- Deleted: the Tools tab page (`ToolsScreen`), the machines list page
  (`MachinesScreen`) and the screens picker (`ScreensScreen`). More and the
  machine page cover all three.

### 2.4 Adaptive layout (Android)

- **Two panes** when width ≥ 600 dp and height ≥ 480 dp. That covers unfolded
  foldables, small tablets, and split-screen halves of large tablets. A
  landscape phone (about 400 dp tall) stays single pane.
- **Rail** at width ≥ 840 dp. Below that, the bottom bar and its sheet stay,
  which suits a foldable held like a book.
- **Divider:**
  - a 1 dp line inside a 16 dp touch target, with a 4 × 40 dp handle that
    darkens while it is dragged;
  - dragging moves the split, clamped so the list keeps ≥ 280 dp and the detail
    ≥ 320 dp;
  - double-tapping restores the default fraction, 0.42;
  - the fraction is saved in `MobilePreferences` (`pane-fraction`);
  - semantics expose "Resize panes".
- iPad keeps the native `UISplitViewController`.

### 2.5 Pins (core)

- `SharedKv` delivers each edit to the preferred machine. If that machine
  hasn't seen what the client shows, the edit goes to the next reachable
  machine that has. It waits only when no reachable machine has.
- A move also needs its neighbour keys to be seen.
- An edit that hasn't been sent yet moves on after a transient error. Once
  sent, it stays with its machine, so a retry is safe.
- Covered by `SharedKvDeliveryTest`: a lagging first machine, a busy first
  machine, every machine behind (it waits, then lands without a rollback), and
  a move anchored on a neighbour.

## 3. Verification

- **Core:** `:core:runtime:jvmTest` for navigation and client, plus the
  native compile.
- **UI:** `:ui:jvmTest` for the store navigation tests:
  - More routes and back;
  - mail active under More;
  - `openChannel` pushes onto the current stack;
  - tool routes bind their own project and checkout, not the last-touched one;
  - divider clamping.
- **Core e2e:** `NavigationEndToEndTest`, `InboxSyncEndToEndTest`, and
  `MobileJourneyTest` with the new routes.
- **Android:** an E2E build on the warm emulator. The Maestro flows `board`,
  `task`, `mail`, `devices`, `tools`, `terminals` and `channels` go through
  `common/more.yaml`. A wide-window check covers two panes and the divider.
- **iOS:** the Kotlin/Native compile locally, then CI's iPhone flows. iPad runs
  on full qualification.
- **CI:** main-push qualification, then a dev release, then stable promotion.

## 4. Non-goals

- No change to the Mac app's sidebar.
- No new core surfaces. Every tool already takes an explicit target.
- Project-scoped terminal lists. The core supports them, but the machine page
  and conversation panes cover today's uses.

## 5. Follow-up

**Peer replication rejects whole pages** (daemon, `internal/store/replica`).
One record from an offline 0.4 machine (`mbp-home`) fails provenance. That
rejects every page pulled into `mbp-office` and `workbench`, so both replicas
stay almost empty. The pin fix above routes around those replicas, but they
need their own fix: quarantine the failing record and keep applying the rest.
The change has to be checked against the threat model.
