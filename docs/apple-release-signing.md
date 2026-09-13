# Apple release signing

Dieter's GitHub release workflow signs the Mac app, its embedded WebRTC framework,
the daemon, and its native capture helper with Developer ID Application. The
daemon installer uses Developer ID Installer. Both deliverables are submitted to
Apple's notary service; a submission must report `Accepted` before release work
continues. The app and installer carry stapled notarization tickets.

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

## Configure the repository

The authenticated GitHub CLI account needs permission to manage Actions secrets
in `dbpprt/dieter`. Supply the dedicated files explicitly:

```sh
just release configure-apple-signing \
  --repo dbpprt/dieter \
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

It uploads only these seven repository secrets:

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

## Release and verify

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
