# App Store and TestFlight preparation

Draft prepared on 13 September 2026 from the iOS implementation, repository
documentation, and completed Apple setup. The app record and dedicated release
credentials are configured. The TestFlight beta description and marketing URL
are saved, and the internal tester group exists. The App Store version `0.1.0`
listing is saved as a draft. Fields marked **Pending** need the release owner's
input or verification in the selected Apple account. Keep reviewer credentials
out of this file and out of the repository.

## App record

| Field | Value | Basis / remaining check |
| --- | --- | --- |
| Name | Dieter AI | User-approved name saved in App Store Connect. |
| Platform | iOS | One app supports iPhone and iPad, iOS 18 or later. |
| Bundle ID | `com.dbpprt.dieter.ios` | Registered App ID and App Store Connect app; matches the current build default. |
| Share extension bundle ID | `com.dbpprt.dieter.ios.share` | Registered explicit App ID with the shared App Group enabled. |
| App Group | `group.com.dbpprt.dieter.ios` | Registered and assigned to both the app and Share extension App IDs. |
| Apple team | `DS6N5L85E7` | Team used for registration and the dedicated iOS distribution credentials. |
| App Store Connect ID | `6811592270` | Registered [app record](https://appstoreconnect.apple.com/apps/6811592270). |
| SKU | `dieter-ios` | Registered internal identifier. |
| Primary language | English (U.S.) | Configured in App Store Connect; the app development language is English. |
| Version | `0.1.0` | Saved App Store version draft; also the current release workflow default. |
| Build | Workflow run number and attempt | Generated as `run_number.run_attempt`; do not reuse a previously uploaded build. |
| Primary category | Developer Tools | Configured in App Store Connect. |
| Secondary category | Productivity | Optional recommendation for its task and board workflows. |
| Subtitle | Remote AI agent workspace | Configured in App Store Connect. |

Apple requires an app record before a build upload. Account agreements and
account access must also be in place. See [creating an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).
The category recommendation follows Apple's [category descriptions](https://developer.apple.com/app-store/categories/).

## Completed release setup

Dedicated iOS distribution credentials were created for Apple team
`DS6N5L85E7` on 13 September 2026. The identifiers below are registration metadata;
certificate private keys, passwords, API key material, and private file paths
are intentionally excluded.

| Resource | Registered metadata |
| --- | --- |
| Apple Distribution certificate | Portal ID `4TWJG5NTJ3`; expires 13 September 2027. |
| App Store provisioning profile | `Dieter iOS App Store 2026`; portal ID `7QUZQSNAZZ`; UUID `755E18D2-B358-43CF-A339-A64EC8098AE9`; expires 13 September 2027. |
| Share App Store provisioning profile | `Dieter iOS Share App Store 2026`; portal ID `G6KRHY774A`; UUID `924983F8-C764-468C-87B2-6B16F8DBFC38`; expires 13 September 2027. |
| App Store Connect API key | `Dieter GitHub iOS Upload`; Developer role; key ID `9LAL22MXP5`; issuer ID `69a6de74-a6e2-47e3-e053-5b8c7c11a4d1`. |

The signing setup now provides nine iOS GitHub Actions
secrets: `IOS_DISTRIBUTION_CERTIFICATE_BASE64`,
`IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`,
`IOS_SHARE_PROVISIONING_PROFILE_BASE64`,
`IOS_APP_STORE_CONNECT_KEY_BASE64`, `IOS_APP_STORE_CONNECT_KEY_ID`,
`IOS_APP_STORE_CONNECT_ISSUER_ID`, `IOS_TEAM_ID`, and `IOS_BUNDLE_ID`.

**Screenshot sharing signing:** completed on 19 September 2026. The App Group is
enabled for both explicit App IDs, both App Store profiles contain the App Group,
and their profile secrets are configured for explicit manual profile selection.
The distribution certificate and upload API key remain unchanged.

The existing 1Password item **Dieter — Apple release signing credentials** was
updated and saved with the iOS certificate, profile, and API key identifiers,
protected local file references, the original GitHub secret mappings, and recovery
and revocation links. Existing macOS notes, fields, and attachments were preserved.
The iOS credential files were referenced, not added as new 1Password attachments.

## App Store description (saved draft)

The full description below is saved under **iOS-App Version 0.1.0** in App Store
Connect. Promotional text, keywords, support URL, and marketing URL are also
saved. **Manual public release** is selected. This does not submit the version
for review or make it available to users.

**Promotional text:** Continue coding-agent work from iPhone and iPad. Start
tasks, follow conversations, and edit files on your enrolled Dieter machines.

**Keywords:** `coding,agents,developer,remote,workspace,projects,tasks,files,automation`

### Description

Dieter AI brings your coding agents to iPhone and iPad. Connect to your Dieter
gateway, choose one of your enrolled machines, and continue work in the projects
you already use.

- Browse projects, boards, tasks, and conversations across your machines.
- Save a task as a draft or start it immediately with your preferred available
  provider, model, and reasoning setting.
- Follow live progress, read earlier messages, send follow-ups, and stop an
  active agent turn.
- Browse remote files, view images, and edit text files with checks that protect
  against saving over a newer revision.
- Use focused navigation on iPhone and a sidebar, task list, and conversation
  layout on iPad.
- Return to a conversation after switching apps while your agent continues
  working on its host machine.

Dieter is a remote client. Before connecting, you need a configured HTTPS Dieter
gateway, an enrolled machine with the Dieter daemon, a registered project, and
an available coding-agent harness on that machine. Sign in with the GitHub
account permitted by your gateway or use a gateway-issued session token.
Agent execution and durable conversations remain on your enrolled machine;
the selected agent provider's service and data terms still apply.

## TestFlight copy

The **Dieter Internal** group is created and verified, with manual distribution
selected. It currently has **0 testers and 0 builds**; no testers have been
invited. The beta app description and marketing URL were saved successfully.
Feedback email and review details remain pending.

### Beta app description

Test Dieter's native iPhone and iPad client for coding agents running on your
own machines. Connect to a Dieter gateway, browse projects and tasks, start work,
continue conversations, and edit remote text files. On iPad, use the project
sidebar and task list alongside the conversation. This beta requires an existing
HTTPS gateway and an enrolled, configured Dieter machine; it does not run agents
on the phone or tablet.

### What to test

1. Sign in to your configured HTTPS gateway and select the correct enrolled
   machine, project, and board.
2. Create a draft with Add task, then start it. Create another task with Run task
   and confirm it starts immediately with your selected provider and model.
3. Follow live progress, load older messages, send a follow-up in the same
   conversation, and stop a running turn.
4. Open a remote text file, make a small edit, save, and reopen it. Confirm that
   conflicting edits produce a useful message instead of overwriting changes.
5. Switch apps or temporarily disconnect, then return. Confirm the conversation
   remains readable and reconnects without starting duplicate work.
6. On iPad, check portrait and landscape navigation, the three-column layout,
   keyboard use, and file browsing. On iPhone, check back navigation and forms
   with the keyboard visible.

Include device model, OS version, app build, and reproduction steps with
feedback. Remove session tokens, private repository content, and other sensitive
information from screenshots or logs before sharing them.

### Beta review notes template

Dieter is a native remote client for a separately hosted coding-agent service.
The app requires an HTTPS gateway and an enrolled host; it cannot create a host
on the iOS device. An isolated review environment will be supplied privately.

1. Open the app and enter the supplied gateway URL.
2. Use the supplied sign-in method and review credentials.
3. Select the supplied review node, project, and board.
4. Use Run task with the suggested sample prompt to view agent progress and send
   a follow-up. Open Browse files to read or edit the supplied sample text file.

**Pending:** provision and verify the review environment, fill in its exact
navigation names and sample prompt, and place working access details in App
Store Connect's private review fields. Keep this environment available throughout
review. Do not use a production gateway or repository as the review fixture.

**Pending:** TestFlight feedback email, review contact name/email/phone, and the
tester invite list. The internal group exists; any external testing audience and
group still need to be chosen. External testing
requires additional [TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/).

## URLs and owner decisions

| Field | Repository evidence / action needed |
| --- | --- |
| Marketing URL | `https://dbpprt.github.io/dieter/` is saved in both the App Store version draft and TestFlight, and linked by the root README as the current website. Verify its live content covers the iOS client before App Store submission. |
| Support URL | `https://github.com/dbpprt/dieter/issues` is saved in the App Store version draft and is the documented support and bug-report channel. |
| Privacy policy URL | **Pending.** No published privacy policy URL was found in the repository. Supply a public policy covering the actual deployment and data practices. |
| Feedback and review contact | **Pending.** No appropriate feedback email or review contact phone was found in the repository. |
| Seller and copyright | **Pending.** The repository's MIT license says “Copyright (c) 2026 Dieter contributors”; this does not establish the Apple account's legal seller or the copyright field to submit. |
| Pricing and availability | Manual public release is selected. **Pending:** confirm price, countries/regions, and release timing. |
| Age rating and content rights | **Pending.** Complete the current questionnaires using the actual app and connected services. Do not infer answers from the Developer Tools category. |
| Encryption/export compliance | **Pending.** The app uses HTTPS and authenticated TLS. Confirm the applicable declaration; the app currently has no `ITSAppUsesNonExemptEncryption` declaration. |

`getdieter.com` appears in website configuration, but the website README describes
it as a future domain. Do not substitute it for a verified public URL.

## Privacy inventory for the declaration

These implementation facts help the owner complete the privacy answers; they
are not a completed privacy label or a claim that no data is collected:

- Gateway sessions are kept in device-only Keychain items, separated by gateway
  origin. The iOS app also stores interface/connection preferences locally.
- GitHub sign-in is handled by the configured gateway. Gateway session records
  include GitHub identity and session timing. The gateway stores account sessions,
  node identities, presence, and route metadata.
- Tasks, transcripts, and files are persisted by the enrolled daemon. They are
  transmitted to the iOS client through an authenticated direct route or gateway
  relay. Lack of gateway persistence does not mean lack of transmission.
- Agent credentials and execution reside on the daemon host. The chosen harness
  may send prompts, files, or other task context to the selected provider.
- No analytics or advertising SDK was identified in the inspected iOS source.
  A release dependency and deployment review is still needed before declaring
  the developer's or third parties' data collection practices.

**Pending:** identify who operates the gateway and any review/beta service, their
retention and deletion practices, and whether developer-operated services collect
account information, user content, diagnostics, or other data. Publish a matching
policy and complete the App Store privacy answers. Apple requires a privacy
policy URL for iOS apps and accurate declarations covering applicable third-party
practices: [manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/).

## Release evidence and remaining distribution work

The app contains opaque iPhone/iPad icon assets derived from the existing Dieter
brand. Native simulator journeys and an unsigned device archive have passed;
see [validation](VALIDATION.md) for evidence and limits. The existing iPhone
walkthrough is a PR demo. Capture suitable store screenshots separately; the
recorded iPad XCTest images have an orientation/rendering issue and must not be
used as store artwork.

The dedicated signing credentials are configured. Follow the
[iOS release setup](README.md#signing-and-testflight) to archive/export the app
once the manual workflow is available. After a build upload, verify
Apple processing and export-compliance status, then assign the build to the
intended TestFlight group and complete external review if needed. Public App
Store submission remains separate from beta distribution. Neither this metadata
draft nor a simulator test establishes Apple acceptance or tester availability.
