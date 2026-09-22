**Dieter gateway/VPS plan assessment — 21 September 2026**

> **22 September amendment:** the public gateway and TURN service have moved to
> `gateway.getdieter.com` and `turn.getdieter.com`. The old gateway name remains
> the immutable issuer and a temporary transport alias. This assessment records
> the earlier state; see the [domain migration](gateway-domain-migration-2026-09-22.md)
> for the accepted design and remaining qualification.

The proposed architecture is sound and addresses the observed TURN failures and
deployment drift. It is a good basis for implementation, but it needs the
concrete amendments below before production activation. The most consequential
issues are preserving the actual production identity and account allowlist,
configuring coturn's relay address behind HAProxy, completing certificate reload
handling, and separating gateway acceptance from retirement of active services.

This assessment read the complete plan and its relay investigation through
Garuda's Dieter daemon, inspected the local VPS checkout and GitHub repository,
and inspected the running VPS over SSH. No production configuration, DNS,
secrets, services, application code, or original plan was changed. This report
is the only repository file added by this assessment.

The assessed document is on Garuda at
`/home/dbpprt/Development/dieter/docs/gateway-vps-deployment-plan-2026-09-21.md`.
Its companion investigation is `docs/investigations/2026-09-21-relay-fallback.md`.
The VPS administration endpoint is `root@91.132.146.140:22`; the infrastructure
checkout here is `/Users/dbpprt/Development/vps`. The Linux plan path is not a
path on the VPS.

**What the plan would deliver**

Dieter would publish its existing gateway image together with a versioned,
verified deployment bundle. The VPS repository would select immutable versions
and own production settings and the host deployment lifecycle. On the single
public IPv4 address, HAProxy would pass TLS through on TCP 443 according to SNI:
gateway traffic to Caddy on loopback 8443, and TURN traffic to coturn on 5349.
Caddy would preserve h2c to the gateway on loopback 4243. Direct UDP/TCP TURN on
3478 would remain available. A host ACME job would manage both certificates.

The plan also proposes higher bounded TURN capacity, state-preserving activation
and rollback, encrypted backups, and eventual retirement of FRP, OAuth2 Proxy,
Hermes/Kanna routes, and their local FRPC installations. Keeping
`https://board.dbpprt.com` avoids an unnecessary origin and enrollment transition.
The plan correctly treats automatic promotion of an already healthy client
relay as a separate product change.

**Verified production baseline**

These observations were collected around 16:00–16:06 UTC. Resource figures and
connection counts are snapshots, not capacity measurements.

