---
title: "Security model"
linkTitle: "Security model"
description: "Understand the trust boundary before connecting your machines."
group: "Reference"
weight: 41
slug: "security"
---

Dieter runs agents with the permissions of the user running the daemon. There is
no Dieter sandbox. Treat a trusted device as an operator of those machines.

## Account access

The gateway authorizes immutable numeric GitHub IDs from
`DIETER_GITHUB_ALLOWED_USER_IDS`. Each allowed account is isolated from other
accounts. A client session has full access within its account or no access;
there are no granular read-only scopes. A session alone reaches no machine: the
device must also be one of the account's [trusted devices](#trusted-devices).

Machine enrollment requires GitHub sign-in and a separate browser approval of
the machine name and enrollment code. The page also shows the public-key
fingerprint. Merely opening the verification link does not enroll a machine.

App sign-in also ends on a gateway confirmation page that names the GitHub
account and the app callback. GitHub can skip its own consent for an app you
authorized before, so this page is what stops another app on the same device
from silently starting a sign-in and receiving your session. Only continue if
you just started signing in from a Dieter app. The gateway accepts only its
configured app callbacks, never loopback addresses.

## Trusted devices

Every machine and app has its own key. The account's **device roster** lists
these keys. It is an append-only list in which every change is signed by a
device that is already trusted; the first machine starts it. Every machine and
app checks the list itself. The gateway stores it but cannot sign a change, so
it can neither add a device nor remove one.

- Machines use their enrollment key (Ed25519).
- Apps create an ECDSA P-256 key on first start: in the Secure Enclave on Mac,
  iPhone and iPad, and in the Android Keystore (StrongBox when available). The
  key cannot be exported. A Mac without a Secure Enclave and the iOS simulator
  use a software key. The Mac app keeps its key in a user-only file, never in
  the Keychain, so it never prompts.

