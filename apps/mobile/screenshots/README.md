# Native screenshots of the Compose design port

These 48 images capture the actual running apps on 7 October 2026. Each platform
passed the complete 16-view journey and owned-device cleanup against an isolated
authenticated gateway, daemon and mock harness. New task creation and both live
replies run through that daemon; the existing transcript/subagent is seeded data.

Open the [comparison gallery](../design/index.html) to compare every view across
Android, iPhone and landscape iPad. The [legacy gallery](../design/legacy-android/index.html)
contains 17 original Android reference captures from 11 selected audit cases.

| Platform              | Native target                                       | Pixels      | Passing evidence                                                    |
| --------------------- | --------------------------------------------------- | ----------- | ------------------------------------------------------------------- |
| Android · Material    | AOSP API 35 / Dieter_Compose_API_35 / emulator-5560 | 720 × 1280  | `tmp/app-pipelines/9bbc763c-5eec-4ad2-abb8-0fbc1d02b98c`            |
| iPhone · Liquid Glass | iPhone 17 Pro / iOS 26.5                            | 1206 × 2622 | `tmp/app-pipelines/1a42816f-6dfb-4664-a7fc-b30ab46df1ff/ios-iphone` |
| iPad · Liquid Glass   | iPad Air 11-inch (M3) / iOS 26.5 / landscape        | 2360 × 1640 | `tmp/app-pipelines/1a42816f-6dfb-4664-a7fc-b30ab46df1ff/ios-ipad`   |

iOS uses native SwiftUI SF Symbol tabs and `glassEffect` controls around the
shared content, with system typography and grouped fields. Android uses the
legacy Monochrome palette, Sora headings and Material controls. The last two
captures verify each host's dark appearance. Android additionally verifies form
and follow-up draft retention across Activity recreation; iPad verifies landscape
and the board remaining visible beside a conversation.

| View          | Android                                                | iPhone                                               | iPad                                             |
| ------------- | ------------------------------------------------------ | ---------------------------------------------------- | ------------------------------------------------ |
| Inbox         | [android-inbox.png](android-inbox.png)                 | [iphone-inbox.png](iphone-inbox.png)                 | [ipad-inbox.png](ipad-inbox.png)                 |
| Projects      | [android-projects.png](android-projects.png)           | [iphone-projects.png](iphone-projects.png)           | [ipad-projects.png](ipad-projects.png)           |
| Board         | [android-board.png](android-board.png)                 | [iphone-board.png](iphone-board.png)                 | [ipad-board.png](ipad-board.png)                 |
| Task          | [android-task.png](android-task.png)                   | [iphone-task.png](iphone-task.png)                   | [ipad-task.png](ipad-task.png)                   |
| Subagents     | [android-subagents.png](android-subagents.png)         | [iphone-subagents.png](iphone-subagents.png)         | [ipad-subagents.png](ipad-subagents.png)         |
| New Task      | [android-new-task.png](android-new-task.png)           | [iphone-new-task.png](iphone-new-task.png)           | [ipad-new-task.png](ipad-new-task.png)           |
| Conversation  | [android-conversation.png](android-conversation.png)   | [iphone-conversation.png](iphone-conversation.png)   | [ipad-conversation.png](ipad-conversation.png)   |
| Review        | [android-review.png](android-review.png)               | [iphone-review.png](iphone-review.png)               | [ipad-review.png](ipad-review.png)               |
| Chats         | [android-chats.png](android-chats.png)                 | [iphone-chats.png](iphone-chats.png)                 | [ipad-chats.png](ipad-chats.png)                 |
| Tools         | [android-tools.png](android-tools.png)                 | [iphone-tools.png](iphone-tools.png)                 | [ipad-tools.png](ipad-tools.png)                 |
| Machines      | [android-machines.png](android-machines.png)           | [iphone-machines.png](iphone-machines.png)           | [ipad-machines.png](ipad-machines.png)           |
| Files         | [android-files.png](android-files.png)                 | [iphone-files.png](iphone-files.png)                 | [ipad-files.png](ipad-files.png)                 |
| File Preview  | [android-file-preview.png](android-file-preview.png)   | [iphone-file-preview.png](iphone-file-preview.png)   | [ipad-file-preview.png](ipad-file-preview.png)   |
| Schedules     | [android-schedules.png](android-schedules.png)         | [iphone-schedules.png](iphone-schedules.png)         | [ipad-schedules.png](ipad-schedules.png)         |
| Settings Dark | [android-settings-dark.png](android-settings-dark.png) | [iphone-settings-dark.png](iphone-settings-dark.png) | [ipad-settings-dark.png](ipad-settings-dark.png) |
| Board Dark    | [android-board-dark.png](android-board-dark.png)       | [iphone-board-dark.png](iphone-board-dark.png)       | [ipad-board-dark.png](ipad-board-dark.png)       |

[Boards](boards.png), [conversations](conversations.png), and the
[legacy → shared board comparison](../design/board-comparison.png) resize full
captures proportionally and add captions outside them. Contact sheets/comparisons
honor the native EXIF orientation (iPad stores portrait pixels with landscape
orientation metadata). Original images are copied byte-for-byte; no app content
is cropped, repainted or synthesized. Native capture
settling waits allow the rendered frame to catch up with its semantic assertion.

[Provenance](provenance.json) records original evidence paths, image SHA-256,
dimensions, native simulator IDs/timestamps and source digests. See
[verification](../VERIFICATION.md) for the qualified scope and production cutover
requirements. These screenshots do not qualify every action in every screen.
