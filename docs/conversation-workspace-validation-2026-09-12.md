# Native conversation workspace: implementation and validation

12 September 2026. Opens linked objects in a tabbed, resizable workspace beside the conversation. Files, Browser, Terminal, and Review are available from the empty launcher and the add-tab menu. There is no side chat.

## Delivered behavior

Markdown opens in interactive Edit mode. Native formatting, checkboxes, relative links, and revision-checked saving work in place; Source, Split, and Preview are optional. Code has syntax highlighting and line navigation. Images, PDFs, and unsupported files use dedicated native preview or download surfaces.

Each tab retains its own document buffer, browser history, and exact machine/project/worktree scope. Dirty close prompts support saving, discarding, or canceling. Hiding the pane preserves its tabs. Closing a terminal tab stops its UI watch without closing the daemon-owned session. Review uses the conversation worktree or the shared project checkout as appropriate.

Opening an object expands the conversation and starts with a 45/55 chat/content split. Restoring the board preserves the actual native transcript view, selection, draft, scroll position, and remembered conversation width. Tabs scroll their selected label into view. Reconnection replaces stale transports while retaining dirty text in the same workspace.

The `present_content` harness tool and `dieter card present` / `dieter chat present` request presentation in the exact owning conversation. The latest typed request is durable and delivered through conversation snapshots and updates; it does not create a message or resume an agent. Files are bounded regular files within the owning workspace, with symlink escapes and `.git` access rejected. HTTP(S) URLs and optional line/title fields are validated before an event is emitted.

## Validation

- `go test -race ./...` and `go vet ./...`: passed.
- `just harness test`: 49 tests passed.
- `just mac test`: 513 tests in 19 suites passed.
- `just android test`: passed using Android Studio's bundled JBR.
- Proto generation, Swift formatting, whitespace checks, packaged-app build, and bundle signature verification: passed.
- All eight native Mac smoke suites passed. The final conversation run recorded 99 result entries with zero failures.

The new pane smoke journeys verify rich Markdown typing and checkbox interaction, scoped save and reopening in Edit mode, dirty tab retention and canceled close, file-tree navigation, actual relative-link clicks, code line navigation, browser address entry/back/navigation/scheme rejection, terminal input and session survival, scoped project review, image/PDF/unsupported-file renderers, native resizing, exact transcript preservation, and RPC-to-watch agent presentation. Model tests cover tab limits, malformed links, endpoint/worktree changes, reconnect recovery, and dirty-buffer protection.

The broader core suite checks Markdown Edit/Source/Split/Preview, diagrams, saving, and editor lifecycle. Sidebar prepare/relaunch checks cover persisted collapse, order, and width. Worktree and project Git operations are exercised in disposable repositories. WebRTC test peers are constrained to loopback interfaces to avoid host VPN/physical-interface dependence.

| Suite | Result | Local evidence directory under `apps/mac/.build/smoke/` |
| --- | --- | --- |
| Core | Passed | `core-20260912-152308-912397ae-d28c-4e84-a426-687662a483d9` |
| Board | Passed | `board-20260912-152511-0bdab15a-7ad8-4880-9069-7e49dc8147a4` |
| Conversation | Passed | `conversation-20260912-153641-e5c4ecf0-8493-48b7-9200-07107595b941` |
| Machine | Passed | `machine-20260912-151937-ab2d8881-29ab-45d8-a869-e3cf014f0d5e` |
| Sidebar | Passed | `sidebar-20260912-152959-d38c14f5-70bb-4b63-93e9-78d327b1b0e5` |
| Terminal | Passed | `terminal-20260912-153056-becc6f7e-f88f-4656-88ab-9f3959efac72` |
| Island | Passed | `island-20260912-153107-f13bd0c8-f130-44e0-be54-bcd1e8a4ec8f` |
| Workspace | Passed | `workspace-20260912-153116-342a5eb9-32ef-4afd-9588-940d39fc89db` |

Two existing coverage limits are explicit: the board suite's in-process accessibility-action probe is unavailable, so card opening was additionally verified through external native accessibility on the installed app; the conversation renderer fixture skips its separate historical-pagination probe, whose bounded-history behavior is covered by unit tests. Android connected tests were unavailable because no emulator or device was connected.

All native smoke mutations used isolated state roots and disposable daemons. The operator's daemon was not stopped, replaced, or restarted. The updated app was installed at `~/Applications/Dieter.app`, its signature and executable hash were verified, and one installed app process was launched and observed connected. Live agent presentation requires updating the running daemon to the matching implementation; manual workspace tabs work with the existing service.

## Screenshots

These are actual native-window captures from the final isolated conversation smoke run, showing test fixtures rather than operator project content.

### Interactive Markdown (default mode)

![Interactive Markdown beside the conversation](screenshots/conversation-workspace/markdown.png)

### Browser

![Browser tab beside the conversation](screenshots/conversation-workspace/browser.png)

### Terminal

![Native terminal tab beside the conversation](screenshots/conversation-workspace/terminal.png)

### Review

![Native project review beside the conversation](screenshots/conversation-workspace/review.png)
