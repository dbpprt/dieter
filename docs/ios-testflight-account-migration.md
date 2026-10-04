# Move internal TestFlight to Dennis Bappert's account

Prepared 4 October 2026; account setup updated 10 October 2026. This change targets a new iPhone/iPad app in Dennis
Bappert's Apple team. It does not transfer, delete, revoke, or modify Michael
Ermer's app or credentials. Current GitHub secrets have not been changed.

## Registration details

| Field                          | Prepared value                                                            |
| ------------------------------ | ------------------------------------------------------------------------- |
| Team                           | Dennis Bappert, `FNGU8JFNPL`                                              |
| App name                       | Dieter – Agents Anywhere (24 characters; created 4 October 2026)          |
| Optional future store subtitle | Run coding agents remotely                                                |
| Platform / primary language    | iOS (iPhone and iPad) / English (U.S.)                                    |
| Main App ID                    | `com.getdieter.ios` (registered)                                          |
| Share App ID                   | `com.getdieter.ios.share`                                                 |
| App Group                      | `group.com.getdieter.ios`                                                 |
| SKU                            | `dieter-ios`                                                              |
| Internal TestFlight group      | Dieter Internal                                                           |
| Initial tester                 | Account holder; select the existing account user, without inviting others |
| App Store Connect numeric ID   | `6819060438`                                                              |

The name, SKU and bundle ID are separate identifiers. The bundle ID stays fixed
after the first upload. The previous app used `com.dbpprt.dieter.ios` under Michael Ermer’s team
`DS6N5L85E7`; its secrets must not be used for this app. Apple's normal transfer process requires a
version already released on the App Store. A new bundle ID avoids depending on
that transfer. This app has separate local storage and requires sign-in again;
there is no local data or Keychain migration. Gateway OAuth callback compatibility
and isolated E2E/development identities remain unchanged.

## Account setup before cutover

1. Register the App Group and both explicit App IDs in Dennis's team. Enable
   App Groups on the app and Share extension and assign the same group to both.
2. Create the iOS record in App Store Connect with the values above. Complete
   any account agreements Apple requires. Record the resulting numeric app ID.
3. Issue a dedicated Apple Distribution certificate from the prepared CSR;
   download the certificate, verify it matches the private key and team, and
   export a macOS-compatible password-protected PKCS#12. Keep all keys,
   passwords and exports outside Git. The Mac Developer ID certificates are
   separate and cannot replace Apple Distribution.
4. Create App Store Connect distribution profiles for the app and Share App
   IDs, both using that certificate and including the shared App Group.
5. Enable App Store Connect API access if needed, then generate a dedicated
   team key named `Dieter GitHub iOS Upload`, with Developer access for upload.
   Save the one-time `.p8` download, Key ID and Issuer ID privately. This key is
   separate from Mac notarization and provides persistent team API access;
   team keys are not restricted to one app.
6. Create `Dieter Internal` as an **internal** TestFlight group and add Dennis
   from the existing eligible App Store Connect users. Do not create a public
   link, external group, or send invitations as part of setup.

The main App ID and iOS App Store Connect record were created on 4 October 2026
under Dennis's account. The record uses the name, bundle ID, primary language and
SKU above. The Share App ID, App Group and its assignments, certificate issuance,
and profiles are still pending. The dedicated Developer API key
`Dieter GitHub iOS Upload` and the internal `Dieter Internal` group were created
on 10 October 2026. API authentication verified the app record; the group has no
public link or testers yet.
The CSR/private key/export password are prepared locally outside Git; no private
paths or key material belong here. No IPA has been uploaded or submitted for review.
Open the app in [App Store Connect](https://appstoreconnect.apple.com/apps/6819060438/distribution).

## Coordinate GitHub cutover with the PR

The nine existing repository secrets are still the previous account's material.
Prepare and validate all replacements before changing any of them. Freeze new
iOS production/distribution admissions during cutover and let current owners
finish; do not cancel or rebuild a consumed release identity. Rotate the whole
set together while no signing/upload job can read a partial set.

Use the existing helper with explicit private files:

```sh
python3 -m fastlane.lib.dieter.native.apple_credentials \
  --platform ios --repo dbpprt/dieter \
  --ios-distribution-p12 /private/path/dieter-ios-distribution.p12 \
  --ios-distribution-password-file /private/path/dieter-ios-distribution.password \
  --ios-provisioning-profile /private/path/dieter-ios.mobileprovision \
  --ios-share-provisioning-profile /private/path/dieter-ios-share.mobileprovision \
  --ios-api-key /private/path/dieter-ios-upload.p8 \
  --ios-key-id KEY_ID --ios-issuer-id ISSUER_UUID \
  --ios-bundle-id com.getdieter.ios --check
```

After local validation, run the same command without `--check` during the agreed
cutover. It writes only these nine names through encrypted GitHub repository
secrets; values go through stdin rather than command arguments:

- `IOS_DISTRIBUTION_CERTIFICATE_BASE64`
- `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `IOS_SHARE_PROVISIONING_PROFILE_BASE64`
- `IOS_APP_STORE_CONNECT_KEY_BASE64`
- `IOS_APP_STORE_CONNECT_KEY_ID`
- `IOS_APP_STORE_CONNECT_ISSUER_ID`
- `IOS_TEAM_ID`
- `IOS_BUNDLE_ID`

Merge this PR only when that account setup and credential cutover are ready.
Old credentials fail the new release identity check. A signed retained release
from the old account cannot be distributed to this account by retrying upload.
Keep Mac, Android, Homebrew and gateway credentials independent. This iOS change
does not require the Mac daemon signing bridge.

## First internal TestFlight build

After cutover, qualify a fresh main revision through the canonical Fastlane
pipeline. CI calls Release only after full qualification; manual release
qualification uses the same checks. Keep one reserved SemVer and native counter
across all components. Do not rebuild or re-sign an already consumed identity.

`channel=dev` publishes a GitHub prerelease and uploads the exact retained
`Dieter-iOS.ipa` to internal TestFlight. `channel=draft` retains the candidates
without uploading to Apple; distribution requires a published candidate. Dev
never advances stable Latest, Homebrew, or production gateway activation.

If an accepted upload or processing is interrupted, reconcile that same release:

```sh
gh workflow run ios-testflight.yml --repo dbpprt/dieter --ref main -f tag=EXACT_TAG
```

Verify Apple processing is valid, the app/team/bundle ID and version/build match,
and the retained receipt confirms membership in `Dieter Internal`. Then install
through TestFlight using the account holder's Apple account. Internal testing
requires processing/export-compliance readiness but no Beta App Review. External
testing would require a separate first-build review and is outside this request.
No public App Store listing, screenshot package or App Store review submission
is required for this internal rollout.

References: [internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/),
[app records](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/),
[transfer criteria](https://developer.apple.com/help/app-store-connect/transfer-an-app/app-transfer-criteria),
[team API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).
