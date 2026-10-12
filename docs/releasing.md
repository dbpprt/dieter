# Releasing

Dieter ships one release for every component: the daemon and CLI, the gateway,
and the macOS, iOS and Android apps all carry the same version. Releases are
built, signed and published by GitHub Actions in this repository; a person
approves the steps that reach users.

## Versions

- Every release has one canonical SemVer, `MAJOR.MINOR.PATCH`
  (for example `0.4.413`), tagged `v0.4.413`. The release line (`0.4`) is set
  in [`fastlane/release-policy.json`](../fastlane/release-policy.json); the patch
  number is a counter that only increases.
- Android uses the counter as its version code. Apple build numbers encode the
  same counter in three components (1 → `1.0.0`, 413 → `1.4.12`,
  10,001 → `2.0.0`); the app version stays the canonical SemVer.
- The gateway publishes minimum client and daemon releases
  ([`deploy/gateway/compatibility-policy.json`](../deploy/gateway/compatibility-policy.json))
  and rejects older software. A breaking protocol change raises these floors
  in the same pull request instead of keeping a compatibility branch.

## Channels

| Channel                  | Produced                                                                   | Reaches                                                                               |
| ------------------------ | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Pull requests and `main` | Every push                                                                 | Unsigned build outputs attached to the CI run; no release                             |
| **dev** prerelease       | Nightly when `main` changed and is green, or on demand (workflow dispatch) | A GitHub prerelease with every artifact, plus a TestFlight build for internal testers |
| **stable**               | Promotion of one exact, tested dev release                                 | GitHub Latest, the Homebrew tap, the in-app and installer update feeds                |

- Dev releases never move GitHub Latest, Homebrew, update feeds or production
  services.
- **Stable is a promotion, never a rebuild.** The promotion workflow verifies
  the signed checksums and qualification of an existing dev release, then
  publishes those exact bytes. It runs in the protected `stable-release`
  environment, so a maintainer approves it.
- Dev releases are retained for a bounded time; stable releases are kept.

## Artifacts

A release contains the daemon/CLI archives for macOS arm64 and Linux
amd64/arm64 (each with its screen-capture helper; macOS also with the privacy
helper), the prebuilt harness runtime of each daemon platform, gateway binaries
for Linux amd64/arm64, the signed gateway container image and deployment bundle,
the notarized Mac app, `Dieter-Android.apk`, the iOS build in TestFlight, the
installer script, and `SHA256SUMS` with its signature.

Release daemons never run npm to install their harness runtime. On each daemon
platform the builder first runs `dieter __harness-runtime-archive` from a
development build of the same source: it installs the embedded runtime
(`npm ci --omit=dev --ignore-scripts`) and the managed Bun package exactly as a
daemon built from source would, writes
`dieter-harness-runtime-<os>-<arch>.tar.gz` (sorted entries, fixed times, root
ownership, normalized modes, and a manifest naming the runtime digest and the
`package-lock.json` SHA-256), and verifies it by installing it. The release
daemon is then linked with the archive's SHA-256 (`Dieter::Release.ldflags`) and
downloads exactly that file from its own release. Removing or replacing a
published archive breaks first runs and updates of that release.

## Signing identity

Release checksums are signed with [Sigstore cosign](https://docs.sigstore.dev/)
keyless signing by exactly one workflow identity:

```text
https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main
issuer: https://token.actions.githubusercontent.com
```

This is a **public security contract**. The Linux installer and the managed
Linux updater accept only this identity (`internal/platform/buildinfo`,
generated from [`config/identity.json`](../config/identity.json)). Renaming or
moving the workflow, or signing from another ref, breaks updates for every
installed daemon; it may only happen together with a compatibility floor bump
that tells old installations to reinstall. Anyone can verify a download:

```sh
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS   # macOS: shasum -a 256 --check --ignore-missing SHA256SUMS
```

Platform signing comes on top of that:

- **macOS:** Developer ID signing and notarization for the app, daemon, capture
  helper and privacy helper. Installed daemons trust only the team in
  `config/identity.json`.
- **Android:** the release keystore. The in-app updater also checks the APK's
  SHA-256 against the digest GitHub publishes.
- **iOS:** App Store Connect distribution, delivered through TestFlight.
- **Gateway:** cosign-signed image and deployment bundle with build provenance
  and an SBOM; verify with `deploy/gateway/scripts/bundle.py verify`.

## Distribution

- **TestFlight.** Dev and stable releases upload the retained IPA to App Store
  Connect and deliver it to the internal groups named in
  `config/identity.json`. An upload whose outcome is uncertain is reconciled,
  not repeated blindly.
- **Homebrew.** Stable promotion updates the `dieter` formula and `dieter-app`
  cask in the tap named in `config/identity.json`.
- **Gateway.** Releases never activate production. A separate protected
  workflow (`gateway-deploy.yml`, environment `gateway-production`) prepares a
  promoted stable gateway release for the operator's deployment controller; see
  [deploy/gateway/README.md](../deploy/gateway/README.md).

Native app builds, signing, notarization and store uploads use Fastlane's
built-in actions (`fastlane/Fastfile`); run a lane locally with
`just pipeline <lane>`. Local configuration can never change release policy.

## Repository configuration

Publishing jobs run only in the upstream repository; forks build but do not
publish. Signing secrets are available only to the jobs that sign for their
domain. Names, not values:

| Domain   | Secrets                                                                                                                                                                                                                                                                |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS    | `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`, `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`, `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID`, `MACOS_NOTARY_KEY_BASE64` |
| iOS      | `IOS_APP_STORE_CONNECT_KEY_ID`, `IOS_APP_STORE_CONNECT_ISSUER_ID`, `IOS_APP_STORE_CONNECT_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_PROVISIONING_PROFILE_BASE64`      |
| Android  | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`                                                                                                                                                                    |
| Homebrew | `HOMEBREW_TAP_TOKEN`                                                                                                                                                                                                                                                   |

Protected environments: `stable-release` (promotion) and `gateway-production`
(gateway deployment preparation). Configure required reviewers on both. Branch
protection on `main` requires the `ci-ok` check; changes land through squash
merged pull requests.

## Cutting a release

1. Make sure `main` is green.
2. Wait for the nightly dev release, or start one from the release workflow's
   **Run workflow** button.
3. Test the dev release (TestFlight, APK, Homebrew-free installs from the
   release page).
4. Run the promotion workflow with the dev tag and approve the
   `stable-release` environment.
5. If the gateway changed, prepare its deployment through `gateway-deploy.yml`
   and admit it through the deployment controller.