| Area | Observed state | Consequence for the plan |
| --- | --- | --- |
| Host | Debian 13.6; one logical CPU; 967 MiB RAM; no swap; about 527 MiB available; 24 GiB disk available | Load and memory qualification are required before adopting 64/256 allocation limits. |
| Gateway | `ghcr.io/dbpprt/dieter-gateway:latest`, source `bf18ee954c968101f0c5bbf4d5d2336b73680eb2`, contract `1`, release string `main` | Capture the digest below as the initial rollback image. `main`/`latest` alone cannot identify it. |
| Gateway state | Docker named volume `dbpprt-vpc_board-gateway-data`, mounted at `/var/lib/dieter-gateway`; UID/GID `100:101`; root mode 0700, database mode 0600 | Reference this existing volume explicitly and preserve its ownership when introducing deterministic image IDs. |
| Gateway configuration | Origin `https://board.dbpprt.com`, listener `127.0.0.1:4243`, proxy mode enabled, native callbacks `dieter-mac://oauth/callback` and `dieter-android://oauth/callback` | The plan matches production here. |
| Allowed GitHub IDs | `60854672,7000188` | Production permits two accounts. The VPS checkout's single-user policy is stale; importing only `7000188` would revoke an existing account's access. |
| TURN | coturn `4.17.2-alpine`; user quota 4, total quota 16; relay ports 49160–49200; TLS and DTLS disabled | Confirms the plan's baseline. The earlier investigation, rather than this assessment, supplies the actual 486 allocation-failure evidence. |
| TURN credentials | Gateway hex-decodes its secret; decoded bytes equal coturn's text secret | Existing credentials agree. Preserve them; the proposed renderer must preserve that byte relationship. Only the comparison result was printed. |
| TURN listeners | Public IPv4, public IPv6, loopback, and Docker bridge interfaces | IPv4-only operation will be an explicit configuration change, not the current state. |
| Edge | Caddy `2.11.4-alpine`; `admin off`; HTTP/2 works; both TLS 1.2 and 1.3 accepted; HTTP/3 advertised | Explicitly configure the target TLS minimum and disable HTTP/3 if UDP 443 remains unused. |
| Firewall | IPv4 and IPv6 allow SSH 22, TCP 80/443/7000, TCP/UDP 3478, UDP 49160–49200 | Update both families and both relay-range endpoints together. Remove 7000 only at retirement. |
| Legacy services | FRPS active, an established FRP connection, backend listeners 18081/18082, and established Caddy-to-Kanna backend connections | Retirement affects live infrastructure. This does not establish whether a person was actively using it at that instant. |
| Container bounds | Gateway, coturn, and Caddy have no explicit memory, CPU, or PID limits; `json-file` logging has no configured rotation options | The planned limits and log retention close real gaps. Low observed memory usage is not load qualification. |
| DNS | `board`, `auth`, `hermes`, and `kanna` resolve to the VPS IPv4; `turn` and the apex did not resolve | A TURN record is still needed. DNS ownership/change capability was not exercised. |
| GitHub | No VPS environments; current repository secrets are the legacy SSH/FRP/OAuth set; deployment workflow remains active on matching pushes | Production environment and manual-only deployment are new work. |
| Backups | No gateway backup systemd timer or root crontab observed | An off-host recovery copy and successful restore remain unverified; other backup mechanisms were not ruled out. |

The running gateway's registry digest is:

```text
ghcr.io/dbpprt/dieter-gateway@sha256:f32e92ababc3746f5454e91ee0d25059b4395ea21f73c16f9dd265c416a14ced
```

The running coturn digest is:

```text
coturn/coturn@sha256:771a95d04cb97bbc5bfc672e5fdf455591c7d2b2a15f02bb9ceda3e27561695f
```

The running Caddy digest is:

```text
caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
```

**Required amendments**

1. **Make preservation checks exact.** Replace the now-resolved inventory
   placeholders with the volume, mount, UID/GID, digest, native callbacks, and
   both allowed account IDs above. Keep the current auth secret, TURN key bytes,
   signing keys, CA, OAuth application, and origin. A proposed fixed container
   UID must either remain `100:101` or include an explicit, bounded ownership
   transition while the gateway is stopped. Test replacement using a copy with
   the actual permissions. Do not infer production authorization policy from
   the outdated VPS AGENTS.md. Gateway storage uses SQLite WAL and rejects
   unsupported schemas; its backup and fresh-store restrictions in the plan are
   appropriate. [Storage implementation](../internal/gateway/storage.go),
   [image ownership](../Dockerfile.gateway).

