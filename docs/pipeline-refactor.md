# Pipeline refactor

The developer and CI interfaces use the same pinned Fastlane lanes. Platform
tools execute their own tests; Dieter owns exact targets, fixtures, leases,
qualification, and immutable release identity.

## Evidence and priorities

The October 4 audit measured 690.71 seconds compiling the Mac SwiftPM package
to execute 13 iOS policy tests in 0.291 seconds. Release separately repeated CI
checks, and each iPhone/iPad worker rebuilt the same simulator products. An iPad
gate passed its tests and then failed artifact creation with `ENOTFOUND`. Failed
iPhone attachments included 32 MiB of video. Candidate evidence also included
archives and copies of the separately retained producer checkpoint.

1. Stream sanitized compiler/test output and retain bounded, explicit evidence.
2. Qualify each main revision once before calling the existing immutable release
   workflow. Keep affected selection for PRs and full qualification for releases.
3. Prepare iOS simulator products once and qualify both layouts on the same
   worker, under the existing build lease. Verify the product manifest before
   reuse. Separate portable policy tests from the full Mac application package.
4. Use Fastlane `run_tests` and `build_app` for XCTest and distribution archives,
   inside owned subprocesses with deadlines. Preserve private launch files,
   structured result qualification, and exact-device lifecycle management.
5. Make local verification select fast checks by default, with device work
   explicitly selected. Document the shared modules and update operating skills.

## Verification budget

During implementation, inspect syntax and run only tests for a changed contract
when needed. At the integration boundary, run the Ruby pipeline contracts,
affected Go pipeline packages, workflow lint, and affected Python helpers once.
Run a focused iOS policy check and one simulator case through the new Fastlane
adapter, then verify product reuse on the second layout. Do not run repository-
wide Go, Android, Mac UI, screen/performance, or distribution tests repeatedly.
Record unavailable native environments explicitly and preserve operator apps.

## Research

The implementation uses the pinned Fastlane 2.240.1 action contracts, rather than
assuming current documentation matches an installed release:

