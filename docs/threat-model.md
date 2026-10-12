# Threat model

Dieter lets authenticated clients drive coding agents that run, unsandboxed, on
your own machines. This document states what Dieter protects, which parties it
trusts, what an attacker in each position can do, and which mitigations exist
today, with pointers into the code. It complements the user-facing
[security model](../site/content/docs/security.md) and the binding
[invariants](invariants.md). Report vulnerabilities as described in
[SECURITY.md](../SECURITY.md).

## Assets

| Asset                                                                   | Where it lives                                                                       |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Source code, working trees and build outputs                            | Daemon hosts (Git checkouts)                                                         |
| Transcripts, prompts, attachments, queues, schedules                    | Daemon `DIETER_HOME` (central store)                                                 |
| Harness and provider credentials (Codex, Claude, Pi, OMP, DSH profiles) | Daemon hosts, in each tool's normal configuration                                    |
| Daemon enrollment key (`identity-key.pem`) and identity                 | Daemon `DIETER_HOME`                                                                 |
| Local API token                                                         | `DIETER_HOME/runtime/local-api-token`, user-only                                     |
| Vault items and member key                                              | Ciphertext replicated to every daemon; member key in `DIETER_HOME/vault/member.json` |
| Client sessions                                                         | macOS user-only file, Android Keystore-encrypted store, iOS device-only Keychain     |
| Gateway signing key, daemon CA, OAuth app secret, session secret        | Gateway state directory and environment                                              |
| Ability to execute code on a daemon host                                | Any authenticated operator path (API, CLI, agent turn)                               |
| Release artifacts and their signatures                                  | GitHub releases, GHCR, Homebrew tap, TestFlight                                      |

The most valuable asset is the last-but-one: **anything that can call a daemon's
API as an operator can run arbitrary commands as the daemon user**, through an
agent turn, a terminal or remote execution. Most of this model is about who can
reach that capability.

## Trust boundaries

```text
 [native client] ──(TLS: direct | WebRTC | relay)──▶ [daemon] ──▶ [harness worker] ──▶ [model provider]
        │                                               ▲   │            (unsandboxed, daemon user)
        └──────── OAuth + session ──▶ [gateway] ────────┘   └──▶ peers of the same account (via gateway)
                                         ▲
                                     [GitHub OAuth]
```

