# Gateway relay fallback investigation — 2026-09-21

Production TURN allocation exhaustion is confirmed. Diagnostic clients received
TURN **486 (Allocation Quota Reached)**, gathered no usable relay candidates,
failed to establish ICE, and successfully fell back to the gateway. Read-only
inspection of the VPS found `user-quota=4` and `total-quota=16`. These limits
are too small for the concurrent control, screen, and peer connections Dieter
creates. A separate client recovery gap can keep an already connected UI on
gateway relay after TURN capacity becomes available.

This is an investigation, not a deployed fix. No production settings, services,
firewall rules, credentials, or application code were changed. Source inspection
used Dieter revision `64902f5`; installed daemons reported v0.4.230 at home and
v0.4.232 at the office. The office Mac app reported 0.4.238. Findings about current
source behavior should not be treated as verification of every installed binary.

**Live infrastructure evidence**

The VPS at `91.132.146.140` runs both `dbpprt-vpc-dieter-gateway-1` and
`dbpprt-vpc-coturn-1`. The TURN image is `coturn/coturn:4.17.2-alpine`; its
container started on August 25. Inspection used the existing trusted SSH
connection from `mini-home`, with strict host verification and batch mode.

The running container uses `-c /etc/coturn/turnserver.conf`, mounted from
`/etc/dbpprt-vpc/turnserver.conf` on the VPS. Its inspected settings are:

| Setting | Live value | Consequence |
| --- | --- | --- |
| `user-quota` | `4` | Four simultaneous allocations per normalized TURN username |
| `total-quota` | `16` | Sixteen simultaneous allocations across the configured realm |
| `min-port` / `max-port` | `49160` / `49200` | Only 41 relay port numbers in the configured range |
| `use-auth-secret` | enabled | Gateway-issued, short-lived REST credentials |
| `realm` | `board.dbpprt.com` | Shared TURN realm |
| `listening-port` | `3478` | UDP/TCP TURN listener |
| `no-tls` / `no-dtls` | enabled | No TURN TLS/DTLS listener |
| `no-cli` | enabled | No live coturn administration interface |

The gateway currently advertises STUN on `board.dbpprt.com:3478` and two TURN
URLs: `turn:board.dbpprt.com:3478?transport=udp` and
`turn:board.dbpprt.com:3478?transport=tcp`. No `turns:` URL is advertised.

The latest `dbpprt/vps` main commit is `048d703aa5e9` from August 17. Its Compose
file contains Caddy and OAuth2 Proxy and its documentation describes the older
FRP deployment. It contains neither the current gateway nor coturn deployment.
The live configuration has drifted from that repository.

**Observed connection behavior**

The probes used ordinary authenticated status calls, plus an isolated diagnostic
CLI built with a Go source overlay. The overlay reported candidate kinds,
selected route, timing, and numeric TURN errors without printing TURN secrets.
Forced-TURN cases changed only that diagnostic client's ICE policy.

| Probe from Garuda | Result | Relevant evidence |
| --- | --- | --- |
| Normal connection to mbp-office | Gateway relay, about 10.4 seconds | Two TURN 486 responses; neither offer nor answer had relay candidates; ICE stayed checking until deadline |
| Normal connection to mini-home | WebRTC direct, about 1.3 seconds | Selected host/host pair; one TURN allocation could fail without preventing the direct path |
| Forced TURN to mini-home | WebRTC TURN, about 4.2 seconds | Relay candidates gathered; selected pair included relay; authenticated status succeeded |
| Forced TURN to mini-office | WebRTC TURN, about 3.6 seconds | Same TURN setup succeeded when allocation was accepted |
| Earlier forced TURN to mini-office | Gateway relay, about 10.8 seconds | Empty offer candidate set; demonstrates intermittent availability |

An ordinary CLI call from mbp-office to mini-office also selected gateway relay,
while the office daemon's peer status reported a recent successful TURN exchange
with Garuda. These are different connections with different allocation timing.
The evidence does not support a universal WebRTC failure.

One diagnostic call failed before RTC configuration with a gateway TCP
`no route to host` error. Intermittent gateway/SSH reachability errors also
occurred during inspection. They are separate observations, not explained by
TURN quotas alone.

**Why four allocations are insufficient**

