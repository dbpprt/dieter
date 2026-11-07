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

1. Enable **Push Notifications** for the `com.getdieter.ios` App ID in the Apple
   Developer account. Regenerate the main app's App Store profile with
   `aps-environment = production`, preserving the existing App Group. The Share
   extension does not need a push entitlement. Debug development profiles use
   `development`; TestFlight and release builds use `production`.
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

3. Release the gateway, daemons and iOS client together through the normal
   qualification/release process. No live service needs to be changed to run
   the isolated tests for this feature.
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
latest signed-in session, and sign-out unregisters it when the gateway is
reachable. Expired/revoked sessions and APNs-invalid tokens stop delivery.

The daemon uses the same attention rules as the shared core. Its authenticated
control tunnel sends coarse counts and an X25519/HKDF-SHA256/AES-GCM envelope
containing the destination card ID. Each recipient's private key stays in its
device-only Keychain, scoped to gateway and account. Neither card IDs, titles,
transcripts nor private keys are stored on the gateway. APNs gets a generic
alert and the encrypted destination. Counts from enrolled machines are summed
for the badge, and foreground reconciliation uses the current account view.

Initial snapshots establish a baseline without replaying old alerts. Live
transitions replace a card's previous local alert; viewing, archiving or resuming
the card removes stale alerts when the app reconciles. APNs owns alerts while
available, and the local planner is the fallback. Foreground APNs banners for
the card on screen are suppressed using the live core's visibility state.
Delivery follows APNs and iOS notification settings. Reconnects, gateway restarts
and OS delivery policy can delay or drop alerts; Inbox remains authoritative.

## Verification

`just pipeline core_test` covers attention rules and notification navigation
through sign-in/sync. Gateway and daemon Go tests cover account binding, token
validation, badge totals, provider JWTs and encrypted payload integrity. The
normal protobuf generation includes the internal native-session registration
RPC; no new user-facing daemon operation is introduced. Existing `card read`
and `chat read` commands acknowledge displayed replies.

`just pipeline ios build` and the existing iOS smoke flows require Xcode and an
iOS simulator runtime. The E2E fixture skips the OS permission prompt; real APNs
delivery requires the signed build, configured gateway and the manual phone
check above. Simulator/local tests never send a production push.