1. **Account boundary.** The gateway isolates allowlisted accounts from each
   other. Inside one account every enrolled daemon and every client session is
   one trust domain: a client session has full operator access to all of the
   account's machines, and there are no read-only scopes (by design; see
   [invariants](invariants.md#network-and-identity)).
2. **Gateway.** The gateway authenticates people (GitHub OAuth, allowlisted by
   immutable numeric user ID) and daemons (enrollment, then key-possession
   proofs), and signs the short-lived assertions that daemons accept for relayed
   and direct calls. It is trusted for authentication and authorization; it is
   not trusted to store or retain Dieter data.
3. **Daemon host and user.** The daemon, its harness workers, terminals and
   remote executions all run as one OS user, without a sandbox. Anything that
   runs as that user is inside the boundary.
4. **Loopback.** The raw daemon API listens on loopback and is guarded by a
   per-start random token readable only by the daemon user.
5. **Model providers.** Prompts, code and tool output go to whatever provider
   the harness is configured for. Dieter does not mediate that data flow.
6. **Release pipeline.** Users trust signed releases from this repository's
   `release.yml` workflow on `main`.

## Threats and mitigations

### Compromised or malicious gateway

**Can:** sign delegation assertions and daemon-targeted bearer tokens that
daemons accept, so a gateway (or an attacker holding its signing key) can call
any RPC on any enrolled daemon of its accounts, which means arbitrary code
execution on those hosts. It can read relayed payloads in transit, deny service,
withhold or delay presence and routes, and serve a malicious sign-in flow.

**Cannot:** read repositories, transcripts or provider credentials at rest
(they are never stored there), forge a daemon's possession proof, decrypt vault
items without a member key, or substitute vault member keys without the join
codes mismatching.

**Mitigations:**

- Daemons pin the gateway key and issuer at enrollment; endpoint moves require
  an account-bound assertion signed by the pinned key
  (`internal/security/trust/gateway_endpoint.go`, `internal/link`).
- Relay assertions are bound to request ID, method, payload hash, daemon
  generation and a short expiry, and each is consumed once
  (`internal/security/trust/tokens.go`, `GatewayClient.consumeRelayProof` in
  `internal/link/gateway_client.go`).
- Commands that return decrypted vault content refuse the relay route
  (`internal/api/vault.go`); vault keys are sealed to member keys and new
  members are approved by comparing codes on two machines
  (`internal/security/vault`).
- Screen media never transits the gateway; screen sessions verify an Ed25519
  binding of the offer, DTLS fingerprint, session and grants.
- You can [run your own gateway](../site/content/docs/gateway.md); the gateway
  is a small, separately deployable service with signed release bundles.

**Residual risk:** a gateway compromise is an account-wide remote-code-execution
compromise. Dieter does not offer end-to-end client-to-daemon authorization that
is independent of the gateway.

### Malicious or compromised peer daemon (same account)

**Can:** act as an operator of every other machine in the account (its
enrollment authenticates `dieter --machine` calls), write shared records
(projects, boards, labels, placement, portable settings), decrypt vault items
while it is a member, and send oversized or malformed peer traffic.

**Mitigations:**

- Peer records have hard limits on records, actors, versions, value, state and
  page size (`internal/replication/crdt/store.go`) and are validated against the
  record schema (`internal/replication/schema`). Rejections stay visible in
  `dieter peer status`.
- Owner-scoped fields carry provenance signatures bound to the owner's enrolled
  certificate, so a peer can relay but not forge another machine's ownership
  claims (`internal/replication/crdt/provenance.go`).
- `dieter machine revoke` (gateway `RevokeDaemon`) closes the machine's relay
  immediately; its direct-route credentials expire within five minutes.
  `dieter vault remove-member` rotates the vault key away from it.

**Residual risk:** machines of one account trust each other with operator
access. Keep untrusted hosts out of the account.

### Other accounts on the same gateway

The relay hub authorizes routes only between an account's own sessions and
daemons, and the account is resolved from the current enrollment, never from
request input (`internal/gateway/hub.go`, `internal/gateway/relay.go`;
`hub_security_test.go`, `relay_security_test.go`). Unauthenticated work is rate
limited per client network (IPv4 address or IPv6 /64) and public messages are
size-limited before allocation (`internal/gateway/ingress.go`).

### Stolen device or session

- **Client device.** A session grants full operator access to the account's
  machines until it expires (`DIETER_NATIVE_SESSION_TTL`) or is signed out. The
  macOS app stores its session in a user-only file that is not encrypted by the
  app; Android encrypts with a device-bound Keystore key; iOS uses device-only
  Keychain items. Clients never hold GitHub tokens or provider credentials.
  There is currently no remote per-session revocation; protect the device and
  OS account, and treat a lost unlocked Mac as a compromised session.
- **Daemon host.** A stolen host exposes everything in `DIETER_HOME`, the
  checkouts and the provider credentials. Revoke the machine
  (`dieter machine revoke`), remove it from the vault, and rotate provider
  credentials. `dieter daemon unenroll` on a host you still control signs its
  own revocation.
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
exfiltrate the checkout, provider credentials, SSH keys, the daemon enrollment
key, the local API token and the vault member key; it can call the `dieter` CLI,
including `--machine` operations on every other machine of the account; and it
can send data to its model provider or any network destination.

**Mitigations (guardrails, not isolation):**

- Vault access is opt-in per conversation at creation, mediated by a per-turn
  token (`DIETER_TURN_TOKEN`), audited, and revealed passwords are redacted from
  stored transcripts (`internal/api/vault.go`, `internal/engine`). An agent that
  reads `DIETER_HOME` directly bypasses this; it prevents mistakes and leaves a
  trail, nothing more.
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

- External TLS is TLS 1.3. Direct routes verify the daemon certificate issued by
  the gateway's daemon CA and a short-lived, daemon-targeted bearer
  (`internal/link/direct.go`). WebRTC API routes carry that same TLS connection
  end to end, including through TURN (`internal/transport/controlrtc`).
- TURN credentials are ephemeral, derived from a shared secret by the gateway.
- Relay queues, messages and concurrent streams are bounded per lane, daemon,
  account and gateway (`internal/transport/relay`); a stalled writer resets only
  its connection.

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
- Gateway-independent end-to-end authorization of client calls.
- Keeping prompts or code away from the model provider you configure.
- Hiding traffic metadata (which machines talk, when, how much) from the
  gateway or TURN operator.
- Protecting a logged-in desktop against physical attackers beyond what macOS
  privacy mode documents ([research notes](../native/macos/privacy-mode-research.md)).
