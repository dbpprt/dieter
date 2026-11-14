# Mobile attention notifications

Android and iOS use one shared notification system. The Kotlin core selects the
Inbox's **Needs you** items: unread model replies and questions waiting for an
answer. Active turns and archived cards are excluded; moving an already-read
card to Review does not notify. Reading the latest reply on any client clears
its contribution. Initial snapshots never announce a backlog.

The core also owns foreground visibility suppression, duplicate push handling,
account binding and pending encrypted taps. Native adapters supply OS permission,
notification presentation, token registration and platform cryptography. Taps
open the task in Inbox after sign-in and workspace catch-up; unavailable tasks
fall back to Inbox. A different account cannot decrypt the destination.

## Background delivery

Local notifications work while the app receives workspace updates. Background
or closed-app delivery uses **APNs on iOS** and **Firebase Cloud Messaging (FCM)
on Android**. Neither app keeps a background daemon connection alive.

A new release supplies the code, but **does not create provider credentials,
change Apple's signing profile, configure Firebase or grant phone permission**.
Configure the providers below, install matching gateway/daemon/app builds, and
perform the physical-phone checks. Stable promotion is unnecessary: signed dev
builds and TestFlight prereleases can receive push too.

### iOS / APNs

The main app requests `aps-environment` through `DIETER_APNS_ENVIRONMENT`: development
builds use sandbox APNs and Release builds use production APNs. Local alerts
remain available when remote registration fails. A cached token is not reused
until APNs confirms registration for the running build.

The release lane validates both provisioning profiles before compiling the
framework. The main profile must allow production push, match the app identity
and App Group, and be an unexpired App Store profile. It also verifies the
exported IPA signature, release identity and production push entitlement before
the IPA can be published. An outdated profile fails with setup instructions;
removing the push entitlement is not a release workaround.

1. Enable **Push Notifications** on the `com.getdieter.ios` Apple App ID. Refresh
   the main app's signing profile, preserving its App Group. The Share extension
   needs no push entitlement. Replace `IOS_PROVISIONING_PROFILE_BASE64` in the
   protected `apple-signing` GitHub environment with the refreshed profile.
   The app entitlement and `DieterAPNSEnvironment` are already wired to the same
   Xcode setting; no source toggle is needed.
2. Create an APNs signing key. Add these optional fields together to the existing
   protected gateway secret input (this is a fragment, not the full object):

   ```json
   {
     "apnsKeyBase64": "BASE64_OF_THE_COMPLETE_P8_PEM",
     "apnsKeyID": "ABCDEFGHIJ",
     "apnsTeamID": "KLMNOPQRST"
   }
   ```

3. Install the signed app, sign in and allow alerts, sounds and badges in
   **Settings → Notifications → Dieter**. Lock Screen visibility is controlled
   by those settings.

Xcode development profiles use sandbox APNs (`development`). TestFlight,
including Dieter dev prereleases, and App Store profiles use production APNs
(`production`). This Apple endpoint choice does not require a stable Dieter
release. The gateway selects the endpoint per registered phone.

Without the deployment renderer, configure `DIETER_APNS_KEY_ID`,
`DIETER_APNS_TEAM_ID` and exactly one of `DIETER_APNS_KEY_FILE` or
`DIETER_APNS_KEY_BASE64`. Invalid or partial credentials fail gateway startup.

### Android / FCM

1. Register the distribution's Android application ID (`com.getdieter.android`)
   in a Firebase project with Cloud Messaging HTTP v1 enabled. The device needs
   Google Play services. Register forks under their own application ID.
2. Supply the public Firebase app configuration when building Android:

   | Build environment variable  | Firebase Android app configuration field |
   | --------------------------- | ---------------------------------------- |
   | `DIETER_FCM_APPLICATION_ID` | `mobilesdk_app_id`                       |
   | `DIETER_FCM_API_KEY`        | `current_key` from `api_key`             |
   | `DIETER_FCM_PROJECT_ID`     | `project_id`                             |
   | `DIETER_FCM_SENDER_ID`      | `project_number`                         |

   These values are public app configuration, not server credentials. Set all
   four or none; partial configuration fails the build. The release job reads
   `FCM_APPLICATION_ID`, `FCM_API_KEY`, `FCM_PROJECT_ID` and `FCM_SENDER_ID` from
   the `android-signing` GitHub environment's variables. With no configuration,
   local notifications still work. The separate `.e2e` app never initializes FCM.

