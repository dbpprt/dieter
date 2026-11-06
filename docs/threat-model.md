# Threat model

Dieter lets authenticated clients drive coding agents that run, unsandboxed, on
your own machines. This document states what Dieter protects, which parties it
trusts, what an attacker in each position can do, and which mitigations exist
today, with pointers into the code. It complements the user-facing
[security model](../site/content/docs/security.md) and the binding
[invariants](invariants.md). Report vulnerabilities as described in
[SECURITY.md](../SECURITY.md).

## Assets

| Asset                                                                     | Where it lives                                                                       |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Source code, working trees and build outputs                              | Daemon hosts (Git checkouts)                                                         |
| Transcripts, prompts, attachments, queues, schedules                      | Daemon `DIETER_HOME` (central store)                                                 |
| Harness and provider credentials (Codex, Claude, Pi, OMP, DSH profiles)   | Daemon hosts, in each tool's normal configuration                                    |
| Daemon identity key (`identity-key.pem`): enrollment and roster key       | Daemon `DIETER_HOME`                                                                 |
| App device keys                                                           | Secure Enclave (macOS, iOS) or Android Keystore; a software key where neither exists |
| Pinned device roster                                                      | Daemon `DIETER_HOME/daemon/roster.pb`; each app's core state                         |
| Roster recovery key                                                       | Printed once by `dieter device init`; kept offline by the operator                   |
| Local API token                                                           | `DIETER_HOME/runtime/local-api-token`, user-only                                     |
| Vault items and member key                                                | Ciphertext replicated to every daemon; member key in `DIETER_HOME/vault/member.json` |
| Client sessions                                                           | macOS user-only file, Android Keystore-encrypted store, iOS device-only Keychain     |
| Gateway signing key, internal daemon CA, OAuth app secret, session secret | Gateway state directory and environment                                              |
| Ability to execute code on a daemon host                                  | Any authenticated operator path (API, CLI, agent turn)                               |
| Release artifacts and their signatures                                    | GitHub releases, GHCR, Homebrew tap, TestFlight                                      |

The most valuable asset is the last-but-one: **anything that can call a daemon's
API as an operator can run arbitrary commands as the daemon user**, through an
agent turn, a terminal or remote execution. Most of this model is about who can
reach that capability. Remotely, that takes the key of a device in the
account's device roster together with a current gateway session.

## Trust boundaries

```text
 [native client] ══(mutual TLS: direct | WebRTC | relay tunnel)══▶ [daemon] ──▶ [harness worker] ──▶ [model provider]
        │                                                          ▲   │            (unsandboxed, daemon user)
        └─── OAuth + session ──▶ [gateway] ── opaque tunnel ───────┘   └══▶ peers of the same account (mutual TLS)
                                    ▲    (stores the signed device roster)
                                [GitHub OAuth]
```

