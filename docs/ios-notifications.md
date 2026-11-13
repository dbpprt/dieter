# iOS attention notifications

Dieter asks for notification permission after signing in, while the app is in
the foreground. Allow alerts, sounds and badges. Lock Screen visibility is
controlled in iOS Settings → Notifications → Dieter.

The app badge counts the Inbox's **Needs you** items: unread model replies and
questions waiting for an answer. A card entering Review after a new reply
notifies you; moving an already-read card to Review alone does not. Active turns
and archived cards are excluded. Viewing the latest reply sends the existing
read receipt, so reading on another client also clears its badge contribution.

Tapping a notification opens its card in Inbox. Cold launches retain the request
through sign-in and workspace catch-up. An archived or deleted card falls back
to Inbox. Notifications from another account wait for that account to be signed
in; they cannot open a different account's conversation.

## Enable background delivery

Local alerts and badges work while the app receives workspace updates. APNs is
required for alerts while iOS suspends or terminates Dieter; the app does not
keep a background connection alive.

Background delivery is currently off: the app's entitlements
(`apps/apple/ios/App/Dieter.entitlements`) omit `aps-environment` until the
release pipeline's App Store profile includes Push Notifications. Without the
entitlement, iOS refuses the APNs registration and the app keeps its local
alerts. Restore the entitlement together with step 1 below.

A stable Dieter release or production promotion is not required. This feature
can run in a development build or a TestFlight **dev** prerelease. Apple's APNs
environment is determined by the app's signing profile:

| App installation                                    | APNs environment          |
| --------------------------------------------------- | ------------------------- |
| Xcode Debug build signed with a development profile | Sandbox (`development`)   |
| TestFlight build, including a Dieter dev prerelease | Production (`production`) |
| App Store distribution                              | Production (`production`) |

Here, **production APNs** names Apple's delivery endpoint; it does not mean a
stable Dieter release. The gateway already selects the sandbox or production
endpoint for each registered device.

1. Enable **Push Notifications** for the `com.getdieter.ios` App ID in the Apple
   Developer account. Refresh the main app's signing profile with the push
   entitlement, preserving the existing App Group. Use a development profile
   for an Xcode Debug install, or an App Store profile with
   `aps-environment = production` for TestFlight, including dev prereleases.
   The Share extension does not need a push entitlement.
2. Create an Apple Push Notification service signing key for that team. Keep its
   `.p8` private key, Key ID and Team ID in the protected gateway secret input.
   Add all three optional fields alongside the existing secrets:

   ```json
   {
     "apnsKeyBase64": "BASE64_OF_THE_COMPLETE_P8_PEM_FILE",
     "apnsKeyID": "ABCDEFGHIJ",
     "apnsTeamID": "KLMNOPQRST"
   }
   ```

   These fields augment the existing secret object; the fragment above is not
   the complete gateway configuration. The deployment renderer places them
   only in the mode-0600 private gateway environment.

3. Run gateway, daemon and iOS builds containing this change. For the shared dev
   environment, use the normal qualified dev prerelease and TestFlight process;
   stable promotion and production activation are separate and unnecessary.
   For local development, use an isolated development gateway/daemon and a
   signed Xcode Debug app. Existing binaries need an updated build containing
   the notification code; APNs configuration alone cannot add it.
4. Install the signed app, sign in and allow notifications. Run a task, leave
   its conversation, lock the phone, and let it finish. Confirm the generic
   **Task needs you** alert, badge count and notification tap. Read the reply on
   another client and verify the badge clears. Also verify a question and a
   fresh launch from a notification.

For gateways run outside the deployment renderer, set `DIETER_APNS_KEY_ID`,
`DIETER_APNS_TEAM_ID`, and exactly one of `DIETER_APNS_KEY_FILE` (a readable `.p8`
PEM path) or `DIETER_APNS_KEY_BASE64` (the complete PEM encoded as base64).
Partial configuration and invalid signing keys fail startup. Without APNs
credentials the gateway remains usable and the iOS client uses local alerts.

## Routing and privacy

Push tokens and recipient public keys are attached to expiring, revocable native
sessions. Machine credentials cannot register a phone. A token moves to its
latest signed-in session. Each push key is signed by the phone’s paired device
key and bound to the pinned roster’s account identity. The daemon verifies this
proof against its own roster before encrypting a card destination, preventing
a gateway from substituting a decryption key. Revoked devices lose delivery
and cannot register again. Sign-out unregisters the route when the gateway is
reachable. Expired/revoked sessions and APNs-invalid tokens stop delivery.

The daemon uses the same attention rules as the shared core. Its authenticated
control link sends coarse counts and an X25519/HKDF-SHA256/AES-GCM envelope
containing the destination card ID. Each recipient's private key stays in its
device-only Keychain, scoped to the pinned roster's stable account identity.
Neither card IDs, titles, transcripts nor private keys are stored on the gateway.
APNs gets a generic alert and the encrypted destination. Counts from enrolled machines are summed
for the badge, and foreground reconciliation uses the current account view.

Initial snapshots establish a baseline without replaying old alerts. Live
transitions replace a card's previous local alert; viewing, archiving or resuming
the card removes stale alerts when the app reconciles. APNs owns alerts while
available, and the local planner is the fallback. Foreground APNs banners for
the card on screen are suppressed using the live core's visibility state.
Delivery follows APNs and iOS notification settings. Reconnects, gateway restarts
and OS delivery policy can delay or drop alerts; Inbox remains authoritative.

## Verification

`just pipeline core_test e2e:true` covers attention rules and notification navigation
through sign-in/sync. Gateway and daemon Go tests cover account binding, token
validation, badge totals, provider JWTs and encrypted payload integrity. The
normal protobuf generation includes the internal native-session registration
RPC; no new user-facing daemon operation is introduced. Existing `card read`
and `chat read` commands acknowledge displayed replies.

`just ios build` and `just e2e ios` require Xcode and an
iOS simulator runtime. The E2E fixture skips the OS permission prompt; real APNs
delivery requires the signed build, configured gateway and the manual phone
check above. Simulator/local tests never send a production push.
