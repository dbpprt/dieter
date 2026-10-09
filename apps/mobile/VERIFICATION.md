# Compose mobile design-port verification

The opt-in hosts in `apps/mobile/android` and `apps/mobile/ios` port the shipping
Android presentation onto the existing KMP client core in `apps/core/mobile`.
The shipping apps remain in `apps/android` and `apps/ios`. Compose has separate
app identities and additional CI gates, with no TestFlight publishing.

Native journeys use a disposable authenticated Go gateway, enrolled daemon,
persisted workspace and deterministic mock harness. New tasks and follow-up
replies pass through the actual daemon; seeded history is sample data. The
[gallery](design/index.html) contains 48 native captures of the redesign below and
links to the 17 legacy reference captures. Originals and their hashes are retained in
[capture provenance](screenshots/provenance.json).

## Native platform redesign (8 October 2026)

The shared screens now sit in each platform's own navigation instead of one
Material-styled shell:

- **iOS:** `DieterComposeHost` hosts each route in a UIKit `UITabBarController`
  and per-tab `UINavigationController`s, with a sidebar and split view on iPad.
  Bar buttons, `UIMenu`s, sheets, alerts and toasts are native; Compose draws
  content with iOS system colors, Dynamic Type sizes and SF Symbols.
- **Android:** Material 3 top app bars, extended FAB, navigation bar and rail,
  list and detail side by side from 840 dp, dynamic color, system back and
  edge-to-edge bars.
- **Shared:** per-tab navigation stacks in `Navigation.kt` bind core scopes
  (board, project, conversation, files, terminals, telemetry) to the visible
  routes on both platforms.

| Check                                                                              | Result                                             | Evidence                                                 |
| ---------------------------------------------------------------------------------- | -------------------------------------------------- | -------------------------------------------------------- |
| Shared Compose: seven JVM tests, including navigation-stack binding, final sources | Passed                                             | `tmp/app-pipelines/a6415c42-0080-4bc2-88b9-e598d508f155` |
| Android pipeline: 16-view journey, Activity recreation and dark system bars        | Passed; native test 50.489 seconds, cleanup passed | `tmp/app-pipelines/99f6fd02-42e9-4dbb-9678-af5f2b59b6c6` |
| Android app and test APKs after formatting and unused-icon removal                 | Built                                              | `tmp/app-pipelines/2494b46b-cd1a-4047-aeb9-76f96e9501d7` |
| iPhone 17 Pro / iOS 27.0, portrait: the same XCUITest journey                      | Passed; 130.865 seconds, after the fixes below     | Local run, see below                                     |
| iPad Pro 11-inch (M5) / iOS 27.0, landscape sidebar and split view                 | Passed; 126.162 seconds, after the fixes below     | Local run, see below                                     |
| Android tablet layout (2560 × 1600 at 320 dpi): rail, board list and conversation  | Inspected manually                                 | Not retained                                             |

The iOS journeys ran `ComposeSpikeUITests/testSharedTaskJourney` against fresh
isolated gateways, enrolled daemons and mock harnesses, with app data reset per
run, from a build on an external volume. `compose_spike action:ios_qualify` was
not run: the internal disk had 9 GB free and an earlier run of that lane ran out
of space. The iOS results are therefore not pipeline-qualified and have no
ownership journal; rerun that lane before relying on them.

Regressions found and fixed during this round:

- A new task opened under its temporary card ID and stayed on a spinner once
  the server ID arrived. Routes now resolve outbox IDs before rendering.
- The transcript's follow-to-bottom scroll could run during a layout pass and
  crash Android (`performMeasureAndLayout called during measure layout`); it now
  requests the scroll for the next measure.
- A navigation update that arrived while UIKit was popping a screen pushed that
  screen back (seen as a lost back tap after "Move to Review"). Stack syncs now
  wait for the transition and reapply the latest state once the pop is recorded.
- iPad columns and the tab sidebar report their overlap as safe area; screens
  now respect horizontal insets instead of drawing under neighbouring columns.
- iPad detail columns opened tools by pushing onto the previous tool; list rows
  now replace the detail. A Monochrome sidebar selection was white on white in
  dark mode, and the empty detail column now explains each tab.
- Android: dark system bars stayed light after Activity recreation, lane tabs
  squeezed their count badges in narrow panes, the rail duplicated New task, and
  three generated icons (Badge, Palette, Speed) were missing their arcs.

## Port qualification (7 October 2026)