The gateway issues usernames in the form
`<expiry>:dieter:<account ID>:<target daemon ID>` in
[`internal/gateway/service.go`](../../internal/gateway/service.go).
Coturn 4.17.2 removes the timestamp before applying its user quota; see
[`get_real_username` and `check_new_allocation_quota`](https://github.com/coturn/coturn/blob/4.17.2/src/apps/relay/userdb.c#L368).
New expiry timestamps therefore do not create separate quota buckets. All
connections for the same account and target daemon share the four-allocation
limit, including both ends of the same connection.

Both endpoints receive the same ICE configuration. With the advertised UDP
and TCP TURN URLs, each endpoint can allocate twice: two endpoints times two
transports equals four allocations for one connection. Native interface/address
gathering can add further demand. These allocations happen during candidate
gathering, before selecting a direct or relayed pair; a successful direct
connection can still occupy TURN capacity. SDP candidate-line counts should not
be interpreted as allocation counts.

Additional demand comes from active UI connections, temporary reads, separate
screen-signaling connections, screen media, and autonomous daemon peer sync.
[`internal/daemon/peer.go`](../../internal/daemon/peer.go) defaults to a sync
round every 15 seconds, opens connections to up to two peers per round, and
closes them afterward. That creates repeated allocation demand alongside
long-lived clients. Mac temporary connections may be retained for five minutes.

Close paths exist in the CLI, peer exchange, and WebRTC stream implementations,
and failed daemon setup has a bounded lifetime. This investigation did not prove
an allocation leak or require one to explain exhaustion. It also did not measure
the precise delay between every client close and server-side quota release.

Both the per-user and total quota checks produce the same 486 response. A later
VPS socket snapshot showed eight bound UDP relay sockets, below the total limit;
that snapshot was not simultaneous with a rejected allocation and cannot identify
which quota rejected each earlier request. Bounded production log reads supplied
no per-user allocation counters. The per-target limit alone is already enough
to explain contention; global exhaustion remains possible under wider load.

**Why fallback can persist**

Only authenticated loopback TLS candidates were advertised by the inspected
daemons. Those are useful to a client on the same host; they do not give another
machine a LAN/WAN direct-TLS route. Remote connections therefore depend on ICE
or gateway relay unless an additional direct route is explicitly configured.

In [`internal/cli/client_transport.go`](../../internal/cli/client_transport.go),
WebRTC gets at most 12 seconds and at most two thirds of the remaining command
deadline. That explains the roughly ten-second fallback with the default
15-second command deadline. Increasing this timeout does not fix a rejected TURN
allocation.

Current Swift, Android, and daemon peer retry policies use a per-machine cooldown
of 2, 4, 8, then at most 15 minutes after repeated failures. This protects the
gateway route from repeated expensive ICE attempts, but delays recovery.

The Mac
[`ConnectionManager`](../../apps/mac/Sources/DieterClient/ConnectionManager.swift)
can promote a cached temporary gateway connection in the background. It stores
the successful candidate for subsequent temporary leases; it does not replace
the active UI connection. The active Mac connection schedules credential renewal
only when the chosen plane has a direct-token expiry. A gateway plane has none.
Android's active connection loop similarly waits indefinitely when there is no
direct credential refresh deadline. A healthy active relay therefore has no
periodic route-upgrade trigger. Cooldown expiry by itself does not reconnect it.
Background status changes should not be confused with promotion of that active
transport.

Finally, plain TCP TURN on port 3478 is not TURN over TLS on port 443. With TLS
disabled, networks that block UDP and non-HTTPS TCP have no TURN TLS option.
This is a deployment coverage gap, not proof that port blocking caused the
observed 486 responses: those responses prove the allocation requests reached
the TURN service.

**Recommended correction and acceptance criteria**

1. Bring the actual gateway/coturn deployment and sanitized configuration into
   `dbpprt/vps` before redeploying from that repository. Preserve secret injection.
2. Size per-user and total TURN quotas for simultaneous connections, both
   endpoints, and all advertised transports, with headroom for peer sync and
   reconnect overlap. For example, eight concurrent two-ended connections with
   two TURN transports already require 32 allocations in one target bucket
   before headroom. Increase the relay port range and matching firewall allowance
   together when the desired capacity exceeds the current range. Keep explicit
   resource bounds; do not substitute an unlimited quota without capacity analysis.
3. Add a reachable TLS TURN path for restrictive networks. Caddy already owns
   public TCP 443, so a `turns:` URL alone is insufficient: listener, certificate,
   routing or separate address, and firewall configuration must all support it.
4. Add bounded route promotion for an active healthy gateway connection. Keep
   the relay until a candidate passes authentication and health checks, resume
   eligible watches from their cursors, and never replay mutations to switch routes.
5. Record sanitized TURN error codes and allocation/candidate counts so a 486
   failure is visible without a special diagnostic build. Review connection reuse
   and gathering demand if quotas still fill after appropriate provisioning.

Validate provisioning with simultaneous native clients, peer sync, and screen
sessions across home and office networks. Confirm successful TURN allocations,
absence of 486 under the supported load, prompt release after disconnect, and
correct selected-route reporting. Separately test recovery from temporary quota
exhaustion while an active relay stays healthy, and TURN TLS from a network that
blocks UDP/3478. These post-fix production checks have not been performed.

Existing isolated verification passed during this investigation:

```sh
just daemon build
go test -race ./internal/controlrtc ./internal/cli \
  -run 'TestControl|TestDaemonCLIUsesWebRTCControlAndFallback|TestPeerMachineSynchronizationRoutes' \
  -count=1
```

Those tests exercise direct WebRTC, TURN, fallback, and peer routing in disposable
fixtures. They establish that the implementation can carry authenticated traffic
on those routes; they do not model the live coturn quotas or prove native active
connection promotion. No operator daemon or app was restarted for verification.
