# Compose mobile spike verification

This experiment exercises one shared mobile vertical slice against Dieter’s real
Go gateway and daemon, through the existing KMP client core. Native journeys use
an isolated account, enrolled daemon, persisted sample workspace and deterministic
mock harness. They require no provider credentials or operator service changes.

## Verified behavior

The shared JVM journey passed creation and temporary ID resolution, the first
assistant reply, a follow-up in the same durable conversation, Review observed
by a second client, and reopening persisted history. Two regression cases cover
late updates from a closed conversation and commands queued while navigation
changes. Evidence: `tmp/app-pipelines/44be2fa8-fe5c-483c-b384-7ce317d4646b`.

Pipeline contracts passed 146 tests and 707 assertions with no failures, errors
or skips, plus catalog lint. Evidence:
`tmp/app-pipelines/f981a405-facb-4257-9d4e-3af1973181f3`.
Gateway fixture tests and Go vet also passed.

The Android native journey passed `ComposeSpikeTest.sharedTaskJourney`, including
opening the seeded transcript, task creation, the actual first mock reply, a
follow-up assistant reply, moving to Review and machine navigation. All six
required screenshots were retained. Execution took 75.7 seconds; the preceding
incremental APK build took 3m31s on this loaded host. Cleanup passed, and the
owned warm emulator was then closed successfully. Evidence:
`tmp/app-pipelines/eabff2fc-8b58-40c2-ae07-5909429ac6cc`.

The iPhone native journey passed `ComposeSpikeUITests.testSharedTaskJourney`
on an iPhone 17 Pro / iOS 26.5 simulator. It opened the seeded transcript,
entered a title and prompt, created a real task, received its first mock reply,
typed a follow-up with the composer visible above the system keyboard, received
the second reply, moved the task to Review and opened Machines. XCTest took
62.5 seconds; the surrounding native execution took 137.7 seconds, and the warm
Xcode preparation/build took 88.4 seconds. All six screenshots were retained.
Qualification and cleanup passed. Evidence:
`tmp/app-pipelines/db231e8f-36a3-4b97-8985-ac0229cd84ec`.

The same XCTest journey passed on an iPad Air 11-inch (M3) / iOS 26.5 simulator
in landscape, additionally requiring a wide window and a visible board beside
the opened conversation. XCTest took 43.5 seconds; surrounding native execution
took 96.2 seconds and warm Xcode preparation/build took 63.9 seconds. All six
screenshots were retained. Qualification and cleanup passed. Evidence:
`tmp/app-pipelines/cdbbd83f-3994-4481-9778-bfda8e952f3b`.

Native verification caught two host integration problems: Compose's required
`CADisableMinimumFrameDurationOnPhone` setting was missing, and SwiftUI keyboard
avoidance combined with Compose's IME padding hid the composer. The host now
provides that plist key and leaves keyboard insets to Compose. XCTest uses
stable editor queries and drags within the visible area above the keyboard's
prediction row. It explicitly requires the composer to stay visible. No assertion
was removed or relaxed. Earlier failed evidence is retained. One preparation
also ran out of host disk space; its cleanup passed, space recovered, and the
complete iPhone lane then passed.

## Additional CI and preview pipeline verification

The added Compose CI/CD compositions passed locally on 2026-10-07:

- Workflow policy and pinned Actionlint validation passed:
  `tmp/app-pipelines/b9075fa7-12d3-4aa6-98bf-4d6254d69d08`.
- Pipeline contracts passed **152 tests / 753 assertions**, with no failures,
  errors or skips, plus catalog lint:
  `tmp/app-pipelines/33bc36fa-3db1-44ba-9ae7-d7fdf2e5f10c`.
- Affected-selection/result/fixture Go tests and Go vet passed. The final
  dependency-selector regression run is
  `tmp/app-pipelines/4724aead-88e0-40f6-895a-44d9b104dc7b`.