| Check                                                                                                | Result                                                                                                                                        | Retained evidence                                                                                                     |
| ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Legacy Android audit: 11 selected instrumented cases, 17 captures                                    | Passed                                                                                                                                        | `apps/mobile/design/legacy-android/provenance.json`                                                                   |
| Shared Compose: six JVM integration/regression tests                                                 | Passed; no failures, errors or skips                                                                                                          | `tmp/app-pipelines/43bb9009-85b1-4a14-84f8-796a4933e3ae`                                                              |
| Existing KMP core: 709 tests in 107 suites                                                           | Passed; no failures, errors or skips                                                                                                          | `tmp/app-pipelines/5abade07-ce7a-45d3-adbe-d9297a07163c`                                                              |
| Shipping Android build after GPU/WebRTC reuse                                                        | Passed                                                                                                                                        | `tmp/app-pipelines/9a30f7fb-8e37-499d-a83a-b3ad780d425e`                                                              |
| Shipping Android: 28 unit tests in eight suites, plus lint                                           | Passed; lint has 0 errors, 72 warnings and 6 hints                                                                                            | `tmp/app-pipelines/2672a18c-23ed-47d1-9692-c591bed82dac`                                                              |
| Final Android: 16-view journey, form/draft Activity recreation, dark system bars and all captures    | Passed; native test 47.456 seconds, cleanup passed                                                                                            | `tmp/app-pipelines/9bbc763c-5eec-4ad2-abb8-0fbc1d02b98c`                                                              |
| Warm Android emulator ownership and graceful closure                                                 | Passed; owner and stop command exited successfully, cleanup passed                                                                            | `tmp/app-pipelines/55a743f4-ce54-479e-a164-dbb840ee588f`                                                              |
| Final iPhone and landscape iPad: one verified build, both complete 16-view journeys and all captures | Passed; native tests 86.655 and 78.501 seconds, both cleanups passed                                                                          | `tmp/app-pipelines/1a42816f-6dfb-4664-a7fc-b30ab46df1ff`                                                              |
| Shipping iOS build after shared renderer extraction                                                  | Passed; app and test bundles, cleanup passed                                                                                                  | `tmp/app-pipelines/b6f90a5d-a8dc-4b7b-b007-99841651a9de`                                                              |
| Apple core native and isolated transport integration                                                 | Passed: 631 native core tests, one binding test and two isolated Swift integration journeys; cleanup passed                                   | `tmp/app-pipelines/77fdb73f-f306-42d9-8db2-b1565594977e`                                                              |
| Shipping Mac unit tests after shared-source extraction                                               | Passed: 446 Mac tests, 16 shared adapter tests, 13 iOS policy tests and three XCTest cases; conditional skips described below; cleanup passed | `tmp/app-pipelines/59f57081-2510-46cf-83b9-161d41ef1e94`                                                              |
| Final pipeline contracts: 152 tests, 753 assertions                                                  | Passed; no failures, errors or skips                                                                                                          | `tmp/app-pipelines/409e3c90-358e-4f9b-b5f7-dc64848764fd`                                                              |
| Fixture and affected-selector Go tests, plus Go vet                                                  | Passed                                                                                                                                        | `tmp/app-pipelines/ee4a3d7c-38f1-44f7-b69f-9cb218a63161` and `tmp/app-pipelines/d782d550-a7f3-4b6b-bb24-61636afa9ad6` |

The six shared tests cover a real durable conversation, temporary-ID resolution,
first/follow-up replies, cross-client Review and history, closed-scope updates,
queued command IDs, terminal delta retention, stale creation previews and draft/
file-buffer preservation. They also open the actual README file and load the
schedule list, guarding against binding a slice without loading it.

Each native journey opens Inbox, Projects, board/cards, seeded transcript,
subagents, task creation, actual live replies, Review, Chats, Tools, Machines,
Files, Markdown preview, Schedules, dark Settings and the dark board. Android
recreates the Activity before task submission and before sending a follow-up.
iOS requires the creation header and composer to stay reachable with the system
keyboard open. iPad additionally requires landscape and a visible board beside
the conversation. XCTest queries distinguish wide lane headers/card counts from
compact lane tabs; they require the same underlying content.

The legacy audit includes focused component fixtures and isolated app journeys
running shipping Android sources. Its selected cases qualify those assertions;
they are not the full shipping Android gate. See [the port inventory](DESIGN_PORT.md).

## Regressions found and corrected

- Files and Schedules bindings need explicit load commands. Project Changes
  needs reactivation after binding; conversation files need the actual project ID.
- Failed or conflicted file saves retain a dirty buffer; only a successful
  document result marks it clean.
