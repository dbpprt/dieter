# Apple release signing

Dieter's GitHub release workflow signs the Mac app, its embedded WebRTC framework,
the daemon, and its native capture helper with Developer ID Application. The
daemon installer uses Developer ID Installer. Both deliverables are submitted to
Apple's notary service; a submission must report `Accepted` before release work
continues. The app and installer carry stapled notarization tickets.

The iOS candidate uses Apple Distribution signing and explicit app/Share
provisioning profiles to produce an iPhone/iPad archive and IPA. Main publishes
a dev release and distributes that exact retained IPA to internal TestFlight
testers. Manual draft assembly retains the candidate for review. iOS does not use the Mac
Developer ID certificates or notarization service.

## Rotate Mac signing to Dennis Bappert's team

The target Mac signing team is Dennis Bappert (`FNGU8JFNPL`). Earlier releases
used Michael Ermer's team (`DS6N5L85E7`). The daemon's fixed service runtime
checks the signing team before activation, so uploading new GitHub secrets
alone is insufficient for existing Homebrew services.

1. Produce a bridge candidate containing the team-rotation verifier with the
   existing Mac credentials. Promote that retained candidate through
   `release-promote.yml`, then update and activate it on existing Mac
   daemon installations before staging a release signed by the new team. An
   older service executable rejects the new team's pending pair before it can
   execute the candidate. This is an operator rollout step; credential setup
   must never restart a running daemon.
2. Create dedicated Developer ID Application and Installer certificates and a
   notarization team API key under `FNGU8JFNPL`, then configure the seven Mac
   secrets below. The Mac app and daemon use the same credentials and rotate
   together. Keep iOS credentials separate.
3. Dispatch `release.yml` on main with `channel=draft` to verify and retain the
   new signed Mac candidates without TestFlight distribution or stable
   promotion. Candidate production is restricted to trusted main; PR CI checks
   the migration without access to signing keys. Replacing repository secrets
   does not change retained candidates. Never rerun a consumed identity to
   obtain a different signature: reserve a new source revision after rotation.

During the transition, the service verifier accepts a complete daemon/helper
pair signed by either named team. It rejects mixed-team pairs, unrelated teams,
unsigned code, and invalid signatures. The former signer remains trusted for
bridge activation and rollback; remove that trust in a subsequent release
after the fleet has migrated and no rollback needs the former signer. This
transition does not preserve macOS privacy grants across developer teams;
operators may need to grant Screen Recording and Accessibility again.

The permission-retention acceptance script targets `FNGU8JFNPL`; both of its
input releases must use that team. It tests updates within the new team, not
privacy-grant retention across the rotation.

The Linux gateway and Linux daemon use GitHub Actions OIDC/Sigstore signatures
from `dbpprt/dieter`, including signed release checksums, gateway images and
deployment manifests. They do not use Apple Developer ID certificates or
notarization credentials. Updating Apple secrets does not rotate their signer.

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
lets collaborators run Dieter releases through GitHub without access to the
certificate provider's Apple developer account. GitHub stores the secrets
encrypted and does not display their plaintext values in its settings.

See Apple's [Developer ID certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [notarization authentication documentation](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

## Configure Mac signing

The authenticated GitHub CLI account needs permission to manage Actions secrets
in `dbpprt/dieter`. Supply the dedicated files explicitly:

```sh
python3 -m fastlane.lib.dieter.native.apple_credentials \
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

1. Register the explicit bundle ID `com.dbpprt.dieter.ios`, its
   `com.dbpprt.dieter.ios.share` Share extension, and the
   `group.com.dbpprt.dieter.ios` App Group in your Apple Developer team. Enable
   that App Group on both App IDs, and create the main app's iOS record in App
   Store Connect. Use the same base bundle ID throughout; `--ios-bundle-id` can
   override the default and derives the extension and App Group identifiers.
2. Create a fresh Apple Distribution certificate and private key dedicated to
   Dieter, then export them together as a password-protected `.p12`. The P12
   compatibility requirements above apply to this export too.
3. Create **App Store Connect** provisioning profiles for both bundle IDs and
   the distribution certificate. Both profiles must include the derived App
   Group. Download both `.mobileprovision` files. Development, Ad Hoc, and
   Enterprise profiles are not substitutes.
4. Create a dedicated App Store Connect **team API key** for Dieter iOS uploads,
   with an appropriate upload role. Save its `.p8`, Key ID, and Issuer ID. Keep
   this separate from the Mac notarization key.

The helper accepts explicit files; it does not search for credentials, export
Keychain identities, or create Apple account resources. Keep the originals and
password files outside the repository.

```sh
python3 -m fastlane.lib.dieter.native.apple_credentials \
  --repo dbpprt/dieter \
  --platform ios \
  --ios-distribution-p12 /private/path/dieter-ios-distribution.p12 \
  --ios-distribution-password-file /private/path/dieter-ios-password.txt \
  --ios-provisioning-profile /private/path/dieter-ios.mobileprovision \
  --ios-share-provisioning-profile /private/path/dieter-ios-share.mobileprovision \
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
| `IOS_SHARE_PROVISIONING_PROFILE_BASE64` | Matching Share extension App Store Connect profile, base64 encoded |
| `IOS_APP_STORE_CONNECT_KEY_BASE64` | Dedicated upload `.p8`, base64 encoded |
| `IOS_APP_STORE_CONNECT_KEY_ID` | Upload API Key ID |
| `IOS_APP_STORE_CONNECT_ISSUER_ID` | Upload API Issuer ID |
| `IOS_TEAM_ID` | Developer team for the signing identity and profile |
| `IOS_BUNDLE_ID` | Explicit iOS app bundle ID |

Apple describes [creating an App Store Connect provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)
and [creating team API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

## Build and distribute iOS

Every main push runs the shared component checks, reserves one canonical numeric
SemVer and native counter, and prepares nine immutable candidates. The iOS
candidate uses Fastlane `build_app` to archive/export with explicit profiles and
a private temporary keychain. Both profiles must match the bundle IDs, team,
distribution certificate and shared App Group. Apple builds use the valid
three-component encoding of the reserved counter described in
[the pipeline guide](../fastlane/README.md).

Release assembly signs all candidate hashes and publishes a **dev** GitHub
prerelease. Distribution downloads the retained `Dieter-iOS.ipa`, verifies its
hash/version/build, reconciles upload and Apple processing, and verifies actual
internal TestFlight group membership. An accepted or uncertain upload is never
blindly reuploaded. Existing internal testers receive the new build; external
Beta App Review and invitations remain separate account administration.

```sh
# Reconcile distribution of an existing pipeline release; never rebuild its IPA.
gh workflow run ios-testflight.yml --repo dbpprt/dieter --ref main -f tag=v0.4.413
# Retain a main candidate as a draft rather than publishing/distributing it.
gh workflow run release.yml --repo dbpprt/dieter --ref main -f channel=draft
```

The release event and manual TestFlight workflow use the same idempotent
adapter. Main calls it explicitly because releases created with `GITHUB_TOKEN`
do not trigger another Actions workflow. Simulator tests verify UI behavior;
store processing and group delivery have their own recorded receipts.

For local compilation and isolated UI qualification:

```sh
just pipeline ios build
just pipeline ios e2e profile:ios-iphone suite:functional
just pipeline ios e2e profile:ios-ipad suite:functional
```

Physical iOS requires exact UDID, existing isolated development identities,
profiles and a reachable authenticated TLS fixture route in ignored
`fastlane/local.json`. Distribution credentials never replace development
signing. The credential validator remains independently callable for explicit
setup/checks; it is not a build or upload launcher.

## Release and verify Mac

Main creates dev releases with signed/notarized app, daemon archive and installer.
Fastlane owns keychain setup, signature verification, notary submission,
stapling and Gatekeeper assessment. Required signing credentials fail closed;
main never advances Latest, Homebrew, stable updaters or production services.

`release-promote.yml` promotes a verified retained candidate through the protected
`stable-release` environment. It checks live TestFlight delivery, updates the tap,
signs the promotion receipt and advances Latest without rebuilding. Configure
environment reviewers and main-branch restrictions before using promotion.

Temporary decoded credentials and provisioning profiles are private and restored
or removed at cleanup. Signing leases protect the host keychain/profile search
paths. Regression checks use disposable/generated material:

```sh
just pipeline check component:portable operation:contracts
just pipeline check component:portable operation:support_tests
```

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
