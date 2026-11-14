# ADR 0002: End-to-end encryption and the device roster

- Status: accepted, implemented 2026-10
- Proposal: [docs/proposals/end-to-end-encryption.md](../proposals/end-to-end-encryption.md)

## Context

Until 0.5 the gateway could read every relayed call and was the root of trust
for every route. Its per-RPC relay decoded protobuf bodies. It issued the daemon
certificates that clients checked on direct and WebRTC TLS, handed clients the
key that verified screen bindings, and signed the tokens and relay assertions
that daemons accepted as the operator. A compromised gateway was an
account-wide remote-code-execution compromise, and the
[threat model](../threat-model.md) listed gateway-independent authorization as
a non-goal. Encrypting the relay alone would not have helped: a party that can
vouch for any key can terminate any encryption.

## Decision

Adopt the proposal's design. Both parts ship together in the 0.6 release line:

- **One secure channel, three carriers.** Every remote call runs TLS 1.3 and
  gRPC end to end between the client device and the daemon's `DirectServer`
  (`internal/link/direct.go`), over a direct TCP candidate, a WebRTC data
  channel or a gateway relay tunnel. The relay is an opaque byte tunnel
  (`RelayService.OpenTunnel`): the gateway splices frames onto the daemon's link
  lane and never parses them. Lanes are resource classes. Per daemon and lane at
  most `relay.TunnelLimit` tunnels are open (control 4, replication 8, command
  32, subscription 32), and each direction has a credit window of 8 frames of
  at most 64 KiB. The per-RPC relay, delegation assertions and the
  `x-dieter-route` marking are deleted.
- **An account device roster the gateway cannot write.** Every daemon and app
  has its own key: daemons their enrolled Ed25519 identity key, apps an ECDSA
  P-256 key in the Secure Enclave or Android Keystore (StrongBox when available),
  with a software key only where the hardware is missing (Macs without a Secure
  Enclave, iOS simulators). The Mac app stores its Secure Enclave key's opaque
  representation in a user-only file and never uses the Keychain. The roster is
  an append-only hash chain (`internal/security/roster`, ported to the Kotlin
  core with shared golden vectors in `tests/fixtures/roster`). The first daemon
  signs the genesis; every later entry is signed by an active member. The
  gateway stores entries and verifies appends, but cannot sign one. Devices pin
  the root and accept only extensions; a member-signed fork at a pinned sequence is a
  conflict, and the device refuses connections until it is reset. Limits: 4096
  entries, 64 active devices, 1 KiB per entry.
- **Mutual TLS pinned to the roster.** A client accepts a daemon only if the
  server key equals the target daemon's roster key. A daemon accepts a client
  certificate only if its key belongs to an active member that may connect, and
  checks membership again on every call. There is no CA, host name or SPIFFE ID.
- **The gateway token stays as a second factor.** `ExchangeDaemonToken` binds
  the daemon token to the caller's roster device ID. The daemon requires both
  the device's TLS key and a token bound to it, so the gateway alone gets
  nothing, and it can still cut off a signed-out session. The operator subject
  stays the GitHub account; the daemon forwards the device ID, and the vault
  audit records it.
- **Gossip.** After a client opens a connection to a daemon, and in every
  peer-sync round between daemons, the two sides compare roster heads through
  `TrustService` (`GetTrustStatus`, `GetDeviceRoster`, `SyncDeviceRoster`), so
  a revocation the gateway withholds still propagates.
- **Screens, replication and vault.** Screen signaling travels inside the
  encrypted channel, the session binding is verified with the daemon's roster
  key, and renegotiation answers carry their own binding. Peer replication uses
  the same carriers on the replication lane, and owner provenance verifies
  against roster daemon keys. The vault's relay refusal is deleted, because
  every remote route is end to end.
- **Clean break.** The release line moves to 0.6 and the gateway floors to
  `0.6.0-dev.0`. Nothing migrates: after upgrading, the first machine starts
  the roster and every other machine and app pairs again.

### Deviations from the proposal

- **Typed code instead of code comparison or QR.** The new device shows a
  one-time 16-character code (80 random bits); a person types it on any trusted
  device (an app's Devices screen or `dieter device approve CODE`). The pairing
  request's proof and the approver's confirmation are HMAC-SHA256 keyed by that
  code (`internal/security/roster/pairing.go`), so the gateway can neither swap
  the new device's key nor pair it into a roster of its own. Nobody compares two
  screens, and codes are never listed. QR pairing is not implemented.
- **First machine.** `dieter device init` starts the roster. `dieter setup` runs
  it automatically when the gateway reports no roster and prints a warning
  instead of asking for confirmation.
- **Recovery key bound to the root.** The recovery key (`DRK1-…`) is printed
  once at `init` and added as a non-connecting member. It commits to the
  roster's root, so it never signs into another roster. `dieter device recover`
  runs on the machine that rejoins; there is no `reset-trust` command.
  `dieter device init --replace` starts a new roster, and every paired device
  then reports a conflict and pairs again.
- **CLI.** The group is `dieter device status|roster|sync|init|requests|approve|revoke|recover`.
  Agents are refused by their turn token; there is no TTY check. `init` and
  `recover` run only on the local route. `dieter daemon unenroll` also revokes
  the machine in the roster and deletes its key.
- **The gateway keeps its daemon CA internally.** Enrollment certificates still
  authenticate daemons to the gateway. They are no longer sent to clients or
  used between devices, and `DaemonRoute` carries no certificates.
- **Gossip through `TrustService`** instead of an `x-dieter-roster-head` header
  on every connection.
- **Pairing requests** expire after 15 minutes (not 10), at most 16 per account,
  and devices poll instead of a `WatchPairingRequests` stream.
- **Tunnel window.** 8 frames of 64 KiB per direction instead of 16.

### Not implemented

- `ROTATE` entries. A device that needs a new key is removed and pairs again.
- QR pairing.
- Phase 4 metadata minimization: provider quota snapshots, daemon names and
  remote-desktop presence are not sealed.
- Publishing the vault member key in the roster; vault membership keeps its own
  join codes.

## Consequences

- The gateway relays ciphertext. It cannot read or change calls, terminals,
  files, executions, peer records, WebRTC signaling or screens, impersonate a
  device, or add one. It still sees metadata: accounts, device IDs, names, kinds
  and public keys, pairing requests, daemon names and presence, direct
  candidates, remote-desktop readiness, tunnel open and close times and sizes,
  client IP addresses, TURN allocations and provider quota snapshots. It can
  deny service and withhold roster entries; gossip detects withheld entries.
- Pairing is a human step on every new device. The residual risk is social
  engineering: a person who types a code they did not see on their own device
  adds someone else's device.
- Endpoint compromise is unchanged. An agent on a daemon host can read the
  identity key and act as that machine.
- A machine that was removed, or that holds a conflicting roster, rejoins only
  with a new key, which means a new enrollment.
- The invariants in [Network and identity](../invariants.md#network-and-identity)
  now name the roster, the opaque tunnel and the agent refusal. The
  [threat model](../threat-model.md) no longer lists gateway-independent
  authorization as a non-goal; hiding metadata still is one.
