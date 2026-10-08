# Compose mobile CI and preview delivery

Compose has additional gates in the existing `Qualification / Required checks`
result. The original app jobs and their release destinations remain in place.

| Gate                  | Runner                | Required work                                                                      |
| --------------------- | --------------------- | ---------------------------------------------------------------------------------- |
| Shared Compose mobile | Ubuntu                | JVM journey and navigation/observation regressions over an isolated gateway/daemon |
| Compose Android       | Ubuntu                | Debug APK and native instrumentation driver compilation                            |
| Compose iOS           | macOS 26 / Xcode 26.5 | One simulator build; native journey on isolated iPhone and iPad simulators         |

PR and main CI use the typed affected-change plan. Shared Compose screens select
all three gates; a platform host selects its own. Changes to the reused KMP core,
Apple transport and Android credential sources select affected Compose gates
alongside the original apps. Weekly and manual full CI require every gate.
Hosted Android compiles its driver; its emulator journey runs locally with an
explicit profile.

iOS reuses one build through the existing qualification loop. Source inputs,
Xcode, configuration, SDK and product hashes are verified before each layout.
Skipped assertions, missing runtimes and cleanup failures fail qualification.
Compose uses a separate unsigned Apple compiler cache, excluding app products,
credentials and fixture state. Toolchains, native actions, processes, leases,
fixtures and result qualification come from the existing Fastlane contracts.

## Preview delivery

After **all selected qualification gates pass**, main pushes and manual CI runs
on main deliver the Compose apps built by that run as GitHub Actions artifacts:

- `compose-android-preview-<SHA>-<attempt>`: `compose-android.apk` and `manifest.json`.
- `compose-ios-simulator-preview-<SHA>-<attempt>`: `compose-ios-simulator.zip` and
  `manifest.json`. The ZIP contains only `DieterComposeSpike.app`, for an
  **arm64 iOS simulator** (iPhone or iPad).

Download them from the successful CI run's **Artifacts** section. Delivered
previews last 14 days; staging artifacts last 7 days. Delivery downloads the exact
producer attempt and verifies source revision, app component, Debug configuration,
preview type and SHA-256 before uploading. It never rebuilds. Upload failures fail
delivery. Unrelated changes need not rebuild or deliver Compose previews.

These are Debug development previews using the repository's source-derived
SemVer and separate app IDs. They do not reserve shipping release identities or
change the nine shipping candidates. The Compose workflows have read-only
repository permissions and no publishing secrets. There is **no Compose IPA,
TestFlight or App Store Connect publishing**. The original iOS distribution
continues independently. Signed physical iOS and Android production distribution
remain future work.

Unzip the iOS preview, select an explicitly owned booted iOS 26.5 arm64 simulator,
then install and launch it:

```sh
xcrun simctl install <owned-simulator-UDID> DieterComposeSpike.app
xcrun simctl launch <owned-simulator-UDID> com.dbpprt.dieter.compose.spike.ios
```

No fixture session is baked into either app. Development gateways must allow
`dieter-compose://oauth/callback` and `dieter-compose-ios://oauth/callback`
for normal sign-in, as described in the spike README.

## Local equivalents

```sh
mise exec -- just pipeline compose_ci action:check component:core
mise exec -- just pipeline compose_ci action:check component:android
mise exec -- just pipeline compose_ci action:check component:ios
mise exec -- just pipeline compose_spike action:android_e2e profile:android-emulator
mise exec -- just pipeline compose_spike action:ios_qualify profiles:ios-iphone,ios-ipad
mise exec -- just pipeline compose_ci action:verify component:android artifact:<preview-directory>/manifest.json
mise exec -- just pipeline compose_ci action:verify component:ios artifact:<preview-directory>/manifest.json
```

Checks print their `tmp/app-pipelines/<UUID>` evidence path. Successful Android
and iOS checks stage a `preview/` directory there. Native results, screenshots,
timings and cleanup reports use the existing bounded CI diagnostic collector
(64 MiB maximum), separate from app artifacts.

Implementation: [qualification](../../.github/workflows/qualification.yml),
[checks](../../.github/workflows/compose-mobile-check.yml),
[delivery](../../.github/workflows/compose-mobile-deliver.yml).