- The shared CI lane executed and passed all three JVM tests in a 33-second
  Gradle run: `tmp/app-pipelines/697dff58-3010-4f78-89e2-9dbaf870fc69`.
  Its cache now tracks the fixture binary and mock runtime sources so backend
  changes invalidate a previous test result.
- Android CI compiled the app and instrumentation driver and staged the APK
  preview; incremental Gradle execution took 64 seconds:
  `tmp/app-pipelines/13ce295f-6a8b-4fe7-9c61-64f342c24892`.
- iOS CI built once and reused verified products for both layouts. The iPhone
  XCTest took **51.0 seconds** and iPad XCTest **44.1 seconds**. Both qualified
  and cleaned up successfully:
  `tmp/app-pipelines/2967ae3a-6e60-4947-a61b-6b4e3da4ef13`.
  The resulting simulator preview is in
  `tmp/app-pipelines/5c773009-4273-4659-950e-b00844315cb1/preview`.
- Both preview manifests verified after copying the packages to new directories,
  exercising the same portable hash/source/component checks as delivery.
  Android verification: `tmp/app-pipelines/8f266123-3b18-497d-8681-a68715ed4625`;
  iOS verification: `tmp/app-pipelines/aba4b727-d759-4fa0-bf19-f5bf12f49d4e`.
  The 36.5 MB iOS ZIP contains only `DieterComposeSpike.app`, with no test bundles.
  Both task-owned simulator IDs were confirmed absent afterwards.

The workflows have not been pushed or executed on GitHub. Local validation
qualifies the lane behavior and workflow contracts; hosted cache transfer,
Actions artifact upload/download and runner availability await the first CI run.
No Compose IPA or TestFlight publication is configured. See
[CI and preview delivery](PIPELINES.md) for triggers, downloads and remaining
signing scope.

## Build cost

The iOS simulator framework, Swift platform adapters, app and XCTest bundle all
built successfully. Evidence: `tmp/app-pipelines/c98526d6-7f0f-4f22-897f-6842e79d5ee1`.
The first successful Kotlin/Native link took 12m19s; the complete run, including
cold Swift dependencies, took about 30 minutes on this 16 GB host under competing
build load. Warm framework checks subsequently took 6–11 seconds. These are local
observations, not CI performance promises.

The debug simulator app is about 130 MB and its static debug framework about
293 MB. These include debug code and symbols; release download size, launch time,
memory and scrolling performance have not been measured. The spike retains only
the eight extended Material icon vectors it uses, with their Apache attribution,
instead of linking the full extended icon library.

## Decision

Use shared Compose content and small native hosts for the mobile migration.
The iOS host calls SwiftUI’s real `glassEffect` API on iOS 26+; older systems use
system material and Reduce Transparency uses an opaque fallback. Android keeps
Material 3 controls. Credentials, certificate pinning and transports reuse the
existing platform implementations. No new daemon API or protocol fork is needed.

The code is opt-in and uses separate app identities. It is suitable for evolving
into a feature-by-feature migration, with the shipping clients as the parity
reference. See the [scope matrix](README.md#migration-decision-and-remaining-scope).

## Limits

This is a vertical spike. Screen streaming, terminal rendering, files and diffs,
schedules, rich attachments/Markdown, agent pickers, notification/background
services and share extensions are not migrated. The native system integrations
can remain native views or services injected through narrow platform interfaces.

Interactive OAuth callbacks, physical phones, direct TLS recovery, accessibility,
dark appearance and full shipping-app catalog parity require later qualification.
The fixture adopts an authenticated debug session; it does not simulate a complete
interactive OAuth sign-in. Seeded transcript content is sample data; new tasks
and follow-up replies are produced by the actual mock harness and durable daemon.

No production gateway policy, live daemon, release, or shipping app installation
was changed. Local experimental bytes use the canonical source release identity.
The owned Android emulator was closed after its passing journey; every owned
iOS simulator was shut down and deleted by its lane. Failed evidence remains
available in the worktree. This is qualification of the spike's vertical slice,
not the full shipping-app catalog.
