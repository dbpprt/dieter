# Apple release signing

Dieter's GitHub release workflow signs the Mac app, its embedded WebRTC framework,
the daemon, and its native capture helper with Developer ID Application. The
daemon installer uses Developer ID Installer. Both deliverables are submitted to
Apple's notary service; a submission must report `Accepted` before release work
continues. The app and installer carry stapled notarization tickets.

The separate, manually dispatched iOS workflow uses Apple Distribution signing
and an App Store Connect provisioning profile to produce an iPhone/iPad archive
and IPA. Uploading that build for TestFlight is optional. iOS does not use the Mac
Developer ID certificates or notarization service.

## Credentials dedicated to Dieter

Create fresh credentials for this repository rather than exporting a personal or
shared production signing identity:

1. Generate separate private keys and certificate requests for Dieter's Developer
   ID Application and Developer ID Installer certificates. Create both certificates
   in the Apple Developer account and export each certificate with its matching
   private key as a password-protected `.p12`.
2. Create an App Store Connect **team API key** named `Dieter GitHub Notarization`,
   with the minimum role needed for notarization. Retain its downloaded `.p8`, Key
   ID, and Issuer ID separately from other projects' keys.
3. Keep the original keys, exported certificates, and passwords outside the Git
   repository. The setup helper takes explicit paths and never discovers or
   exports an existing Keychain identity.

Developer ID certificates identify an Apple developer team; Apple does not limit
them to a single app or bundle identifier. These credentials are dedicated to
Dieter by how they are stored and used. Repository owners and collaborators who
can modify trusted release workflows can use them to sign code. This arrangement
lets Dennis Bappert (`dbpprt`) run Dieter releases through GitHub without access to
the Apple developer account. GitHub stores the secrets encrypted and does not
display their plaintext values in its settings.

See Apple's [Developer ID certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [notarization authentication documentation](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

## Configure Mac signing

The authenticated GitHub CLI account needs permission to manage Actions secrets
in `dbpprt/dieter`. Supply the dedicated files explicitly:

```sh
just release configure-apple-signing \
  --repo dbpprt/dieter \
  --platform macos \
  --application-p12 /private/path/dieter-application.p12 \
  --installer-p12 /private/path/dieter-installer.p12 \
  --notary-key /private/path/dieter-notarization.p8 \
  --key-id KEY_ID \
  --issuer-id ISSUER_UUID
```

The helper prompts for the two export passwords, validates the inputs before
uploading, and sends secret values to `gh` through standard input rather than
command arguments. Add `--check` to validate locally without contacting GitHub.

For `.p12` exports created with OpenSSL, explicitly use
`-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` with `pkcs12 -export`,
or export the dedicated identity through Keychain Access. OpenSSL 3's default
PBES2/AES encryption and SHA-256 MAC can pass OpenSSL validation while macOS
`security import` fails with `MAC verification failed during PKCS12 import`,
even when the password is correct. The helper rejects these incompatible
container algorithms before uploading. Re-export the same dedicated certificate
and matching private key with the explicit options; no new Apple certificate is
needed. These options concern the password-protected `.p12` container, not the
code-signing algorithm. The helper never rewrites the supplied credential files
or imports them into a local Keychain.

For `--platform macos`, it uploads these seven repository secrets:

| Secret | Contents |
| --- | --- |
| `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64` | Dedicated Application `.p12`, base64 encoded |
| `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Application export password |
| `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64` | Dedicated Installer `.p12`, base64 encoded |
| `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD` | Installer export password |
| `MACOS_NOTARY_KEY_BASE64` | Dedicated notarization `.p8`, base64 encoded |
| `MACOS_NOTARY_KEY_ID` | Notarization API Key ID |
| `MACOS_NOTARY_ISSUER_ID` | Notarization API Issuer ID |

Configure the full set before dispatching a release. Missing or partial
credentials fail the GitHub release signing gate; published Mac releases never
silently fall back to ad-hoc signing. Local development builds retain their
existing signing behavior. Existing Android and Homebrew credentials are
unaffected.

## Configure iOS signing and TestFlight

Create dedicated iOS credentials and an app record before configuring GitHub:

1. Register the explicit bundle ID `com.dbpprt.dieter.ios` in your Apple Developer
   team and create its iOS app record in App Store Connect. Use the same bundle ID
   throughout; `--ios-bundle-id` can override the default.
2. Create a fresh Apple Distribution certificate and private key dedicated to
   Dieter, then export them together as a password-protected `.p12`. The P12
   compatibility requirements above apply to this export too.
3. Create an **App Store Connect** provisioning profile for that bundle ID and
   distribution certificate. Download the `.mobileprovision` file. Development,
   Ad Hoc, and Enterprise profiles are not substitutes.
4. Create a dedicated App Store Connect **team API key** for Dieter iOS uploads,
   with an appropriate upload role. Save its `.p8`, Key ID, and Issuer ID. Keep
   this separate from the Mac notarization key.

The helper accepts explicit files; it does not search for credentials, export
Keychain identities, or create Apple account resources. Keep the originals and
password files outside the repository.

```sh
just release configure-apple-signing \
  --repo dbpprt/dieter \
  --platform ios \
  --ios-distribution-p12 /private/path/dieter-ios-distribution.p12 \
  --ios-distribution-password-file /private/path/dieter-ios-password.txt \
  --ios-provisioning-profile /private/path/dieter-ios.mobileprovision \
  --ios-api-key /private/path/dieter-ios-upload.p8 \
  --ios-key-id KEY_ID \
  --ios-issuer-id ISSUER_UUID \
  --ios-bundle-id com.dbpprt.dieter.ios
