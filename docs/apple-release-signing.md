# Mac release signing

Fastlane signs the Mac app, its embedded native code, the daemon, capture helper,
and `DieterPrivacyHelper.app` with Developer ID Application. The daemon installer
uses Developer ID Installer. Apple's notarization service must accept the
submitted software before the candidate is retained; the installer and Mac app
carry stapled tickets. Candidate production runs only on trusted main.

## Signing team rotation

The target Mac signing team is Dennis Bappert (`FNGU8JFNPL`). Earlier releases
used Michael Ermer's team (`DS6N5L85E7`). The fixed service runtime verifies the
team before activation. During the transition, an entire daemon/capture/privacy
helper release must have valid Developer ID signatures from one of those teams.
Mixed teams, unrelated signers, unsigned code and invalid signatures are rejected.
The previous signer remains temporarily trusted for activation and rollback;
remove that trust after the fleet migration and rollback window.

The seven Mac repository secrets below have been rotated to Dennis's dedicated
credentials. The notarization team API key is named `Dieter GitHub Notarization`
and has the Developer role. The daemon and Mac app share these credentials;
iOS credentials are separate.

Before rotating an existing service, the preferred sequence is to release and
activate a bridge containing the verifier change while the old signing
credentials remain available. The old installed executable rejects a new-team
pending release before it can execute it. If credentials have already rotated
and no old-team bridge exists, automatic activation from that executable cannot
perform the handoff. An operator must install a fully verified new-team release
through a reviewed service migration. Never weaken signature verification or
restart the operator's daemon as a test.

Merging the verifier does not migrate a running daemon or promote a stable
release. Main qualification produces immutable dev candidates. Manual
`release.yml` with `channel=draft` qualifies first, then retains signed candidates
without TestFlight delivery or stable promotion. `release-promote.yml` promotes
qualified retained bytes through the protected stable environment. Changing
secrets does not change existing candidates; never rebuild a consumed release
identity to change its signer. A new source revision needs a new reservation.

macOS privacy grants may require Screen Recording and Accessibility authorization
again across developer teams. The permission-retention acceptance script targets
`FNGU8JFNPL` and requires two releases from that team; it does not establish grant
retention across this rotation.

The Linux daemon and gateway keep GitHub Actions OIDC/Sigstore signatures from
`dbpprt/dieter` for release checksums, OCI images and deployment manifests. Apple
credentials do not change their signer.

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

| Secret                                              | Contents                                     |
| --------------------------------------------------- | -------------------------------------------- |
| `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`             | Dedicated Application `.p12`, base64 encoded |
| `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`           | Application export password                  |
| `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`   | Dedicated Installer `.p12`, base64 encoded   |
| `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD` | Installer export password                    |
| `MACOS_NOTARY_KEY_BASE64`                           | Dedicated notarization `.p8`, base64 encoded |
| `MACOS_NOTARY_KEY_ID`                               | Notarization API Key ID                      |
| `MACOS_NOTARY_ISSUER_ID`                            | Notarization API Issuer ID                   |

Configure the full set before dispatching a release. Missing or partial
credentials fail the GitHub release signing gate; published Mac releases never
silently fall back to ad-hoc signing. Local development builds retain their
existing signing behavior. Existing Android and Homebrew credentials are
unaffected.