1. **Account boundary.** The gateway isolates allowlisted accounts from each
   other. Inside one account every device in the account's device roster is one
   trust domain: a trusted device with a current gateway session has full
   operator access to all of the account's machines, and there are no read-only
   scopes (by design; see [invariants](invariants.md#network-and-identity)).
2. **Device roster.** The roster decides which machines and apps may connect.
   It is an append-only, hash-chained list of device keys; every entry after
   the first daemon's genesis is signed by an active member
   (`internal/security/roster`). A person adds a device by typing the one-time
   code the new device shows on a device that is already trusted.
3. **Gateway.** The gateway authenticates people (GitHub OAuth, allowlisted by
   immutable numeric user ID) and daemons (enrollment, then key-possession
   proofs) for its own service. It issues daemon tokens bound to a roster
   device, stores and distributes the roster and pairing requests, and relays
   opaque tunnels. It is trusted for availability and for keeping accounts
   apart. It is not trusted with Dieter data, and it does not decide which
   devices belong to an account.
4. **Daemon host and user.** The daemon, its harness workers, terminals and
   remote executions all run as one OS user, without a sandbox. Anything that
   runs as that user is inside the boundary.
5. **Loopback.** The raw daemon API listens on loopback and is guarded by a
   per-start random token readable only by the daemon user.
6. **Model providers.** Prompts, code and tool output go to whatever provider
   the harness is configured for. Dieter does not mediate that data flow.
7. **Release pipeline.** Users trust signed releases from this repository's
   `release.yml` workflow on `main`.

## Threats and mitigations

### Compromised or malicious gateway

Since 0.6 the gateway relays ciphertext and is not a root of trust
([ADR 0002](adr/0002-end-to-end-encryption.md)).

**Can:**

- Deny or delay service: refuse sign-in, tokens, tunnels, roster appends or
  pairing requests, withhold presence and routes, or cut off sessions.
- Withhold roster entries, such as a revocation, from some devices. Apps
  compare roster heads with every machine they connect to, and machines with
  each other in every peer-sync round, so the entry still propagates and the
  gap is visible.
- Present a different roster (a fork or a new genesis). Devices that pinned the
  account's roster report a conflict and refuse remote calls until a person
  resets them.
- See metadata: accounts, device IDs, names, kinds and public keys, pairing
  requests (descriptors and MACs), daemon names and presence, direct candidates
  (IP addresses), remote-desktop readiness, tunnel open and close times and
  byte counts, client IP addresses, TURN allocations and provider quota
  snapshots.
- Serve a malicious sign-in page. A session alone reaches no machine without a
  paired device key.
- Try social engineering: ask a person to type a code that the gateway's own
  device shows.

**Cannot:**

- Read or change anything inside a tunnel or WebRTC channel: calls,
  transcripts, terminals, files, executions, Git, vault content, peer records,
  WebRTC signaling and screens.
- Impersonate a daemon to a device, or a device to a daemon. Both sides of
  every TLS connection are pinned to roster keys, and a daemon token is bound to
  the device key that must present it.
- Add a device or forge a revocation. Every roster entry is signed by a member,
  and pairing needs the code that only the new device's own screen shows.
- Roll back or rewrite roster history that a device has pinned.
- Read repositories, transcripts or provider credentials at rest, or decrypt
  vault items.

**Mitigations:**

- The roster binds each entry to the account (`<issuer>|github:<id>`), the
  previous entry's hash and a member's signature, with hard limits (4096
  entries, 64 active devices, 1 KiB per entry). Devices pin the root and adopt
  only extensions (`internal/security/roster`, `internal/link/trust.go`, the
  Kotlin core's `trust` package). Go and Kotlin share golden vectors
  (`tests/fixtures/roster`).
- Pairing (`internal/security/roster/pairing.go`): the request's proof and the
  approver's confirmation are HMAC-SHA256 keyed by the 80-bit code. The approver
  signs exactly the key the code proves; the new device pins a roster only when
  the confirmation verifies for its root and the entry that added the device. A
  roster that merely lists the device is never enough.
- Mutual TLS 1.3 on every carrier (`internal/link/tls.go`,
  `internal/link/direct.go`): the client accepts only the target daemon's
  roster key; the daemon accepts only a client key of an active member, checks
  membership again on every call and on session resumption, and requires a
  daemon token bound to that device (`ExchangeDaemonToken`).
- Roster gossip through `TrustService` after every new client connection and in
  every peer-sync round (`internal/replication/peersync`).
- Daemons pin the gateway key and issuer at enrollment; endpoint moves require
  an account-bound assertion signed by the pinned key
  (`internal/security/trust/gateway_endpoint.go`, `internal/link`).
- Screen sessions verify an Ed25519 binding of the offer, DTLS fingerprint,
  session and grants with the daemon's roster key; media stays DTLS-SRTP.
- Vault keys are sealed to member keys, and new members are approved by
  comparing codes on two machines (`internal/security/vault`).
- You can [run your own gateway](../site/content/docs/gateway.md); the gateway
  is a small, separately deployable service with signed release bundles.

**Residual risk:**

- The metadata listed above, and denial of service.
- A gateway that presents a different roster forces every device that sees it
  into a conflict. Recovering means starting a new roster
  (`dieter device init --replace`) and pairing every device again, and that
  step trusts the gateway's account view at that moment.
- `dieter setup` starts a roster when the gateway reports none, with a warning.
  A gateway that hides an existing roster can split a new machine off into a
  roster of its own; it still cannot add devices to either roster.
- People can be talked into typing a code they did not see on their own new
  device. `dieter device approve` warns about this, and every addition appears
  as a notice on the apps' Devices screen.
- Anyone who holds the recovery key can sign a device into the roster.

### Malicious or compromised peer daemon (same account)

**Can:** act as an operator of every other machine in the account (its roster
key and enrollment authenticate `dieter --machine` calls), add or remove
devices (roster membership is flat), write shared records (projects, boards,
labels, placement, portable settings), decrypt vault items while it is a
member, and send oversized or malformed peer traffic.

**Mitigations:**

- Peer records have hard limits on records, actors, versions, value, state and
  page size (`internal/replication/crdt/store.go`) and are validated against the
  record schema (`internal/replication/schema`). Rejections stay visible in
  `dieter peer status`.
- Owner-scoped fields carry provenance signatures verified against the owner
  daemon's roster key, so a peer can relay but not forge another machine's
  ownership claims (`internal/replication/crdt/provenance.go`,
  `internal/store/replica/provenance.go`).
- `dieter device revoke DEVICE_ID` from any trusted device removes the machine
  from the roster; every daemon refuses it as soon as it sees the signed
  revocation, on established connections too. `dieter machine revoke` (gateway
  `RevokeDaemon`) also closes its gateway links at once.
  `dieter vault remove-member` rotates the vault key away from it.
- Every roster change is listed on the apps' Devices screen ("Pixel 9 was added
  by Studio") and by `dieter device roster`, with the device that signed it.

**Residual risk:** machines of one account trust each other with operator
access. Keep untrusted hosts out of the account.

### Other accounts on the same gateway

The gateway opens tunnels only from an account's own sessions to its own
daemons, and the account is resolved from the current session or enrollment,
never from request input (`internal/gateway/hub.go`, `internal/gateway/relay.go`;
`hub_security_test.go`, `tunnel_test.go`). Roster entries and pairing requests
are scoped to the caller's account (`roster_test.go`), and a roster bound to
another account or gateway never verifies. Unauthenticated work is rate limited
per client network (IPv4 address or IPv6 /64) and public messages are
size-limited before allocation (`internal/gateway/ingress.go`).

### Stolen device or session

- **Client device.** Reaching a machine takes both the app's device key and a
  current gateway session (`DIETER_NATIVE_SESSION_TTL`). Device keys are
  non-exportable where the hardware allows: a Secure Enclave key on macOS
  (stored as an opaque blob in the app's user-only Application Support file,
  never in the Keychain) and iOS (device-only Keychain), and an Android Keystore
  key (StrongBox when available). Macs without a Secure Enclave and iOS
  simulators use a software key, which a copy of the file or Keychain item
  carries along. The macOS session file is not encrypted by the app; Android
  encrypts sessions with a device-bound Keystore key; iOS uses device-only
  Keychain items. Clients never hold GitHub tokens or provider credentials.
  Remove a lost device from any trusted device (Devices → Remove, or
  `dieter device revoke DEVICE_ID`); machines refuse it from the next call
  after they see the revocation. Until then, treat a lost unlocked device as a
  compromised one.
- **Daemon host.** A stolen host exposes everything in `DIETER_HOME`, including
  the identity key that is its roster key, the checkouts and the provider
  credentials. Remove it from the roster (`dieter device revoke`), revoke it at
  the gateway (`dieter machine revoke`), remove it from the vault, and rotate
  provider credentials. `dieter daemon unenroll` on a host you still control
  removes it from the roster, signs its own gateway revocation and deletes its
  key.
- **Recovery key.** The roster recovery key can sign any device into the
  roster, but only into the roster whose root it commits to. Keep it offline. If
  it leaks, revoke it with `dieter device revoke`; a new one comes only with a
  new roster (`dieter device init --replace`).
- **Native sign-in.** The gateway ends app sign-in on a confirmation page that
  names the account and the app callback, so another app on the device cannot
  silently complete a sign-in; only configured native redirect URIs are
  accepted, never loopback (`internal/gateway/auth_native.go`). Daemon
  enrollment needs a separate browser approval of the machine name and code
  (`internal/gateway/auth_enrollment.go`).

### Prompt injection against unsandboxed agents

Agents read untrusted text all the time: web pages, issues, dependency sources,
test output, files in the repository. Any of it can instruct the agent.

**Can:** an injected agent runs commands as the daemon user. It can read and
exfiltrate the checkout, provider credentials, SSH keys, the daemon identity key
(which is also the machine's roster key), the local API token and the vault
member key; it can call the `dieter` CLI, including `--machine` operations on
every other machine of the account; with the identity key it can act as this
machine's device outside the CLI, including approving a device; and it can send
data to its model provider or any network destination.

**Mitigations (guardrails, not isolation):**

- Vault access is opt-in per conversation at creation, mediated by a per-turn
  token (`DIETER_TURN_TOKEN`), audited, and revealed passwords are redacted from
  stored transcripts (`internal/api/vault.go`, `internal/engine`). An agent that
  reads `DIETER_HOME` directly bypasses this; it prevents mistakes and leaves a
  trail, nothing more.
- Agent mail is opt-in per conversation and schedule at creation and mediated
  by the same turn token (`internal/api/mail.go`). Agents may only send; every
  other `MailService` call refuses a turn token, so one conversation can't
  read another's reports or use the mailbox to relay instructions. A turn can't
  grant mail access to a card, chat or schedule it creates unless its own
  conversation has it. Mail bodies pass through the turn's vault redaction
  before they are stored. The apps render a fixed Markdown subset without HTML,
  never load images or other remote content, and resolve relative links only
  inside the sender's checkout. As with the vault, an agent that writes
  `DIETER_HOME` directly bypasses this.
- Agent turns cannot change device trust. `dieter device` mutations
  (`init`, `approve`, `revoke`, `recover`, `sync`) and `dieter daemon unenroll`
  refuse a turn token, also with `--machine`, and the daemon refuses
  `TrustService` mutations that carry one (`internal/cli/rpc_device.go`,
  `internal/api/trust.go`). An agent that uses the identity key directly
  bypasses this.
- Harness workers start with an allowlisted environment (basic user variables,
  provider keys and proxy settings), plus only the names listed in
  `DIETER_HARNESS_ENV` (`Environment.harnessEnvironment` in
  `internal/harness/harness.go`). This limits accidental leakage of the
  daemon's environment; it does not hide files the user can read.
- Harness-level approval and sandbox settings of the underlying tools (Codex,
  Claude Code, …) still apply when you configure them.

**Recommendations:** run the daemon as a dedicated OS user, in a VM or on a
separate machine for work on untrusted repositories or inputs; keep production
credentials off agent hosts; grant vault access only to conversations that need
it.

**Non-goal:** Dieter does not sandbox agents or police their tool calls.

### Local attackers on a daemon host

- Other local users, containers sharing the host network, and request-forgery
  bugs in other local services can reach `127.0.0.1:4242` but not the token:
  every raw request must present the per-start random token from
  `DIETER_HOME/runtime/local-api-token` (mode 0600, rotated on every start;
  `internal/security/localauth`).
- `DIETER_HOME` files are written atomically with user-only permissions
  (`internal/platform/fsx`); the gateway `.env` must be mode 0600
  (`internal/platform/config/envfile.go`).
- Same-user processes are inside the boundary (see prompt injection).
- On macOS the privacy helper is a separately signed bundle; the daemon stays
  unprivileged and the helper accepts only clients signed by the pinned Apple
  team (`native/macos`, `internal/host/serviceruntime`).

### Network attackers

- External TLS is TLS 1.3. Every remote call runs mutually authenticated TLS
  1.3 between the calling device and the daemon, pinned to both roster keys,
  plus a short-lived daemon token bound to the calling device
  (`internal/link/tls.go`, `internal/link/direct.go`). The same connection runs
  over a direct TCP candidate, a WebRTC data channel (also through TURN;
  `internal/transport/controlrtc`) or a gateway relay tunnel, so neither the
  network, TURN nor the gateway sees plaintext.
- TURN credentials are ephemeral, derived from a shared secret by the gateway.
- Relay tunnels are bounded per daemon and lane, with an 8-frame credit window
  of 64 KiB frames per direction, inside byte budgets per lane, daemon, account
  and gateway (`internal/transport/relay`); a stalled writer resets only its
  connection.

### Supply chain and release signing

- **Release checksums.** Every release publishes `SHA256SUMS` signed with
  Sigstore cosign keyless signing. The only accepted signer identity is
  `https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main`
  with issuer `https://token.actions.githubusercontent.com`. The Linux installer
  and the managed Linux updater verify exactly that identity
  (`internal/platform/buildinfo.ReleaseSignerPattern`,
  `internal/host/machine/update_linux.go`), generated from
  [`config/identity.json`](../config/identity.json). This identity is a public
  contract; see [releasing.md](releasing.md#signing-identity).
- **macOS.** The daemon, capture helper and privacy helper are Developer ID
  signed and notarized; staged updates verify the signing team before
  activation (`internal/host/serviceruntime`).
- **Android.** The in-app updater installs only an APK whose SHA-256 matches the
  digest GitHub publishes for that release asset; Android still verifies the
  signing key on upgrade.
- **CI secrets.** Signing secrets live only in GitHub environments that
  `main` alone may use, and `main` requires a code owner's approval, so
  unreviewed code never runs with them. Jobs holding them never run npm install
  scripts (the darwin harness runtime archive is built without secrets and
  pinned by hash) and restore only release-scoped caches that CI cannot write.
- **Gateway.** The image and deployment bundle are signed with cosign, with
  build provenance and an SBOM; `deploy/gateway/scripts/bundle.py verify`
  checks them.
- **Dependencies.** Go modules are checksum-verified (`go.sum`); the harness
  runtime installs from `package-lock.json` with integrity hashes, including the
  Claude Code, Codex and OMP CLIs that agent bridges link instead of installing,
  and pinned DSH/Bun versions; vendored Swift packages live in `third_party/`
  with their patches documented; GitHub Actions are pinned by commit SHA.

**Residual risk:** npm and other registries remain upstream trust roots for the
harness runtime that release builders and source-built daemons install, and for
DSH, which daemons install on first use.

## Non-goals

- Sandboxing or policing agents, or protecting a host from its own daemon user.
- Granular client permissions (read-only sessions, per-project scopes).
- Keeping prompts or code away from the model provider you configure.
- Hiding metadata from the gateway or TURN operator: which devices exist,
  their names and keys, presence, direct candidates, which machines talk, when
  and how much, and provider quota snapshots.
- Resisting denial of service by the gateway.
- Protecting a logged-in desktop against physical attackers beyond what macOS
  privacy mode documents ([research notes](../native/macos/privacy-mode-research.md)).
