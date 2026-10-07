# Screenshots of the running Compose spike

These are captures of the actual native apps, using the same shared Compose
screens and an isolated gateway/daemon fixture. They are not design renders.

## Android

AOSP API 35, dedicated `Dieter_Compose_API_35` emulator, 720 × 1280 pixels at
280 dpi. `ComposeSpikeTest.sharedTaskJourney` captured these images during a
passing native journey on 7 October 2026. Evidence:
`tmp/app-pipelines/eabff2fc-8b58-40c2-ae07-5909429ac6cc`.

| Screen                              | Capture                                              |
| ----------------------------------- | ---------------------------------------------------- |
| Board                               | [android-board.png](android-board.png)               |
| Seeded conversation                 | [android-task.png](android-task.png)                 |
| New task / system keyboard          | [android-new-task.png](android-new-task.png)         |
| Live mock reply / completed tools   | [android-conversation.png](android-conversation.png) |
| Review after a follow-up            | [android-review.png](android-review.png)             |
| Machine compatibility / relay route | [android-machines.png](android-machines.png)         |

The task form capture is an in-progress frame while entering the prompt; its
submitted text is visible in the following conversation capture. The mock
harness executes actual isolated tool steps and emits the deterministic answer
shown in the live-reply image. The seeded conversation contains sample text.

## iPhone

iPhone 17 Pro, iOS 26.5 simulator, 1206 × 2622 pixels. XCTest captured these
images on 7 October 2026 against the isolated authenticated fixture. The host
uses SwiftUI Liquid Glass around the common Compose content.

| Screen                     | Capture                                            |
| -------------------------- | -------------------------------------------------- |
| Board                      | [iphone-board.png](iphone-board.png)               |
| Seeded conversation        | [iphone-task.png](iphone-task.png)                 |
| New task / system keyboard | [iphone-new-task.png](iphone-new-task.png)         |
| Live mock reply / tools    | [iphone-conversation.png](iphone-conversation.png) |
| Review after a follow-up   | [iphone-review.png](iphone-review.png)             |
| Machines                   | [iphone-machines.png](iphone-machines.png)         |

These six captures come from a passing native journey, including the actual
first and follow-up mock replies and Review. Qualification and cleanup passed.
Evidence: `tmp/app-pipelines/db231e8f-36a3-4b97-8985-ac0229cd84ec`.

## iPad

iPad Air 11-inch (M3), iOS 26.5 simulator, 2360 × 1640 pixels in landscape.
The same XCTest journey passed on 7 October 2026 and required the board to stay
visible beside the conversation. Qualification and cleanup passed. Evidence:
`tmp/app-pipelines/cdbbd83f-3994-4481-9778-bfda8e952f3b`.

| Screen                      | Capture                                        |
| --------------------------- | ---------------------------------------------- |
| Board / empty detail        | [ipad-board.png](ipad-board.png)               |
| Board / seeded conversation | [ipad-task.png](ipad-task.png)                 |
| New task / system keyboard  | [ipad-new-task.png](ipad-new-task.png)         |
| Board / live mock reply     | [ipad-conversation.png](ipad-conversation.png) |
| Review after a follow-up    | [ipad-review.png](ipad-review.png)             |
| Machines                    | [ipad-machines.png](ipad-machines.png)         |

The tablet task form has scrolled to its focused prompt while the keyboard is
open. The journey uses the system's Hide keyboard control to submit the form
and to read the completed follow-up with the full transcript visible.

## Comparisons

[Boards](boards.png) and [conversations](conversations.png) place the Android
and iPhone captures side by side. Each full capture is proportionally resized
to the same pixel height, with captions added outside it. No app content is
cropped, repainted or synthesized. See [verification](../VERIFICATION.md) for
the current qualification status.