- [run_tests](https://docs.fastlane.tools/actions/run_tests/): build-for-testing,
  test-without-building, explicit destinations, xctestrun, and native results.
- [build_app](https://docs.fastlane.tools/actions/build_app/): archive/export,
  manual profile mapping, explicit version settings, and existing signing.
- [GitHub reusable workflows](https://docs.github.com/en/actions/sharing-automations/reusing-workflows):
  qualification and release dependencies in the same run avoid duplicate checks
  and do not require trusting an unrelated workflow's artifacts.
- [upload-artifact](https://github.com/actions/upload-artifact): separate compact
  evidence from immutable product checkpoints; avoid compressing binaries twice.

## Release boundaries

Every main revision still reserves one canonical numeric SemVer and native build
counter. Candidates build/sign once; reruns recover their retained exact bytes.
TestFlight consumes the retained IPA. Stable promotion remains protected and
separate. No refactor command installs over the daemon or activates production.

## Implemented flow

`just check-changed` selects fast local checks and lists related native work
separately. Explicit named profiles select emulators, simulator layouts or exact
physical devices. Both local and CI use the same pinned Fastlane implementation.
The catalog preserves the platform-native assertions and standardizes admission,
fixtures, results and cleanup.

PRs and main qualify affected components. Main qualifies once, then calls
Release in the same workflow run. iPhone and iPad share one verified simulator
build. Kotlin Apple assertions, Mac Swift integration and portable iOS policies
have separate owners, avoiding duplicate tests across the Apple jobs. Scheduled
and manual full runs retain the complete Mac and iOS functional catalogs.

Fastlane owns XCTest commands and iOS archive/export. Shared modules own process
deadlines, sanitized streaming, leases, product integrity and evidence. Diagnostic
uploads are capped at 64 MiB and record omissions; producer checkpoints remain
mandatory and separate. CI summaries include cases and the ten slowest operations,
including shared builds. A diagnostic upload outage does not invalidate passing
tests or require repeating them.

## Verification results

The integration boundary passed the Ruby pipeline contracts (95 tests, 471
assertions), affected Go pipeline packages, workflow contracts/actionlint, and
the 71-case catalog lint. Subsequent changes were checked with focused contracts
for cleanup, product integrity, selection, release-checkpoint provenance,
Fastlane options and evidence. Four repository skills passed validation.

The portable iOS policy check passed all 13 assertions. Its first Kotlin framework
preparation took 6m32s, the smaller Swift graph built in 118.15s, and assertions
ran in 0.397s. These are separate preparation and execution costs; they are not a
claim about hosted CI wall-clock improvement.

The focused native command was:

```sh
just pipeline ios_qualify profiles:ios-iphone,ios-ipad cases:ios.credentials
```

It passed three credential assertions on each layout, using the same verified
simulator products. The group, iPhone and iPad cleanup reports all passed; no
owned pipeline simulators remained.

| Phase | Measured time |
| --- | ---: |
| One cold shared Xcode build | 18m11s |
| iPhone product verification, fixture preparation and simulator boot | 76.6s |
| iPhone credential case, including XCTest startup | 72.1s |
| iPad product verification, fixture preparation and simulator boot | 51.2s |
| iPad credential case, including XCTest startup | 65.9s |

The full group took about 23 minutes on this host with two build jobs. Compilation,
product verification, simulator boot and XCTest startup dominate tiny assertion
bodies. Reusing products removes the second compilation; it does not remove
those other costs. The retained evidence is
`tmp/app-pipelines/75ca2c32-daf0-4503-83e9-c278a265c93e`.

An earlier attempt failed before assertions because Fastlane's build-settings
query exhausted its short default retries and left descendant output pipes open.
The adapter now allows one bounded 120-second settings query, and owned-process
cleanup handles descendants after their parent exits. Focused regression tests
passed before the successful native run; no full E2E catalog was repeated.

Local verification used Xcode 27.0 and iOS 26.5 simulators. Hosted Xcode 26.5,
physical-device qualification, distribution signing, TestFlight and stable
promotion were not executed. Release behavior was checked through contracts;
no release or production service was mutated. The first hosted run must confirm
runner-specific behavior. When adopting the workflows, update branch protection
to require **Qualification / Required checks** instead of retired reporter jobs.

AGENTS.md, contributor/platform guides and the native/CLI skills now document
the focused verification budget. The new Dieter pipelines skill owns pipeline
development and diagnosis.

## Live release continuation

The user authorized publishing this refactor to main and completing the Fastlane
card's release work here. Card `c_5def4a1b1001ac17eec839bf` had passed hosted
qualification on `6c23aede`, but all nine candidate producers failed before builds:
relative identity inputs resolved from Fastlane's working directory. Its retained
fixes and three regressions were imported through the Dieter CLI into this
worktree. All three path-boundary tests passed (10 assertions).

The release workflow chain also now grants `actions: read` where candidate
checkpoints and completed claim-owner runs must be inspected. Its contract passed
(11 assertions), and workflow lint passed. Existing assertions are not repeated
locally before publishing; the new main run owns hosted qualification and release
verification.

## Ten-minute feedback target

The full hosted run on `46aeaa91` passed all qualification assertions and cleanup.
macOS took 26m21s, including 10m44s Swift test compilation, a separate 5m53s app
compilation, and about 4m37s native cases. iOS took 69m12s: roughly 17 minutes of
cold policy/framework/app preparation, followed by sequential iPhone/iPad catalogs
and simulator preparation. `ios.remote-node` alone took 6m29s on iPhone and
10m30s on iPad; its native methods used 339s and 560s respectively. This is real
test execution, not artifact transfer. Other job durations were Kotlin JVM 2m05s,
Kotlin Apple 5m20s, Go/harness 10m02s and Android 12m36s. Portable/Android/core
diagnostics were only about 3–12 KB.

Routine PR/main checks now use affected selection and the explicit
typed portable check/package plan (including reverse Go dependencies), rather
than running every portable suite whenever any portable input changes. The
`ios.connecting` journey on both layouts, while full scheduled/manual qualification
retains every functional assertion. Hosted Apple qualification shares the Mac
test/app compilation graph and caches unsigned compiler/dependency state. The
ten-minute target applies to warm required-check feedback; the first cache fill,
broad core/schema changes and full catalogs can exceed it. Further work should
measure warm transfer/build costs before choosing persistent isolated Apple
workers, batching compatible XCTest launches, or splitting full layout execution
across workers. Signed distribution and Apple's processing time remain separate.

The run also exposed GitHub's transitive skipped-job behavior: the successful
reservation followed a skipped manual-qualification job, so candidate jobs were
skipped. Explicit status conditions now admit producers only after successful
reservation, and a required release gate rejects missing/skipped/failed producer,
publication or dev delivery stages. A green qualification run alone is not proof
of release delivery.

The `beb14c07` hosted run passed all required component/native checks and cleanup.
Routine portable qualification took 1m40s (115 contracts / 569 assertions), and
Android took 6m02s. The Mac app build reused its test graph: 1m35s rather than
5m53s, while its cold initial Swift compile took 14m18s. Apple compiler caches
were retained; this first cold run does not establish a warm feedback time.
Both iOS layouts passed the connection journey. Five server binaries and Android
then passed candidate production. OCI production exposed an unsupported ORAS
`--workdir` argument: relative artifact inputs now use the owned child process's
working directory, preserving layer basenames without changing Ruby's global cwd.
