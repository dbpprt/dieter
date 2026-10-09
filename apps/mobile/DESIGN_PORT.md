# Android design audit and Compose port

The reference is the shipping Android UI, inspected in source and through 11
selected native audit cases. The retained [17 screenshots](design/legacy-android/index.html)
include light/dark cards, Inbox, projects, creation/options, subagents, schedule
editing, diffs/commit/merge, checkouts and tablet layouts. Their
[provenance](design/legacy-android/provenance.json) names the original case output
and source revision. These captures use isolated data, focused component fixtures
and app journeys running the shipping Android sources.

## Surface inventory

| Legacy Android reference                            | Shared port                                 | Preserved behavior and design                                                                                                                                   |
| --------------------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ActivityScreen`, `ProviderQuotaUi`                 | `WorkspaceScreens`, `ToolScreens`           | Attention/activity groups, project tiles, timeline/search, account usage and inclusion/reset controls                                                           |
| `ProjectOverviewScreen`, `ChatsScreen`              | `WorkspaceScreens`, `AdministrationScreens` | Expandable projects/boards, pinned groups, folders, search, chat archive/restore and filing                                                                     |
| `BoardScreen`, `BoardCards`, `BoardCardActions`     | `BoardScreens`                              | Palette/card density, labels, summaries, machine/workspace badges, age, token/status footer, filters, sorting, swipe actions and lane dragging                  |
| `ConversationCreation`, agent settings              | `CreationScreen`                            | Project/board/checkout destination, core preview, agent/model/effort/options, labels, workspace, prompt, Todo/Start and attachments                             |
| `TaskDetail`, `MessageContent`, subagents and plans | `ConversationScreen`, `RichText`            | Live and historical messages, delivery, rich text/code/tables/links, tool groups, task plans, subagents, queue edit/remove/steer, following and draft retention |
| `FilesScreen`                                       | `ToolScreens`                               | Checkout/card scope, folder history/hidden files, editor and Markdown preview, create/rename/delete, revision-aware save and bounded dirty buffers              |
| `WorkspaceChangesScreen`                            | `ReviewScreen`, `WorkspaceTools`            | Changed files/commits, unified/split diff, folds/context/comments, staging and Git forms, PR signals, conflict prompts and merge readiness/options              |
| `SchedulesScreen`                                   | `ManagementScreens`                         | Project schedule list/editor, core preview, agent preferences, next occurrences, history, enable/pause/run/delete                                               |
| Project/board settings                              | `AdministrationScreens`                     | Project settings/prompts, checkouts, boards/workflow, labels, archived cards, workspace cleanup/discard and causal-setting conflict selection                   |
| Machine/settings views                              | `ToolScreens`, `MobileTheme`                | Telemetry, capability-gated actions with confirmation, gateways/reconnect/outbox, appearance and eight exact palettes                                           |
| `RemoteTerminalView`, terminal lists                | Native factory + shared controls            | Existing terminal emulator, selection/input, bounded output replay, cursor-mode-aware special keys and rename/close                                             |
| `ScreensScreen`, `ScreenCanvasView`                 | `ScreenUI` + native factory                 | Existing video/input, control, quality/FPS/codec/display/clipboard, zoom/fit, software keyboard, right click and refresh                                        |

## Reuse and platform presentation

Palette and drag state are imported from the original Android sources using
explicit Sync tasks. The screen host was split into a small protocol, letting
both Android apps embed the original GPU canvas. WebRTC build/verification is
centralized in `native/android-webrtc/sdk.gradle`. The original iOS Metal renderer,
cursor state and input view moved into SharedCore so both iOS hosts can use them.
Termux and SwiftTerm render terminal bytes; the KMP core owns sessions and replay.

Android uses Material 3 components, dynamic color and Sora titles. On iOS,
UIKit tab bars, navigation stacks, bar buttons, menus, sheets and alerts carry
the same actions, and Compose draws content with system colors, type and SF
Symbols. Native pickers and previews supply platform interaction. No backend
rule, API or release identity is forked.

## Evidence and limits

The native journey opens the seeded task/subagent, creates a new task, receives
actual first and follow-up mock replies in its durable conversation, moves it to
Review, then visits chats, tools, machines, files/Markdown preview, schedules and
dark appearance. Six shared regressions additionally cover captured IDs,
closed-scope updates, terminal delta retention, preview cancellation, draft
flush and file-buffer preservation. [Verification](VERIFICATION.md) records the
current results and retained failure evidence.

The reference audit is broader than the spike's native functional journey.
Complete shipping catalogs, notification/background/widget/share services,
physical-device media, accessibility and production drag/reordering polish are
not qualified by screenshots. The old apps remain available throughout migration.