3. Give a dedicated service account permission to send FCM messages for that
   project (the Firebase Cloud Messaging API Admin role). Put its complete JSON
   key, base64 encoded, in the protected gateway secret input:

   ```json
   {
     "fcmServiceAccountBase64": "BASE64_OF_THE_COMPLETE_SERVICE_ACCOUNT_JSON"
   }
   ```

   The renderer writes this only into the mode-0600 private gateway environment.
   Never put the service-account key in the Android app, build configuration or
   public deployment bundle. Without the renderer, use exactly one of
   `DIETER_FCM_SERVICE_ACCOUNT_FILE` or `DIETER_FCM_SERVICE_ACCOUNT_BASE64`.

4. Install the app and allow notifications when asked after sign-in. On Android
   13+, this requires the runtime Notifications permission. Check the **Tasks
   needing you** channel in **Settings → Apps → Dieter → Notifications** too.

FCM sends a generic notification plus the encrypted task link. Google Play
services displays it while Android has stopped the app process; the foreground
callback uses the shared presentation policy. Launcher badges depend on the
launcher and Android notification policy; Android does not offer iOS's exact,
independent numeric app badge. Badge-only updates are best effort. Opening or
resynchronizing Dieter reconciles stale alerts with the authoritative Inbox.
Android force-stop disables FCM delivery until the user launches the app again.
Devices without Google Play services retain local notifications.

## Routing and privacy

Both providers use the same native-session registration and daemon encryption
path. Push provider, token, public key and signed device binding belong to an
expiring, revocable session. Availability is reported per provider, so a gateway
with only APNs does not disable Android's local fallback. FCM tokens remain
case-sensitive; token replacement is scoped to its provider.

Each recipient key is signed by the phone's paired device key and bound to the
pinned roster's stable account identity. The daemon verifies that proof against
its own roster before encrypting a task link. A gateway cannot substitute its
own decryption key. Revocation, session expiry and explicit provider token
invalidation stop delivery; sign-out unregisters when reachable.

The daemon sends coarse counts and X25519/HKDF-SHA256/AES-GCM encrypted card
IDs. Per-account private keys stay in device-only Keychain on iOS and
Keystore-encrypted storage on Android. Neither task IDs, titles, transcripts nor
private keys are stored on the gateway. APNs/FCM receive generic alert text,
counts and encrypted links. Provider HTTP requests are bounded, use fixed
endpoints, reject redirects and do not log tokens or response bodies.

## Verification

Release-gate tests reject missing/sandbox push entitlements, wrong app identities,
lost App Groups, expired/development/ad-hoc profiles and exported apps with an
incorrect push environment or release identity. These checks use synthetic
profiles and send no push or Apple Developer mutation.

Unit tests cover shared attention and presentation rules, pending taps, account
isolation, provider routing, token case, provider JWTs, encrypted payload
integrity and private deployment rendering. Protobuf generation includes the
internal native-session registration RPC; no new daemon operation is added.
Existing `card read` and `chat read` acknowledge displayed replies.

`just ios build` and `just e2e ios` require Xcode and a simulator runtime.
`just e2e android profile:android-emulator` uses the isolated E2E app. Fixture
runs skip permission prompts and external push providers, so they cannot prove
live delivery.

With each provider configured, verify on a physical phone:

1. Run a task, leave its conversation, background Dieter and lock the phone.
   Let the task finish; confirm the generic **Task needs you** alert and tap it
   to open the correct task. Repeat with a question waiting for an answer.
2. Repeat after the OS has terminated the app process. Verify the tap survives
   a cold launch, sign-in and synchronization. On Android, do not use force-stop
   as a substitute for process termination.
3. Read the reply on another client; confirm iOS's badge clears and both apps
   remove stale alerts after reconciliation. Check that viewing a conversation
   suppresses its foreground banner and repeated delivery does not alert again.
4. Deny/re-enable permission, rotate the OS token, switch accounts and sign out.
   Verify local fallback when that provider is unconfigured, and ensure an old
   account's encrypted link never opens a different account's task.

OS settings, network availability and provider delivery policies can delay or
drop alerts. The Inbox remains authoritative. No production push is sent by
the automated tests.