2. **Specify coturn's bind and relay addresses for the HAProxy path.** The
   existing coturn configuration has no explicit `relay-ip`. Coturn can select
   the relay interface from the local address of the client connection. Moving
   the TLS client connection behind a loopback proxy changes that input. Require
   an explicit public relay binding—on this directly addressed host,
   `relay-ip=91.132.146.140`—and intentional listener addresses. Setting only an
   advertised `external-ip` is not a substitute for binding the correct relay
   socket. The TLS test must exchange data through the allocated relay, not
   stop at a successful allocation or certificate handshake. Check that returned
   relay addresses never name loopback or the Docker bridge. The plan already
   calls for public-address testing; this makes the configuration hazard
   explicit. [coturn 4.17.2 configuration reference](https://github.com/coturn/coturn/blob/4.17.2/examples/etc/turnserver.conf).

3. **Complete the certificate renewal design.** The current `admin off` prevents
   `caddy reload` from working. Choose a protected local administration endpoint
   or document bounded container replacement. For manually loaded certificate
   files, a forced reload is needed even if the Caddyfile is unchanged. Coturn
   4.17.2's source registers `SIGUSR2` for certificate reload; the plan's caution
   about assuming SIGHUP is correct. Use that implementation as the candidate
   renewal mechanism and qualify it in the pinned image. Mount the containing
   certificate directory, publish a complete validated certificate/key pair,
   and ensure coturn's unprivileged user can read it. Test that a fresh handshake
   sees the renewed certificate while an existing TURN allocation and gateway
   stream continue; include failed-renewal recovery. These are source-supported
   mechanisms, not a completed runtime renewal test.
   [Caddy reload documentation](https://caddyserver.com/docs/command-line#caddy-reload),
   [coturn certificate reload source](https://github.com/coturn/coturn/blob/4.17.2/src/apps/relay/mainrelay.c).

4. **Keep legacy services through a separately accepted retirement phase.** The
   target edge allows only `board` and `turn` SNI, but step 7 says old Caddy routes
   are removed after gateway acceptance. Switching to that two-host allowlist
   would already cut off `auth`, `hermes`, and `kanna` during step 6. Define a
   transitional HAProxy allowlist routing all current HTTPS names to Caddy, keep
   their existing OAuth gates/routes intact, and remove them only in the
   retirement phase. Identify the FRPC owner and retain its recovery path through
   that phase. This corrects a sequencing gap and makes the proposed service
   retirement reviewable independently of fixing TURN.

5. **Authenticate the bundle-to-image relationship.** The text explicitly signs
   the image and checks the bundle checksum, but should also say which verified
   signature or attestation covers the manifest containing both digests. A
   checksum supplied with a bundle does not itself authenticate its executable
   scripts. Require a signed manifest or bundle attestation binding source SHA,
   release, image digest, bundle digest, dependency digests, and contract. Also
   record gateway storage schema compatibility separately from the application
   contract when deciding whether rollback can reuse current state. Existing
   release signing provides a useful pattern to extend.

6. **Make resource limits an activation gate.** The 64 per-target / 256 total
   allocation proposal is a test candidate, as the plan already acknowledges.
   This host has one CPU and less than 1 GiB RAM. Record supported simultaneous
   client/screen/peer load, reconnect overlap, measured egress, memory headroom,
   and chosen bandwidth limits before activation. Set coturn `max-bps` and
   `bps-capacity` with their bytes-per-second units, reserve resources for the
   gateway/SSH/edge, and bound HAProxy connections and handshake inspection.
   Disable unused RFC 6062 TCP relay endpoints if only UDP relay ports are
   intended; that is separate from retaining TCP/TLS client access to TURN.
   Avoid metrics labeled with ephemeral TURN usernames, which can create
   unbounded label cardinality. No new quota numbers are justified by this
   assessment's idle snapshot. [coturn limits and metrics reference](https://github.com/coturn/coturn/blob/4.17.2/examples/etc/turnserver.conf).

7. **Handle existing IPv6 exposure explicitly.** There is already a global IPv6
   listener and matching UFW allowances, despite the inspected hostnames having
   no IPv6 DNS result. Absence of AAAA records does not prevent connections to an
   IP literal. If the first release is IPv4-only for TURN, restrict its bindings
   and remove the corresponding managed IPv6 TURN allowances. Verify direct
   address exposure before declaring the public-port check complete. Keep SSH
   and unrelated host policy intact.

**Deployment drift and release checks**

There are three distinct inputs to reconcile: GitHub VPS main, the dirty local
VPS checkout, and live `/opt/dbpprt-vpc`. Main remains at `048d703`; the local
checkout has the same 13 modified files described by the plan. Production adds
the current Dieter service and coturn on top of that older Board configuration.
None of those inputs alone is a deployable representation of current production.

The active GitHub workflow still deploys on matching pushes to main. Its checked-in
Compose does not include the live gateway/coturn services, while its deployment
script uses `--force-recreate --remove-orphans`. Running that old workflow can
remove those live services. The local unpublished workflow instead demands
Board/GHCR secrets absent from the inspected GitHub secret inventory. Avoid both
deployment paths until the reconciled manual-only workflow and release lock are
reviewed. This is a current operational hazard, not an instruction to disable or
run a workflow during assessment.

The existing Dieter image pipeline already tests the gateway dependency graph,
runs its vulnerability gate, and publishes both architectures. The observed
[successful publication](https://github.com/dbpprt/dieter/actions/runs/35589105779)
matches the live source SHA. Extending that pipeline is the right choice.
Its path filter omits real dependencies `internal/buildinfo`, `internal/envfile`,
and `internal/protocol`; the new bundle/docs paths also need coverage. The plan's
explicit release invocation, immutable production selection, anonymous package
pulls, pinned SSH host key, and host-owned deployment operation are appropriate.
Image public availability was established by the original investigation; this
assessment inspected the installed registry digest and publication metadata,
without pulling or replacing an image.

HAProxy's documented `req.ssl_sni` can route an unmodified TLS ClientHello; it
requires bounded inspection of a complete hello and explicit unknown-name
handling. SNI routing is not authentication: gateway and TURN authentication
remain essential. The installed Go dependency Pion ICE v4.4.0 sets TLS
`ServerName` from the TURN hostname, supporting the Go side of the proposed
design. That source check does not qualify the installed native WebRTC builds.
Keep the plan's real Mac/Android SNI and TURN-TLS tests as hard acceptance gates.
[HAProxy reference](https://docs.haproxy.org/3.2/configuration.html#7.3.5-req.ssl_sni).

**Recommended implementation sequence**

1. Reconcile the three configuration sources, record production identity and
   ownership, replace automatic deployment with the reviewed manual workflow,
   and verify a consistent encrypted backup in an isolated restore.
2. Deliver the image/bundle contract and a reproducible version of the existing
   topology. Qualify and address the confirmed TURN allocation shortage with
   bounded resources, retaining the current HTTPS and legacy routes.
3. Add the TURN hostname, certificate lifecycle, and transitional shared-port
   edge. Qualify Go/Mac/Android TLS relay data flow, sustained streams, renewal,
   observer disconnect, failed activation, and rollback.
4. After gateway/TURN acceptance, retire the identified legacy services and
   clients, then retire their DNS/secrets after the rollback window.

These can remain workstreams of the same project. The acceptance records should
make it possible to stop after a successful gateway/TURN improvement without
having already removed unrelated service access.

**What was and was not verified**

The gateway returned public health HTTP 200 over HTTP/2, root HTTP 404, and
untargeted OAuth-start HTTP 400. An unauthenticated data RPC returned gRPC status
16. TLS 1.2 and TLS 1.3 both negotiated HTTP/2; the observed certificate expires
7 November 2026. Existing authenticated Dieter gateway and remote-machine calls
worked, including access to the plan and a verified SSH probe through mini-home.
One later direct SSH attempt was refused; the mini-home probe succeeded. A
stable CI administration route still needs preflight qualification.

No actual coturn allocation/load experiment, native TLS-443 session, new-account
OAuth flow, off-host backup, restore, renewal, firewall change, or deployment was
performed. The earlier investigation's 486 and forced-TURN findings are attributed
to that investigation, not reported as new test results. The current health
handler returns status/build metadata and does not itself establish database,
daemon-link, or TURN readiness. The plan correctly requires authenticated
acceptance beyond process state; retain those independent checks.

My recommendation is to proceed with implementation after incorporating these
amendments. Production activation should wait for the concrete release lock,
resource qualification, native route evidence, certificate lifecycle, and
verified recovery copy. The design does not require a new gateway architecture,
new origin, reenrollment, or operator-daemon restart.
