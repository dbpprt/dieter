# macOS design references

These 41 transparent PNGs were extracted losslessly from the 25-page
`Board Mac SwiftUI app with worktrees.pdf`. The source PDF is intentionally not
checked in. Each file is one implementation-level view or component rather than
a render of the full PDF page. The PDF's plate number is not the same as its
page number because the newer plates appear first.

## View index

| Plate | PDF page | Reference files | What they show |
| --- | ---: | --- | --- |
| 25 | 1 | `island-collapsed.png`, `island-expanded.png`, `settings-island.png` | Notch pill counts, expanded activity, and Island preferences. |
| 24 | 2 | `settings-desk-pet.png`, `desk-pet-companion.png` | Desk-pet selection/behavior and its floating review companion. |
| 15 | 3 | `merge-conflict.png`, `merge-failed-toast.png` | A blocked merge with agent resolution and the failed pre-merge toast. |
| 16 | 4 | `pull-request-states.png` | Open PR, checks-running card chip, and checks-passed merge state. |
| 17 | 5 | `worktree-manager.png`, `worktree-commits.png` | Worktree cleanup/adoption and the commit list used for step diffs. |
| 18 | 6 | `machine-offline.png`, `turn-failed.png`, `session-expired.png`, `merge-completed-toast.png` | Offline, failed-turn, expired-session, and successful-merge feedback. |
| 19 | 7 | `empty-states.png` | Fresh-install onboarding beside an empty Todo lane. |
| 20 | 8 | `command-palette.png` | Command-K search across cards, files, and actions. |
| 21 | 9 | `settings-overview.png` | General, notification, agent, model, and prompt settings. |
| 22 | 10 | `card-comments.png`, `card-subagents.png` | Card comments and concurrent subagent progress tabs. |
| 23 | 11 | `card-context-menu.png`, `card-drag-indicator.png`, `card-drag-preview.png`, `keyboard-shortcuts.png` | Card menu, drag insertion affordances, and shortcut help. |
| 14 | 12 | `machine-popover.png` | Live machine utilization and Dieter process activity. |
| 11 | 13 | `new-chat-workspace.png` | Choosing a worktree or the registered project directory for a new chat. |
| 12 | 14 | `changes-diff-viewer.png` | Worktree file list and inline diff in a card window. |
| 13 | 15 | `merge-into-main.png` | Merge strategy, commit message, cleanup, and create-PR alternative. |
| 01 | 16 | `board-card-inspector.png` | Main Board window with lane filters and a card inspector. |
| 02 | 17 | `chats-standalone-chat.png` | Global Chats list and an idle standalone conversation. |
| 03 | 18 | `new-conversation.png`, `board-labels.png` | New card/conversation form and board label management. |
| 04 | 19 | `connect-onboarding.png`, `choose-git-repository.png` | Gateway onboarding and local Git repository selection. |
| 05 | 20 | `settings-connection.png` | Connection routing, gateways, discovered machines, and auth. |
| 06 | 21 | `collapsed-navigation.png` | Collapsed icon rail with the project navigation flyout. |
| 07 | 22 | `files-editor.png` | Working-tree browser and editor. |
| 08 | 23 | `schedules-editor.png` | Schedule list and recurrence/action editor. |
| 09 | 24 | `terminals.png` | Machine-aware terminal tabs and new-terminal popover. |
| 10 | 25 | `menu-bar-item.png`, `connection-popover.png`, `review-notification.png` | Menu-bar icon, gateway/activity popover, and review-ready notification. |

The images retain the PDF's alpha channel. A black or transparent surround is
intentional and is not part of the macOS UI surface.

## Regenerating

Regenerate them with a Python environment that provides `pypdf`:

```sh
python3 -m pip install -r apps/mac/design/requirements.txt
python3 apps/mac/design/extract_reference_images.py \
  "/path/to/Board Mac SwiftUI app with worktrees.pdf"
```

The extractor assigns explicit semantic filenames and fails if the page or
embedded-image structure changes, so a refreshed PDF cannot silently scramble
the references. After a successful validation and extraction it also removes
stale PNGs from this directory, keeping the checked-in set aligned with the
source PDF.
