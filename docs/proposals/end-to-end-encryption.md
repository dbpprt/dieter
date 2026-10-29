# Proposal: end-to-end encryption, so the gateway relays but cannot read

Status: implemented 2026-10 (see [ADR 0002](../adr/0002-end-to-end-encryption.md))
· scope: gateway, daemon link and transports, Kotlin core, Android and Apple
transport adapters, CLI, peer replication, screens

## Implementation notes

This page is the proposal as written. [ADR 0002](../adr/0002-end-to-end-encryption.md)
records what shipped in the 0.6 release line. The differences:

- **Pairing is a typed code.** The new device shows a one-time 16-character
  code; a person types it on a trusted device (Devices → Add a device, or
  `dieter device approve CODE`). The request proof and the approver's
  confirmation are HMAC-SHA256 keyed by that code. There is no code comparison
  on two screens and no QR pairing; §3.3 A and B describe the earlier design.
- **First machine and recovery.** `dieter device init` starts the roster and
  prints a recovery key that commits to the roster's root. `dieter setup` runs
  `init` when the gateway reports no roster, with a warning rather than a
  prompt. `dieter device recover` rejoins a machine with that key. There is no
  `reset-trust`; `dieter device init --replace` starts a new roster.
- **CLI.** `dieter device status|roster|sync|init|requests|approve|revoke|recover`.
  Agents are refused by their turn token, without a TTY check.
- **Gateway trust roots.** The gateway keeps its daemon CA to authenticate
  daemons to itself; clients and devices never see or use it.
- **Storage.** The gateway verifies every roster append, so it never serves a
  chain devices would reject; it still cannot sign one. Daemons pin the roster
  in `DIETER_HOME/daemon/roster.pb`.
- **Gossip** runs through `TrustService` after each new connection and in every
  peer-sync round, not through an `x-dieter-roster-head` header.
- **Bounds.** Tunnels have an 8-frame credit window; pairing requests live 15
  minutes.
- **Not implemented:** `ROTATE` entries, QR pairing, Phase 4 (sealed quota and
  presence metadata) and vault keys in roster entries.

## TL;DR

Today the gateway can read every relayed call, and it is also the root of trust
for every route. It issues the daemon certificates that clients check on direct
and WebRTC TLS, it hands clients the key that verifies screen bindings, and it
signs the bearer tokens and relay assertions that daemons accept as "the
operator". Encrypting the relay alone would not help: a gateway that can vouch
for any key can terminate any encryption and can call `ListMessages` itself.

To make the gateway a blind relay, two things have to change together:

1. **One secure channel, three carriers.** The relay becomes an opaque byte
   tunnel. Every remote call (direct TCP, WebRTC data channel, gateway tunnel)
   runs TLS 1.3 and gRPC end to end between the client and the daemon's
   existing `DirectServer`. That is what the WebRTC route already does today.
2. **An account device roster that the gateway cannot write.** Every daemon and
   every client has its own key. The account's set of keys is an append-only,
   hash-chained log in which each entry is signed by an existing device. A new
   device is added only after a QR scan or code comparison between two devices
   (the vault join-code model, applied to all devices). The gateway stores and
   distributes the log but cannot extend it. Clients pin daemon keys from the
   roster, and daemons accept only roster clients, through mutual TLS.

After both changes the gateway still authenticates people for its own service,
delivers presence, relays bytes and issues TURN credentials. It cannot read or
alter chats, terminals, files, executions, peer records, WebRTC signaling or
screens. It cannot impersonate a daemon to a client or a client to a daemon,
and it cannot add a device. What it keeps is metadata and the ability to deny
service.

Execution is four phases. Phase 1 (the opaque tunnel) can ship alone and stops
passive reading. Phases 2–3 (roster, mutual TLS, deleting the gateway's trust
roots) stop an active gateway. Phase 4 (metadata) is optional.

---

## 1. Where we are

What a gateway operator, or anyone holding the gateway's keys, database or
logs, can do today:

| Capability                          | Evidence                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Read every relayed call             | The relay server terminates client TLS, reads the protobuf body with `RawCodec`, hashes it and forwards it in a `DaemonLinkFrame` (`internal/gateway/relay.go:31-37,106-118`). Responses return the same way. The daemon calls these "plaintext-visible gateway relay calls" (`internal/link/gateway_client.go:782-788`).                       |
| Act as any operator                 | Daemons accept any delegation (`relay.go:106`) or daemon token (`internal/link/direct.go:91`) signed with the gateway signing key. The subject is just `github:<id>`. The gateway can mint either for any request.                                                                                                                              |
| Impersonate a daemon on every route | The gateway owns the daemon CA and issues every daemon leaf (`internal/gateway/crypto.go:145`). Clients fetch the CA on every route selection (`service.go:552`, `RouteSelector.kt:122,204`) and pin nothing across sessions. Direct TLS and the TLS inside WebRTC therefore protect against the network and TURN, but not against the gateway. |
| Read and rewrite WebRTC signaling   | `StartControlConnection` (control route) and `StartRemoteDesktop` / `SendRemoteDesktopSignal` (screens) usually travel over the relay, so the gateway sees SDP, ICE candidates and binding. The client does not check the control route's DTLS fingerprint (`RouteSelector.kt:188-198`).                                                        |
| Substitute the screen-binding key   | The client verifies the daemon's Ed25519 screen binding with the leaf certificate from `ResolveDaemonRoute` (`screens/ScreenRoutes.kt:17-23`). It does not check the chain or pin the key. A gateway that returns its own certificate can re-sign a binding for its own DTLS fingerprint.                                                       |
| Read peer records                   | Peer replication falls back to the relay (`internal/replication/peersync/peer.go`). `value_json` holds project names, prompts, board and label instructions, card titles and schedules in plaintext. Owner provenance verifies against the gateway CA (`internal/store/replica/provenance.go:21,122`).                                          |
| Read vault secrets (active attack)  | The vault refuses the relay but explicitly allows direct and WebRTC routes (`internal/api/vault.go:205-206`). Both of those authenticate the daemon with gateway-issued certificates, so the refusal stops only a passive gateway.                                                                                                              |
| Store account metadata              | Daemon names, public keys, direct candidates (IP addresses), remote-desktop presence, and provider quota snapshots including `display_email` and spend (`internal/gateway/storage.go`, `quota_storage.go`).                                                                                                                                     |

Two parts are already end-to-end and serve as models. Vault items are sealed to
member keys with join-code approval (`internal/security/vault`). Screen media is
DTLS-SRTP, and TURN sees only ciphertext.