- iOS canvas-layout callbacks must not increment the observed layout revision,
  which otherwise causes repeated layout. Explicit toolbar zoom/fit still does.
- Terminal special keys use each native renderer's actual application-cursor mode.
- Monochrome explicitly defines Material selection-container colors, preventing
  default purple navigation/chip colors from leaking into the legacy palette.
- Android owns the core/session in an AndroidViewModel, retaining forms and
  drafts across Activity recreation. The window and system bars follow appearance.
- Task creation keeps its header outside the scrolling form. Compose owns iOS
  keyboard insets and disables whole-host focus panning; title/prompt editing and
  the conversation composer pass on both layouts.
- Public SwiftPM dependencies use Fastlane's supported netrc provider. Both iOS
  hosts use the pinned-package plugin-validation flag already used by shipping iOS.

Failed evidence remains retained. Files and Schedules initially failed in
`dd2f67a2-69a8-4e0b-8075-4f20948be964` and
`1369f161-db8b-4875-9ecf-d9a670ca7ba0`; the final journeys pass both. The iOS
link ran out of disk in `edc69447-d963-42cc-9734-89342fb39acb`, and plugin
validation failed in `62bdf878-cf04-4261-add5-d483d2c1e7a2`. Native keyboard/
layout/query failures are retained in `a4713cd1-6e5d-4895-ba77-35ee7ffcc759`,
`28b02648-d7fc-4fce-9762-ac42e27d005b` and
`08d590f6-b64e-4f79-89a2-a621ab2c3f3a`. An earlier Android run passed assertions
but lost its timed-out warm owner; `8f1aa511-27f1-4780-ad33-ec9ba2a11e2b` failed
cleanup and does not qualify. The final owner and journey both passed cleanup.
All IDs above are under `tmp/app-pipelines/`.

A software-rendered Android boot again showed the known System UI ANR before
admission. The inspected Wait control was tapped and a second UI dump verified
launcher focus before the final native journey; app assertions were unchanged.

The first Swift integration build reached the Mac app link, which failed with
`errno=28 (No space left on device)` in
`tmp/app-pipelines/8369f531-8aab-40b2-891e-10d0a71a6358`. Native Kotlin tests had
passed and the shared Swift sources compiled. Available space recovered after
that process exited; the incremental retry passed both Swift integration
journeys. Compiled caches and failed evidence were preserved.

The first complete Mac unit run in
`tmp/app-pipelines/2aac6fe8-b462-49fb-8897-c51339a781bf` failed the unchanged
`productionBoardWithSixtyFiveCardLaneSettlesInAHostedView` timing assertion:
16.176 seconds against a five-second limit. Its isolated retry in
`tmp/app-pipelines/ca259c5a-2319-4649-be79-9418b5cc2e54` passed in 1.317 seconds;
both runs passed cleanup. The initial failure and process sample are retained.
The complete retry above passed, including that board assertion in 0.606 seconds.
The final read-only Mac inventory reported Dieter stopped; no task-owned app or
emulator remains running.

The Mac unit lane conditionally skips two isolated transport integrations,
two opt-in diagnostics and seven screen/media fixture tests. The two transport
integrations passed separately in the Apple core lane above. The diagnostics
and screen/media matrix are outside this spike's qualification; skipped cases
are not counted as qualified assertions.

## CI and qualification scope

The added CI/preview compositions were locally qualified before this design port:
workflow policy and Actionlint, contracts, affected selectors, shared CI tests,
Android APK preview, iPhone/iPad simulator preview and portable manifest
verification. See [CI and preview delivery](PIPELINES.md). Hosted Actions execution,
artifact transfer and runner performance are separate from local validation.

The implementation includes rich transcripts, creation/agent options,
files/editor/history, Git diffs/operations, schedules, administration,
telemetry/quotas, native terminals, screen rendering/input and native pickers/
previews. A compiled control or screenshot does not qualify every action.

Physical devices, interactive OAuth, full screen/media hardware behavior,
native picker/attachment journeys, VoiceOver/TalkBack, release size/performance
and complete shipping catalogs remain cutover requirements. Lane dragging
supports moves; production reordering, ghost/autoscroll polish and screen
modifier/resolution controls remain less complete than shipping. Background
services, notifications, widgets, share extensions and updating remain in the
original hosts. Activity recreation is tested; broader process-death restoration
is not qualified by that test.

Native tests inject an authenticated debug fixture session into the separate
spike apps. They do not change production OAuth policy, install over a shipping
app or restart the operator daemon. Owned device cleanup is mandatory.