**Pairing.** A new device shows a one-time code of 16 characters, such as
`ABCD-EFGH-JKMN-PQRS`. Type that code on a device you already trust: in an app
under **Devices → Add a device**, or on a machine with
`dieter device approve CODE`. The code proves which key the new device posted,
and the new device checks that the approval came from a device that knew its
code. A gateway can therefore neither swap the key nor pair the device into a
list of its own. Nobody compares codes on two screens, and waiting devices are
listed by name only. [Machines & routes](/docs/machines/#trusted-devices)
describes the steps.

{{< callout type="warn" title="Only type a code you see on your own new device" >}}
A device whose code you type on a trusted device becomes a trusted device with
full access to your machines. Never type a code that someone sends you, reads
out to you, or shows on a device you do not own.
{{< /callout >}}

Every change appears on the apps' **Devices** screen, for example "Pixel 9 was
added by Studio". `dieter device roster` lists the signed history.

**Recovery key.** When the first machine starts the roster, `dieter device init`
prints a recovery key (`DRK1-…`) once. Store it offline. If no trusted device
is left, it adds a machine again with `dieter device recover --recovery-key -`.
It works only for the roster it was made for, but anyone who holds it can add a
machine to your account.

**Conflicts.** Apps compare their lists with every machine they connect to, and
machines with each other, so a change the gateway withholds from one device
still reaches it. If a device
sees a different history from the one it trusts, it reports a conflict and
stops connecting. Unless you started a new roster yourself
(`dieter device init --replace`), treat a conflict as a sign that your gateway
may be compromised; see
[troubleshooting](/docs/troubleshooting/#a-device-is-not-trusted).

## Machine identity and transport

Every remote call runs TLS 1.3 end to end between your device and the daemon,
whatever the route: verified direct TLS, a WebRTC data channel (directly or
through TURN), or a gateway relay tunnel. Both sides authenticate with their
keys from the device roster: the app or CLI accepts only the target machine's
key, and the daemon accepts only a trusted device. Each call also carries a
short-lived gateway token bound to the calling device, so the gateway can still
end a signed-out session. The relay is an opaque tunnel: the gateway forwards
encrypted bytes that it can neither read nor change. An enrolled daemon proves
possession of its Ed25519 key on each connection to the gateway.

The raw daemon API stays on loopback (`127.0.0.1:4242`). Never publish that port.
Loopback alone admits every user and process on the host, so each raw request
must also carry a random local API token. The daemon rotates it on every start
and writes it to `DIETER_HOME/runtime/local-api-token`, readable only by the
daemon user. The CLI reads it automatically; other local users, containers
sharing the host network, and request-forgery bugs in other local services
cannot.
Enrolled daemons advertise a separate authenticated loopback TLS route; an
additional LAN or tailnet TLS route is optional. Public gateway origins require
HTTPS. Literal loopback HTTP is reserved for isolated local setups.

External TLS uses TLS 1.3. If a reverse proxy terminates TLS, configure that
policy at the proxy too; the proxy sees only the encrypted tunnels inside.
Relay tunnels, queues and messages are bounded. Transport cancellation never
implicitly stops an agent.

The gateway stores no state for a sign-in until GitHub returns; the attempt is
sealed in a browser cookie. Unauthenticated work is limited per client network
(per IPv4 address or IPv6 /64): concurrent machine handshakes, public
enrollment and compatibility calls, and pending enrollments. One source cannot
fill a pool that every machine and client shares.

## Storage and what the gateway sees

| Location      | Stored data                                                                                                                                                                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Daemon        | Checkouts and local execution state; transcripts, files, schedules; shared metadata replicas; the trusted device list; encrypted vault replica and this machine's vault member key; local harness credentials in their normal configuration locations |
| Gateway       | Account sessions, daemon identities, presence, routes, revocation metadata, the signed device roster, pairing requests for up to 15 minutes, and normalized credential-free provider quota snapshots                                                  |
| Native client | Session credential, device key, the trusted device list, caches, drafts, and pending commands appropriate to that platform                                                                                                                            |

The gateway **does not store** repositories, transcripts, project files, schedules,
provider credentials, or raw provider responses. It relays your calls only
inside end-to-end encrypted connections, so it can neither read nor change
them: chats, prompts, terminals, files, executions, Git, vault content, shared
project records, screen signaling and screens.

It still sees metadata:

- your account, and the names, kinds and public keys of your devices;
- pairing requests while they wait (never their codes);
- machine names, presence and direct route addresses;
- whether a machine can share its screen;
- when relay tunnels open and close, and how many bytes they carry;
- client IP addresses and TURN allocations;
- provider quota snapshots.

A gateway can refuse service, and it can withhold changes to the device list
from some devices until they talk to each other. None of this protects a
machine whose own user account is compromised, for example by a prompt-injected
agent.

Quota snapshots may include a bounded account display email when returned by the
provider's structured account API. Opaque account keys are account-scoped HMACs,
not raw provider account IDs.

Agent model requests follow your provider's configuration. Cloud model providers
may receive prompts, code, and tool output. Dieter does not make that inference
local or replace the provider's data policy.

## Vault

[Vault](/docs/vault/) items replicate as AES-256-GCM ciphertext. Vault keys are
sealed to each member machine's hybrid ML-KEM-768/X25519 key. A new machine
joins by matching a code on two machines or by using the offline recovery key.
That way, a relay or replica that can write peer records still can't substitute
keys. Every remote route, the relay included, is end-to-end encrypted, so
decrypted vault content never reaches the gateway. Agent turns use the vault
only when their conversation was created with vault access. Agents run
unsandboxed as your user, so treat that rule as protection against mistakes
plus an audit trail, not as isolation.

## Mail

[Mail](/docs/mail/) stays on the machine that received it and is not
replicated; the apps read it over the end-to-end encrypted routes, so the
gateway never sees it. Agents may send mail only from conversations created
with mail access, and can't read the mailbox. The apps never load images or
other remote content from a message, and render no HTML.

## Revocation

Remove a lost or retired device on any trusted device: **Devices → Remove** in
an app, or `dieter device revoke DEVICE_ID`. Machines refuse it from its next
call once they see the signed removal, also on connections that are already
open. A removed device must reset and pair again with a new key. The last
device that can connect cannot be removed.

Revoking a daemon at the gateway (`dieter machine revoke`) closes its relay
immediately; direct access ends as its five-minute tokens expire. Signing out
or expiring a gateway session closes its gateway streams, relay tunnels
included, within approximately five seconds; direct streams expire with their
token, with ten seconds of clock tolerance.

`dieter daemon unenroll` removes the machine from the trusted devices, signs
its revocation request, deletes its key and gateway credential, and leaves
projects and conversations intact. Clients stop recovery on revocation.
Read-subscription retries do not restart agents or processes.

## Native sessions and device keys

- **macOS:** user-only session and device key files under
  `~/Library/Application Support/com.getdieter.mac`, with `0700` directory and
  `0600` file permissions. The session file is not encrypted by the app. The
  device key file holds a Secure Enclave key that only this Mac can use, or a
  software key on a Mac without one. Neither uses the Keychain.
- **Android:** session encryption uses a device-bound Android Keystore key. The
  device key is a non-exportable Keystore key, in StrongBox when available.
- **iOS:** device-only Keychain items are separated by gateway origin. The
  device key is a Secure Enclave key (a software key on simulators), kept as a
  device-only Keychain item.

Clients retain Dieter sessions, not GitHub access tokens or provider credentials.
A session without the device key reaches no machine. Signing out keeps the
device key and the trusted device list, so signing in again to the same account
needs no new pairing; **Reset this device** on the Devices screen deletes both.
Protect the operating-system account and device that hold them.

## Screens and clipboard

Screen signaling runs inside the encrypted connection to the machine. Clients
verify the machine's signed screen binding with its key from the device roster
before accepting video or input.
Up to four viewers can connect, with one revocable input controller. Held keys
and buttons are released on focus loss or disconnect. Host capture requires the
relevant OS permissions; there is no separate enable switch.

Clipboard sharing is opt-in and available only to the focused controlling viewer.
Its contents do not enter transcript history or logs. Reconnection never replays
an uncertain paste. See [Screens](/docs/screens/) for platform limits.

## Verifying releases

Every release publishes `SHA256SUMS` signed with Sigstore cosign keyless
signing. The only valid signer is the release workflow on `main`:

```sh
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
```

The Linux installer and the managed Linux updater check exactly this identity
before installing anything. macOS binaries are additionally Developer ID signed
and notarized, and the Android updater checks the APK digest published with the
release.

## Threat model

The contributor [threat model](https://github.com/dbpprt/dieter/blob/main/docs/threat-model.md)
goes further: what a compromised gateway, a malicious machine in your account, a
stolen device or a prompt-injected agent can do, and which mitigations exist.
In short: the gateway is trusted to keep the service available, but not with
your data or with deciding which devices are yours; every trusted device in an
account can operate every machine; and agents can do anything your user can.

## Reporting a vulnerability

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/dbpprt/dieter/security/advisories/new).
Do not put credentials or an unpatched exploit into a public issue. The
repository's [security policy](https://github.com/dbpprt/dieter/blob/main/SECURITY.md)
describes what to include and what is in scope.