The [threat model](../threat-model.md) documents all of this honestly ("a
gateway compromise is an account-wide remote-code-execution compromise"). It
lists "gateway-independent end-to-end authorization of client calls" as a
non-goal. This proposal turns that non-goal into a goal.

## 2. Goals and non-goals

**Goals.** These hold against an active, malicious gateway, including theft of
its signing keys and database, and against the TURN operator and the network:

- G1. The gateway cannot read or modify any `dieter.v1` call or response:
  transcripts, prompts, attachments, files, terminals, remote execution, Git,
  vault, settings, peer records, and screen and control signaling.
- G2. The gateway cannot impersonate a daemon to a client or peer, or a client
  or peer to a daemon.
- G3. The gateway cannot add a device to an account, or silently keep a revoked
  one active.
- G4. If the gateway shows different devices different views of the account
  (equivocation), the devices detect it the next time they talk to each other.
- G5. Screen media, input and clipboard stay end-to-end, including through TURN.

**Non-goals** (unchanged or explicitly accepted):

- Hiding metadata: which devices exist and are online, who connects to whom,
  when, and how many bytes flow. Phase 4 reduces this but does not eliminate it.
- Resisting denial of service by the gateway.
- Protecting against compromised endpoints. A prompt-injected agent still runs
  as the daemon user and can read its keys.
- Scopes or read-only devices. Device access stays binary, as
  [invariants.md](../invariants.md#network-and-identity) requires.
- Changing what reaches model providers.

## 3. Design

### 3.1 Device identities

Every participant has a long-term signing key whose private half never leaves
the device:

| Device      | Key                                              | Storage                                                                                                        |
| ----------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| Daemon      | The existing enrolled Ed25519 `identity-key.pem` | `DIETER_HOME`, unchanged (one writer, `internal/link`). The CLI and peer sync on that host act as this device. |
| Android app | New ECDSA P-256 key, non-exportable              | AndroidKeyStore (StrongBox when available, TEE otherwise)                                                      |
| iOS app     | New ECDSA P-256 key                              | Secure Enclave, `ThisDeviceOnly`                                                                               |
| macOS app   | New ECDSA P-256 key                              | Secure Enclave key, not a Keychain item (below). No prompts.                                                   |

**No Keychain on macOS.** The Mac app deliberately moved off the Keychain
because its ACLs follow the code signature: every ad-hoc development rebuild
looked like a new app and prompted again. The device key avoids the Keychain
entirely:

- CryptoKit `SecureEnclave.P256.Signing.PrivateKey` is created without an
  access-control policy, so signing is silent.
- Its `dataRepresentation` is an opaque blob that only this Mac's Secure
  Enclave can use. It lives in the app's existing 0600 Application Support
  file, next to the session.
- A copied file is useless on another machine, which is stronger than today's
  plaintext session token.
- The app signs once per TLS handshake, not per call.
- A migrated or restored Mac gets a new key and is paired again.
- If Phase 0 finds Secure Enclave creation needs entitlements that ad-hoc
  development builds lack, those builds use a software key in the same file.
  They still never touch the Keychain.

P-256 is chosen for clients because it is the only curve all three platforms
keep in hardware and the curve every TLS stack in use (Go, Conscrypt, NIOSSL)
accepts for client certificates. Phase 0 confirms this (§5). Each device
presents its key as a self-signed X.509 certificate. The certificate is only a
container. Trust comes from the roster, never from an issuer.

A device ID is `base32(SHA-256(SPKI))[:20]`, so an ID cannot be bound to a
different key.

### 3.2 The account device roster

A roster is an append-only, hash-chained log per account:

```text
RosterEntry {
  account     // "<gateway issuer>|github:<numeric id>"; stops replay into another account
  seq         // 0, 1, 2, …
  prev        // SHA-256 of the previous entry's canonical encoding (zero for seq 0)
  op          // GENESIS | ADD | REVOKE | ROTATE
  device {    // subject of the operation
    id, kind (daemon|client), platform, display_name,
    public_key (alg, SPKI), daemon_id (for daemons)
  }
  signer      // device ID of a member that is current at seq-1 (the subject itself for GENESIS)
  signature   // over "dieter-roster-v1" ‖ canonical(entry without signature)
}
```

Rules, implemented once in Go (`internal/security/roster`) and once in the
Kotlin core (`core/runtime/.../trust`), with shared golden vectors in
`tests/fixtures`:

- `GENESIS` is self-signed by the first device. The account's **root hash** is
  the hash of the genesis entry.
- `ADD` and `REVOKE` must be signed by a member that is current at `seq-1`.
  Membership is flat: any member can add or revoke any device, matching the
  binary-access invariant. A device may revoke itself.
- `ROTATE` replaces a device's key and is signed by the old key.
- A device accepts a chain only if it extends the head it has pinned. It never
  accepts a different entry at a sequence number it has already seen. A
  conflicting entry at a known `seq` is equivocation (§3.8).
- Hard limits, enforced on both sides: 64 active devices, 4096 entries, 1 KiB
  per entry. This matches the bounded style of `internal/replication/crdt`.

**Storage.** The gateway stores the entries as opaque signed blobs in one new
table and serves them through new `GatewayService` RPCs:

- `GetDeviceRoster(after_seq)`
- `WatchDeviceRoster`
- `AppendDeviceRoster(entry, expected_head)`, a compare-and-swap. A concurrent
  append fails with `Aborted`, and the client rebases and retries.

The gateway checks only the account binding and the size limits. It does not
verify signatures, because the devices do. Daemons keep the verified chain in
`DIETER_HOME/trust/roster.pb` (atomic writes under the central lock). Clients
keep it in the core's on-device store, next to `accounts.pb`.

### 3.3 Pairing: adding a device

> As built, pairing uses a code the new device shows and a person types on a
> trusted device; see [Implementation notes](#implementation-notes).

The gateway is the mailbox, never the judge. A pairing request is an unsigned
note on the gateway that holds the new device's public key, display name, kind
and a random request ID. It expires after 10 minutes. The new RPCs are
`PostPairingRequest`, `ListPairingRequests` and `WatchPairingRequests`.

Both flows are mutual. The new device must learn the real roster head, and the
existing device must learn the real new key. A gateway that substitutes either
one changes the code.

**A. Code comparison** works everywhere, including headless Linux:

1. The new device posts its request and fetches the roster from the gateway. It
   cannot trust the roster yet.
2. Both sides compute
   `code = Crockford(SHA-256("dieter-pair-v1" ‖ root hash ‖ head hash ‖ new key)[:10])`
   and display it in 4-character groups. This is the same construction as
   `vault.JoinCode`, so the code paths can share it.
3. The approver (the app's "Devices" screen, or `dieter device approve` on a
   daemon host) shows the pending device's name and code. The person confirms
   that the code matches what the new device shows, and the approver appends a
   signed `ADD`.
4. The new device sees its `ADD` on top of the head it computed the code from,
   and pins that head.

**B. QR scan** is the one-step path for phones and tablets:

1. The existing device (the app, or `dieter device pair` printing an ANSI QR in
   the terminal) shows
   `QR = {gateway, account, head seq/hash, approver ID, 128-bit one-time secret}`.
2. The new device scans it, pins the head from the QR, and posts its request
   with `HMAC(secret, new key)`.
3. The approver verifies the HMAC and appends the `ADD` without a typed code.

**First device and new daemons.** `dieter daemon enroll` keeps its browser
approval at the gateway, which authenticates the account. Afterwards the daemon
asks the gateway for the account roster:

- **The roster is empty.** The daemon creates the genesis only after an explicit
  prompt: "No trusted devices exist for this account. If you already use
  Dieter on other devices, stop: your gateway may be compromised."
- **The roster is not empty.** The daemon posts a pairing request, prints the
  code, and waits. Clients will not trust it, and it will not answer them,
  until a member approves it.

**Recovery when every device is lost.** At genesis the daemon prints a roster
recovery key: a 256-bit seed whose Ed25519 key is added as a non-connecting
`recovery` member. It mirrors the vault's recovery key and can sign `ADD`
entries. Without it, the only way back is a per-host reset
(`dieter device reset-trust` on each daemon host), which starts a new genesis.
Each reset is a local action on that host. The gateway can never reset trust.

**Guardrails against agents.** `dieter device approve|pair|revoke` refuse to
run when `DIETER_TURN_TOKEN` is set or there is no TTY. Every roster change
appears as a security notice on every client ("Pixel 9 was added by MacBook
Pro"), so an unexpected addition is visible.

### 3.4 The secure channel: mutual TLS pinned to the roster

The daemon's `DirectServer` (`internal/link/direct.go`) becomes the only
endpoint for remote calls, whatever the carrier:

- **Server certificate.** The daemon presents a self-signed certificate for its
  identity key. The client accepts the TLS handshake only if the server SPKI
  equals the roster key of the daemon ID it dialed. This replaces the
  CA-plus-SPIFFE check on Android (`OkHttpTransport.kt` `DaemonTrustManager`),
  Apple (`DaemonCertificatePinning.swift`) and Go (`link.DialDirect*`).
- **Client certificate.** The daemon sets
  `tls.Config{ClientAuth: RequireAnyClientCert}` and checks in
  `VerifyPeerCertificate` that the client SPKI belongs to a current roster
  member. Daemons dialing peers (peer sync, `dieter --machine`) present their
  identity key.
- **Caller identity.** Operator identity comes from the TLS peer, not from a
  token. The daemon forwards `x-dieter-device-id` to `internal/api`, which
  records the device on turns, vault audit and executions. The device name is
  more useful in audits than `github:<id>`.
- **Roster gossip.** Every connection carries `x-dieter-roster-head`
  (`seq:hash`) in both directions (§3.8).
- **Resumption.** TLS 1.3 session resumption without 0-RTT keeps reconnects
  cheap on the relay carrier.

**Gateway admission stays, as a second factor.** The daemon still requires a
gateway daemon token, and that token is now bound to the device key through the
reserved `ExchangeDaemonTokenRequest.client_key_thumbprint`
(`api/proto/dieter/gateway/v1/gateway.proto:212`). A call needs both a roster
device and a current gateway session. The gateway can therefore still cut off a
signed-out session immediately, a stolen bearer is useless without the device
key, and a gateway acting alone gets nothing. Delegation assertions are deleted
(§4).

### 3.5 Carriers

| Carrier       | Today                                              | After                                                                                   |
| ------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Direct TCP    | TLS to `DirectServer`, gateway-CA trust            | Same socket, mutual TLS with roster pins                                                |
| WebRTC        | TLS over `dieter-control-tls-v1` to `DirectServer` | Same, with roster pins. Signaling now runs inside the tunnel, invisible to the gateway. |
| Gateway relay | Per-RPC protobuf relay the gateway can read        | **Opaque byte tunnel** to `DirectServer`, carrying the same TLS as the other two        |

The relay tunnel:

- **Gateway API.** One new client-facing bidirectional RPC,
  `RelayService.OpenTunnel(stream TunnelFrame) returns (stream TunnelFrame)`.
  The first frame names the daemon and a lane class. The gateway authenticates
  the session as today, checks that the daemon belongs to the account, and
  splices frames.
- **Link frames.** `OPEN_TUNNEL`, `TUNNEL_DATA` and `TUNNEL_END` are added. The
  existing `WINDOW_UPDATE` and `CANCEL_RPC` frames are reused for credit flow
  control and reset. `OPEN_RPC`, `REQUEST_*`, `RESPONSE_*` and `RPC_ERROR` are
  deleted.
- **Daemon side.** On `OPEN_TUNNEL` the daemon dials its loopback `DirectRoute`
  listener and pipes bytes, exactly as `internal/transport/controlrtc/manager.go`
  already does for WebRTC. One splice helper serves both.
- **Lanes become tunnel classes.** The class is chosen at open: control,
  replication, command or subscription. It selects the daemon link connection
  and the per-lane budget, as now. The Kotlin core opens one command tunnel and
  one subscription tunnel per daemon, so watch traffic cannot starve commands
  at the gateway hop. Peer sync uses the replication class.
- **Bounds.** Tunnel counts per lane, daemon, account and gateway, a 16-frame
  credit window of 64 KiB chunks per tunnel, and the existing buffered-byte and
  write-timeout limits in `internal/transport/relay`. A stalled tunnel resets
  only itself. Cancelling an RPC inside the tunnel is an HTTP/2 `RST_STREAM`
  the gateway never sees, and it still never stops an agent.
- **Client side.**
  - Android/JVM: OkHttp duplex HTTP/2 to the gateway, bridged through the
    loopback socket pattern of `ControlRTCBridge`.
  - Apple: a grpc-swift bidirectional stream bridged the same way.
  - Go CLI and peer sync: a `net.Conn` adapter.
  - The Apple bridge's unary and server-streaming limitation for relay
    disappears, because relay calls are now ordinary gRPC over TLS.
- **Routing and hedging.** Route preference and hedging in
  `RouteSelector`, `peersync` and `cli/client_transport.go` stay as they are.
  The only change is that "relay" yields a TLS connection like the other
  routes.

### 3.6 Screens

- **Signaling.** `StartRemoteDesktop`, `SendRemoteDesktopSignal` and
  `ExchangeRemoteDesktopClipboard` travel inside the tunnel, so offer, answer,
  ICE candidates and CLI clipboard data are no longer visible to the gateway.
- **Binding key.** The client verifies the screen binding with the daemon's
  roster key instead of `daemon_certificate_pem` (`ScreenTrust.kt`,
  `ScreenRoutes.kt`).
- **Renegotiation.** Renegotiation answers get a fresh binding (today they
  have none, `remotedesktop/manager.go:924-941`). Over an authenticated channel
  the binding is defense in depth. It stays because it ties the DTLS
  fingerprint to the session and its grants independently of the carrier.
- **Media.** Unchanged. It is DTLS-SRTP, and TURN relays ciphertext.
- **RTC configuration.** The gateway still signs the TURN/ICE configuration,
  bound to the account. The daemon checks the account from the admission token
  rather than comparing operator subjects (`controlrtc/manager.go:60`,
  `remotedesktop/manager.go:454`).

### 3.7 Peer replication and the vault

- **Peer replication.**
  - Peer sync dials through the same carriers with mutual TLS. Replication
    payloads stop being gateway-visible in Phase 1.
  - The target daemon can now tell a peer daemon from a client, because the
    device kind is in the roster.
  - Owner provenance (`internal/replication/crdt/provenance.go`,
    `store/replica/provenance.go`) verifies against the roster key of the owner
    daemon, not against the gateway CA.
- **Vault.**
  - Once Phase 3 lands, every remote route is end-to-end and the caller is a
    roster device. The relay refusal in `internal/api/vault.go` is then deleted
    rather than extended.
  - Optional follow-up: publish each daemon's X-Wing vault key in its roster
    entry, so a roster `ADD` approves vault membership at the same time and the
    separate join code goes away.

### 3.8 Freshness, equivocation and revocation

- **Head exchange.** Every mutual TLS connection, and every peer-sync round,
  exchanges roster heads.
  - Equal heads: nothing happens.
  - The peer is ahead: fetch from the gateway and verify. If the gateway does
    not serve the missing entries, ask the peer, through
    `TrustService.GetRosterEntries`, a new daemon RPC with a
    `dieter device sync` CLI command.
  - A different hash at a shared `seq`: equivocation. Refuse the connection,
    record evidence in `dieter device status`, and alert on every client.
- **Revocation.** The revoking device appends `REVOKE` and then pushes its new
  head to each online daemon directly. A gateway that withholds the entry from
  some daemons is caught by the head exchange on the next peer-sync round (at
  most minutes). `dieter machine revoke` / `RevokeDaemon` at the gateway still
  cuts the relay immediately as well.
- **Rollback.** Pinned heads only move forward, so serving an old roster is
  rejected.

### 3.9 What the gateway still sees and can do

**Still visible to the gateway:**

- Account, device IDs, kinds and display names, and public keys.
- Daemon presence, release versions and direct candidates (IP addresses and
  ports).
- Remote-desktop readiness.
- Pending pairing notes.
- Tunnel open and close times, lane classes and byte counts.
- Client IP addresses.
- TURN allocations.
- Provider quota snapshots, until Phase 4.

**Still possible for the gateway:**

- Deny or delay service: refuse sign-in, tokens, tunnels, roster appends or
  pairing notes.
- Withhold roster updates. This is detected (§3.8).
- Serve a phishing sign-in page. Sign-in alone no longer grants anything
  without a pairing approval on an existing device.

**No longer possible:** reading or changing anything inside a tunnel or WebRTC
channel, minting an operator, presenting a daemon key, or adding a device.

Code integrity does not depend on the gateway. Releases are verified against
the Sigstore identity, notarization and APK digests, and the gateway delivers
compatibility floors, never code.

## 4. What gets deleted (clean break, one floor bump)

**Gateway trust roots and the plaintext relay:**

- **Daemon CA:** `Keys.DaemonCA*`, `IssueDaemonCertificate`
  (`internal/gateway/crypto.go`), `DaemonRoute.daemon_ca_pem`,
  `daemon_certificate_pem`, `DaemonCredential.daemon_ca_pem` /
  `certificate_pem`, and `link.Identity.DaemonCAPEM` / `CertificatePEM`.
- **Delegation assertions:** `DelegationClaims`, `SignDelegation`,
  `ParseAndVerifyDelegation` and `consumeRelayProof`.
- **Per-RPC relay:** the per-RPC relay server (`internal/gateway/relay.go`), the
  per-RPC `DaemonLinkFrame` kinds, and `GatewayClient.relayLocal`.

**Daemon-side checks the redesign makes obsolete:**

- `x-dieter-route: relay` and the vault relay refusal.
- The "plaintext-visible" relay marking.

**Client code that reads gateway-supplied trust:**

- `daemon_ca_pem` and `daemon_certificate_pem` readers in `RouteSelector.kt`,
  `ScreenRoutes.kt`, `OkHttpTransport.kt`, `NativeRpc.kt`, `CoreRpcBridge.swift`
  and `cli/client_transport.go`.
- The CA-plus-SPIFFE check in `DaemonCertificatePinning.swift`, which becomes an
  SPKI check.

The gateway signing key stays for the gateway's own concerns: daemon tokens
(now thumbprint-bound), RTC configuration envelopes and endpoint moves.

## 5. Phases

### Phase 0: decide and spike

- Write ADR 0002, which amends three invariants:
  - The gateway also stores a signed device roster and short-lived pairing
    notes.
  - Remote calls are mutually authenticated by roster keys.
  - The relay is an opaque byte tunnel.
- Spike client certificates with hardware keys on each stack, and fall back to
  software P-256 sealed with the platform key store where a stack refuses:
  - Conscrypt with an AndroidKeyStore P-256 `X509KeyManager` through OkHttp.
  - NIOSSL `NIOSSLCustomPrivateKey` backed by a CryptoKit Secure Enclave key
    on iOS and macOS. On macOS, confirm that ad-hoc and Developer ID builds
    without Keychain entitlements can create the key and sign silently.
  - Go server verification.
- Add an **adversarial gateway** mode to `internal/testkit/topology`. It records
  every byte it relays and stores, and it can attempt MITM, operator forgery,
  key substitution, rollback and equivocation. Its first tests document today's
  leaks; later phases make them pass.

### Phase 1: opaque relay tunnel (stops passive reading)

- Add the tunnel RPC and link frames (§3.5), the gateway splice with lane
  budgets, the shared daemon splice helper with `controlrtc`, and the Kotlin,
  Apple and Go carriers.
- Delete the per-RPC relay and delegation assertions. Raise the floors.
- Daemon trust still chains to the gateway CA in this phase, so the vault relay
  refusal stays until Phase 3.
- Ships alone. It is independent of any pairing UX and closes the
  database/log/curious-operator exposure at once.

### Phase 2: device roster, pairing and mutual TLS (stops active attacks)

- Add `internal/security/roster` and the Kotlin core port with golden vectors.
- Add gateway storage, roster and pairing RPCs, and daemon roster sync and
  storage.
- Add the CLI group `dieter device list|status|pair|approve|revoke|sync|reset-trust`
  with offline help, the generated CLI reference, and the `dieter-cli` skill.
- Add the shared Compose "Devices" screen and the SwiftUI equivalent:
  approvals, codes, QR scanning, security notices.
- Change enrollment as described in §3.3.
- Switch every carrier to roster-pinned mutual TLS.
- Bind daemon tokens to device thumbprints.
- Switch the screen binding key and peer provenance to the roster.
- Add head gossip and equivocation evidence.

### Phase 3: remove the gateway as a trust root

- Delete everything in §4 that Phase 1 left: the CA, certificates in
  credentials and routes, and the vault relay refusal.
- Rewrite `docs/threat-model.md` (the gateway section, residual risk and
  non-goals), `docs/invariants.md`, `docs/architecture.md`, and the user pages
  `site/content/docs/security.md`, `architecture.md` and `gateway.md`.
- Ship Phases 2 and 3 in one release so existing accounts move once.

### Phase 4 (optional): metadata minimization

- Seal provider quota snapshots to roster devices. Clients aggregate the
  summaries, and the gateway stores ciphertext and per-machine freshness only.
  The quota account-correlation HMAC key moves from the gateway to the devices.
- Seal daemon display names and remote-desktop presence details the same way.
  Online state and candidates stay in the clear, because routing needs them.

## 6. Verification

- **Go unit tests** for roster verification: forks, rollback, wrong account,
  non-member signer, revoked signer, limits. Golden vectors are shared with the
  Kotlin core.
- **Canary acceptance tests** (`-tags e2e`, adversarial topology). Send a chat
  message, terminal input, file content, an execution, a clipboard exchange and
  a project name, each containing a random canary. Assert that the canary
  appears in none of the gateway's relayed bytes, logs or SQLite. Run this over
  the relay, WebRTC with TURN only, and direct routes. This is the headline
  acceptance criterion for G1.
- **Active-attack tests.** In each case the attack must fail and leave evidence:
  - The gateway presents its own server key.
  - It opens a tunnel with its own client key.
  - It mints a token without a device.
  - It swaps the screen-binding certificate.
  - It rewrites SDP inside a tunnel (impossible by construction).
  - It withholds a `REVOKE`.
  - It serves two forks.
- **CLI parity.** Every `dieter device` command runs over local, direct TLS,
  WebRTC and relay (`internal/testkit/topology`), with the help-contract and
  `rpcCommand` mappings.
- **Device flows.** Maestro pairing flows on Android and iOS with the E2E app
  identities: code comparison and QR with a fixture image. The Mac flow pairs
  by code.

## 7. Decisions needed

1. **Client key storage.** Hardware-backed P-256 (recommended) or software keys
   sealed by the platform key store. The Phase 0 spike may force software keys
   on one stack.
2. **Existing accounts.** Fresh pairing of every device on upgrade
   (recommended; clean break, a handful of approvals), or one-time adoption of
   the gateway's current daemon list as the genesis. Adoption trusts the
   gateway once, exactly as much as today, and is migration code.
3. **Gateway admission as a second factor.** Keep the gateway token, bound to
   the device thumbprint, as a second factor (recommended), or rely on the
   roster alone. Dropping it removes the gateway's ability to cut off a stolen
   device before someone appends `REVOKE`.
4. **Roster recovery key at genesis.** Recommended, mirroring the vault. Without
   it, losing every device means a per-host trust reset.
5. **Phase 4.** Do it, or accept quota metadata on the gateway.

## 8. Risks

- **Human verification is the weak link.** People approve codes without
  looking. QR as the default and security notices on every device reduce this.
- **Agents on daemon hosts can approve devices** if they bypass the TTY and
  turn-token checks, for example by reading the identity key. This is no worse
  than today's prompt-injection position. It is documented, not solved.
- **Relay latency.** The relay carrier gains one TLS round trip per tunnel.
  Cached data planes and session resumption amortize it, and the hedging policy
  is unchanged.
- **Platform TLS gaps.** If a stack cannot present hardware-backed client
  certificates, the fallback is a software key in the platform key store
  (Phase 0 decides). A channel-bound signature over the TLS exporter is the
  last resort.