```

Omit `--ios-distribution-password-file` to enter the P12 password at the prompt.
Add `--check` to validate the supplied credentials locally without contacting
GitHub. `--platform` accepts `macos`, `ios`, or `all` and defaults to `macos`, so
existing Mac setup commands keep working. Use `all` with both sets of explicit
credential flags to configure both platforms together.

The iOS setup uploads these repository secrets:

| Secret | Contents |
| --- | --- |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Dedicated Apple Distribution `.p12`, base64 encoded |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Distribution export password |
| `IOS_PROVISIONING_PROFILE_BASE64` | Matching App Store Connect profile, base64 encoded |
| `IOS_APP_STORE_CONNECT_KEY_BASE64` | Dedicated upload `.p8`, base64 encoded |
| `IOS_APP_STORE_CONNECT_KEY_ID` | Upload API Key ID |
| `IOS_APP_STORE_CONNECT_ISSUER_ID` | Upload API Issuer ID |
| `IOS_TEAM_ID` | Developer team for the signing identity and profile |
| `IOS_BUNDLE_ID` | Explicit iOS app bundle ID |

Apple describes [creating an App Store Connect provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)
and [creating team API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

## Build and upload iOS

The `ios-testflight.yml` workflow runs only by manual dispatch. It has a
`version` input (default `0.1.0`) and an `upload` input (default `false`). The
workflow assigns a distinct build number using `run_number.run_attempt`, including
when rerunning a workflow. It does not upload on pull requests or pushes to
`main`, and it is independent of the automatic Mac release workflow.

GitHub enables manual dispatch after the workflow exists on the default branch,
so this workflow becomes available when the PR is merged. Retry the latest run
or dispatch a fresh run: an older run's retry can have a lower build number than
a newer uploaded build, which Apple may reject.
The release helper uses conservative four/two-digit bounds for the run and
attempt components and fails before signing if either exceeds them.

First run a build without uploading:

```sh
gh workflow run ios-testflight.yml --repo dbpprt/dieter --ref BRANCH \
  -f version=0.1.0 -f upload=false
```

This produces signed archive and IPA workflow artifacts for inspection. When
ready to upload a new build to App Store Connect, dispatch with `-f upload=true`.
The workflow uses `xcodebuild -exportArchive` with the `app-store-connect` method
and explicit signing credentials. It requires a supported Xcode version for App
Store Connect uploads; current iOS uploads require builds made with Xcode 26 or
later.

The underlying recipes are:

```sh
just ios signing-config
just ios archive-unsigned 0.1.0 1.1
just --yes ios testflight 0.1.0 1.1
just --yes ios testflight 0.1.0 1.1 --upload
```

`archive-unsigned` is a local device-architecture archive check and needs no Apple
credentials. It cannot be installed or uploaded as a signed distribution.
`testflight` is CI-only and uses the configured iOS secrets; without `--upload`,
it only archives and exports. Temporary decoded signing credentials are removed
when the recipe exits. Simulator tests and unsigned builds do not verify actual
App Store Connect acceptance or TestFlight distribution.

After upload, Apple must process the build. Complete any export-compliance and
beta test information in App Store Connect, then assign the processed build to a
TestFlight group and invite testers. External testing may require Beta App
Review. Upload success alone does not make a build available to testers. See
[Apple's upload requirements](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
and [TestFlight workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).

## Release and verify Mac

The `Release` GitHub Actions workflow runs after pushes to `main` and supports
manual dispatch. By default it builds and publishes the complete release,
including Android and Homebrew artifacts. To verify the Mac app, daemon, and
installer on a branch without publishing or changing Homebrew, clear **Publish**
in the Run workflow form, or run:

```sh
gh workflow run release.yml --repo dbpprt/dieter --ref BRANCH -f publish=false
```

This mode uploads signed and notarized Mac build artifacts to the workflow run;
it skips public release creation, retention changes, and Homebrew updates.

The Mac recipes are:

- `just --yes mac sign-notarize-release`: sign the framework and app with hardened
  runtime and timestamps, notarize, staple, validate, and assess with Gatekeeper.
- `just --yes daemon sign-notarize-macos`: sign and notarize the daemon and capture
  helper used by the existing Homebrew `.tar.gz`.
- `just daemon installer-macos`: build the daemon `.pkg` from staged binaries and
  `RELEASE_VERSION` without installing it.
- `just --yes daemon sign-notarize-installer-macos`: sign the installer, notarize,
  staple, validate, and assess with Gatekeeper.

Signing recipes run only in CI. Temporary decoded credentials are private to the
runner and removed when the recipe exits. `just release test` uses generated or
mock credentials and never touches an installed app or daemon.

## Daemon installer behavior

The signed `dieter-darwin-arm64.pkg` installs into
`/usr/local/libexec/dieter/VERSION/`. It leaves Homebrew paths, `PATH`, launchd
services, and running processes unchanged. An existing version directory is
rejected instead of overwritten. After installation, invoke the versioned CLI
explicitly, for example:

```sh
/usr/local/libexec/dieter/0.4.100/dieter --help
```

Starting or switching a daemon service remains a separate user action. The
Homebrew archive remains available for Homebrew-managed installations. Its loose
binaries are notarized, but the `.tar.gz` cannot carry a stapled ticket; use the
`.pkg` for a deliverable that supports offline ticket verification.
