# Gateway Admin: backend and Mac implementation plan

Prepared 22 September 2026 · Proposed contract, not implemented APIs

Read with the [assessment](gateway-admin-assessment-2026-09-22.md) and
[wireframe brief](gateway-admin-design-brief-2026-09-22.md).

## 1. Establish the admin boundary

Add `DIETER_GATEWAY_ADMIN_USER_IDS`, parsed as positive numeric GitHub IDs.
It defaults to empty (admin disabled); require it to be a subset of the existing
login allowlist. Validate malformed/unknown IDs at startup. Do not promote the
first user, every allowed user, a login name, or a value supplied by the app.
Deployment schemas, renderer, example settings and documentation must carry the
new setting. Do not change a live deployment as part of implementation tests.

Extend the authenticated gateway principal with **credential kind** and verified
source daemon ID when present. Today both native session and peer proof become
`Principal{GitHubID, Login}`. Checking only that ID for admin access would grant
every daemon owned by an admin the same fleet visibility.

Recommended policy: admin RPCs require a current **human native session** whose
GitHub ID is configured as admin. Daemon proofs retain ordinary account access
and can report telemetry for themselves, but cannot read the admin fleet. This
adds one binary gateway-admin decision, not per-RPC client scopes or new daemon
data-plane permissions. Keep all existing owner checks unchanged.

Add `gateway_admin` to `GetAccount` as a server-derived UI capability; false for
a peer proof. All admin RPCs independently authorize. For streams, recheck both
session validity and admin status at least every five seconds, including while
idle, and terminate on sign-out/revocation. Admin lists must never become a way
to mint tokens for, or relay requests to, another account's daemon.

## 2. Define one typed API surface

Add an explicitly registered `GatewayAdminService` in the existing gateway
protobuf package. Keep public root 404 and use the authenticated gRPC endpoint;
there is no browser admin site or public metrics endpoint. Implement bounded
unary snapshots first. The proposed operations below are design names.

| Gateway operation | Result / purpose | Increment |
| --- | --- | --- |
| `GetAdminOverview` | Build, process epoch/uptime, inventory totals, observed tunnel/relay gauges, safe service status, telemetry availability | A |
| `ListAdminAccounts` | Allowed IDs plus observed identities; last-known login, unexpired-session count, machine/presence counts; page cursor | A |
| `ListAdminMachines` | Filter by account/status/version; IDs, owner, enrollment/revocation/generation, safe route summary and fresh presence | A |
| `GetAdminMachine` | One machine's safe metadata, certificate expiry, tunnel state, relay rates and measurement coverage | A |
| `GetAdminTopology` | Bounded nodes/edges, logical-flow references, interval and evidence labels; explicit truncated/coverage fields | A |
| `GetAdminTraffic` | Selected gateway/machine/edge series and directional counters, with layer/source and gaps | A current rate; B history |
| `WatchAdminState` | Bounded coalesced revision/invalidation notices; client refetches relevant pages | B |

Every response has `observed_at`, `gateway_epoch`, `revision` and applicable
`coverage`/freshness fields. Stable machine identity is the enrolled daemon ID,
scoped to gateway origin. Account identity is numeric GitHub ID, not login.
Return ISO timestamps or typed protobuf timestamps consistently with the
project's chosen schema convention; byte counters are `uint64`, never floats.

Use purpose-specific messages. Never serialize `AuthState`, `DaemonRecord`, RTC
configuration, session bearer, certificate private material, or raw database
rows. Certificate expiry/fingerprint are derived on the server. Default route
summary contains network kind and count, not internal addresses. Admin account
summary uses existing records/configuration; do not fetch new GitHub profiles
merely to populate the page.

For pages, default to 50 rows and cap at 200, with an opaque snapshot cursor
bound to account/filter/sort/revision. Expired snapshots require restarting the
list. Snapshot retention is bounded; telemetry timestamps are separate from
inventory revision so normal byte updates do not invalidate every page.

## 3. Preserve CLI and daemon API parity

Declare matching `GetGatewayAdminOverview`, `ListGatewayAdminAccounts`,
`ListGatewayAdminMachines`, `GetGatewayAdminMachine`,
`GetGatewayAdminTopology`, `GetGatewayAdminTraffic` and later
`WatchGatewayAdminState` operations on `DieterService`. Implement on `grpcAPI`;
`connectAPI` remains a thin adapter. They proxy to the selected daemon's enrolled
gateway, never read a gateway DB and never accept an arbitrary forwarding URL.

Proposed CLI group:

```text
dieter gateway admin overview
dieter gateway admin accounts [--page-size N --page-token TOKEN]
dieter gateway admin machines [--account ID --status STATUS]
dieter gateway admin machine DAEMON_ID
dieter gateway admin topology [--account ID]
dieter gateway admin traffic [--machine ID | --edge ID] [--window 15m]
dieter gateway admin watch [--count N]
```

Global `--machine` selects the daemon proxy, with existing verified direct TLS,
WebRTC and authenticated relay behavior. It does not select the machine filter
or expand account privileges. Support table/JSON output and finite watch counts.

**The human-session policy needs an explicit CLI credential path.** Do not reuse
the proxy daemon's peer proof as admin authorization. Implement an interactive
`dieter gateway admin login` flow using the existing native OAuth/PKCE exchange,
with the browser on the CLI host. The CLI supplies its short-lived exchange
result through the daemon API; the daemon keeps the resulting native session
only in a bounded in-memory admin connection, returns an opaque handle, and
forwards admin reads using that session. Bind the handle to the proxy enrollment,
gateway origin and authenticated human account; require that account to match
the proxy's owner. Explicit logout revokes the native session and clears the
handle. Restart/expiry requires signing in again. Never print bearer tokens or
put them in argv, transcripts, persisted execution output or normal logs.

This is an explicit delegation to a fully trusted selected daemon: its existing
full-access callers can use the activated admin connection. State that in CLI
help before login. It does not silently activate admin access on the user's
other enrolled daemons. Add typed begin/exchange/logout daemon operations and
offline help in the same authentication increment. The Mac app uses its own
existing native session directly against the gateway and needs no broker.

Update root/group/leaf help, README, CLI skill, `rpcCommand` in
`internal/cli/help_contract_test.go` and end-to-end routes. Keep
`TestGRPCAPIImplementsEveryDeclaredRPC` passing. This authentication work is a
dependency of A, not deferred until after the UI ships.

## 4. Instrument what the gateway actually observes

Use a dedicated telemetry owner with atomic counters and bounded snapshots.
Keep instrumentation outside serialized store writes and never retain payloads.

| Hook | Record | Avoid |
| --- | --- | --- |
| Hub connect/unregister, activity and lease | Connected-since, last activity, current links, reconnect/disconnect totals and sanitized reason | Claiming observed connection age is lifetime machine uptime |
| Relay admission/cleanup | Active RPCs, accepted/rejected calls, completion code, queue bytes/frames/high-water mark, overflow count | Treating streams as agent turns; changing existing concurrency caps |
| Relay successful receive/send boundaries | Payload bytes in both directions on each measured gateway leg | Counting at enqueue as successful delivery, summing retransmitted deliveries as unique logical data |
| Auth/enrollment decision points | Bounded outcome counters by fixed reason category | Raw errors, codes, tokens, user-controlled cardinality or user-enumerable unauthenticated responses |
| Gateway process/runtime | Uptime, selected runtime gauges, query health and capacity saturation | Running arbitrary host commands or copying environment/secrets into the API |

Initially count **serialized application payload bytes**, excluding gRPC framing,
compression/transport overhead, TLS, IP and TURN overhead. Count each boundary
consistently after success. A successful send means accepted by the transport,
not proof the application consumed it. Retain distinct attempted/admitted/failed
counts when necessary. Wire/NIC bytes, if added later, are a separate layer.

For a logical A → B relay transfer of 100 payload bytes, A → gateway ingress
and gateway → B egress are each 100. Gateway ingress is 100 and egress is 100;
logical transferred data is 100, not 200. Keep the two legs so a failed forward
or in-flight buffer can legitimately make their counters differ. Do not infer
traffic on the forwarding leg from the receiving counter alone.

On a machine inspector, **In** means toward that machine; **Out** means away
from it. On gateway overview, **In/Out** is relative to the gateway. For an edge,
label both endpoints explicitly (`A → B`, `B → A`). Do not combine tunnel
envelope, relay payload and TURN counters in the same total.

Separate fixed categories: `gateway_control`, `peer_sync`, `daemon_rpc`,
`screen_media`, `clipboard`, `unknown`. Relay method identity can classify
known RPCs without decoding their content. Media/clipboard counters remain
unavailable until their dedicated endpoint instrumentation exists. Count admin
poll traffic separately so the act of viewing the page is understandable.

Rates use deltas over a monotonic elapsed interval within one source epoch.
First sample, counter reset, invalid interval or missing coverage is unavailable,
not zero. Prefer gateway receive time for freshness; retain endpoint sample
time separately and detect skew. Do not call an RPC duration “network RTT” or
combine streaming watch lifetime with unary latency percentiles.

## 5. Build topology from evidence

Nodes: gateway, enrolled daemon, grouped native clients, optional TURN service.
Edges: observed tunnel, gateway relay leg, endpoint-reported direct TLS,
WebRTC-direct or WebRTC-TURN. A logical flow may reference several edges.

Minimum edge fields:

```text
edge_id, logical_flow_id?, source_node_id, destination_node_id
transport, purpose, evidence_source, measurement_layer
state, first_observed_at, last_observed_at, interval_start, interval_end
source_epoch, sequence, bytes_a_to_b?, bytes_b_to_a?
rate_a_to_b?, rate_b_to_a?, active_rpc_count?, latency_kind?, latency_ms?
coverage, omitted_count, unavailable_reason?
```

Use optional measurements so a real zero survives. Separate route capability
from edge state. Do not draw every candidate as connected or every pair of
machines as a mesh. Keep a native client group separate from enrolled machines;
adding individually named clients requires authenticated instance binding.

For relay source attribution, carry the verified daemon ID from authentication
into the relay observation. A native session contributes to its account's client
group. Never propagate an unverified `source_daemon_id` into a trusted graph.

## 6. Add endpoint and TURN reporting in B

Instrument `internal/daemon/peer.go` around selected routes and completed/failed
exchanges, plus RPC/connection counters on direct daemon and control-RTC paths.
Publish a dedicated negotiated telemetry frame over the authenticated daemon
link, separate from presence/heartbeat and quota frames. Bound queue, frequency,
frame size and dimensions; telemetry must be droppable without delaying relay,
heartbeat or agent work.

Report only aggregate connection metadata: reporter/boot epoch, sequence,
interval, peer or anonymous client, transport, byte layer, directions, coarse
purpose, state and safe failure category. Gateway derives reporter identity from
the link, verifies any named peer belongs to the same account, and rejects
cross-account/arbitrary labels, duplicate/replayed epochs and stale generations.

Existing direct access tokens identify an account/target, not necessarily the
source machine. A reporter claiming a peer is **endpoint-reported evidence**,
not independently verified peer identity. Prefer the initiating daemon's report
for outgoing peer traffic; leave native clients grouped. Cryptographically
binding both endpoints is additional protocol work if required later.

Deduplicate by reporter/epoch/sequence/flow/direction. If both endpoints report,
choose one authoritative measurement per direction and keep the other as
corroboration; never sum sender and receiver measurements. Gateway observations
take precedence for its own relay legs. Do not merge layers just because their
timestamps or byte counts look similar. Telemetry is diagnostic, not a billing
ledger or proof that peer stores have converged.

For TURN, add a protected local collector/adapter using the deployed coturn
version's supported metrics. No public exporter. Start with service allocation,
ingress/egress, errors and capacity totals. The current TURN username encodes
expiry/account/target daemon; it is not a unique logical flow and does not prove
that an issued credential created an allocation. Avoid exposing username labels.
Per-flow TURN correlation requires an opaque allocation/session identifier and
qualified collection support. Show “Unattributed TURN traffic” until it exists;
never apportion global TURN bytes among machines by guesswork. TURN bytes remain
a separate measurement layer from daemon payload bytes.

## 7. Set resource and retention limits before enabling telemetry

These are proposed starting budgets to qualify, not claims about deployed scale.

| Resource | Proposed bound / behavior |
| --- | --- |
| A telemetry history | Current counters/rates only, memory-resident; reset at gateway restart with a new epoch |
| B history | 10-second buckets for 15 minutes, 1-minute buckets for up to 24 hours; memory-resident, no promise of pre-restart history |
| Telemetry memory | 64 MiB global budget including series/indexes; stop admitting new detail before exceeding it |
| Active telemetry identities | 1,000 machine detail series and 4,000 edge series maximum; real inventory remains paginated independently |
| Endpoint reports | At most one per 10 seconds per daemon, up to 64 KiB and 128 edge records; report omitted coverage |
| Endpoint freshness | Mark reports stale after 30 seconds without receipt; retain last values with age. This is independent of the existing 60-second gateway tunnel lease. |
| Admin topology response | Up to 200 nodes, 500 edges, 1 MiB; require account/search filtering beyond cap |
| History query | Up to 20 series, 1,440 points per series and 1 MiB response; reject oversize queries or return explicit coarser resolution |
| Unary refresh | Suggested five seconds while visible, backoff on failure; stop when hidden/signed out |
| B watch | At most one active view subscription per client; bounded global admission (initially 16), one replaceable pending invalidation and bounded write deadline |
| Recent diagnostics | Optional 1,000-event memory ring with fixed reason enums; diagnostic history is not a durable audit log |

Dimension limits are independent of transport and agent limits. If telemetry
overflows, preserve gateway aggregate counters when available, drop detail,
increment dropped-report/series counters and return `partial` coverage. Do not
deny enrollment or stop agents because the admin graph is full. Slow consumers
must not hold hub locks or stall relay streams. A watch disconnect cancels only
the watch.

Before adding retained series/events, amend the gateway data policy to permit
bounded credential-free operational transport metadata. Persistent SQLite
history and durable admin-action auditing are deferred; if introduced, use the
gateway's transactional cross-process locking and explicit schema policy. Never
add historical API branches or a development-store migration path.

## 8. Implement Mac from the wireframes

Create a dedicated `GatewayAdminModel` and views under a feature directory,
with typed client methods and deterministic topology reducers. Avoid growing
`AppSession` into the metrics store. Resolve capability against the selected
gateway/native credential, independently of the selected daemon's online state.
Admin should remain usable when all enrolled machines are offline.

Key cached state by gateway origin plus authenticated user; clear on sign-out,
account/origin switch or permission loss. Recheck capability after reconnect.
Cancel visible-view tasks when navigating away. Keep graph positions stable
across samples, render bounded graph projections, and provide an equivalent
accessible table. Do not persist fleet data in project folders or the shared
peer navigation KV. Layout preferences can remain local client preferences.

## 9. Implementation slices and acceptance

| Slice | Main change sites | Required evidence |
| --- | --- | --- |
| A1 auth + contract | Gateway config/auth/service/server; gateway + daemon proto; CLI auth broker, deployment settings | Empty admin list, nonadmin, forged ID/login, expired native session, admin-owned peer proof denied; ordinary owner APIs unchanged; no secrets in responses/logs |
| A2 safe inventory + CLI | Gateway storage queries/admin service; daemon `grpcAPI` and Connect adapters; CLI/help/docs | Two-account isolation for ordinary users; authorized cross-account inventory; revoked/offline/never-seen cases; bounded stable pagination; local/direct/relay CLI routes |
| A3 gateway counters + graph | Hub/relay telemetry owner and snapshot builder | Exact bidirectional byte fixtures, forwarded vs received counts, failure/cancel/queue overflow, concurrent snapshots, epoch resets, one slow viewer isolated |
| Design handoff | Versioned example API payloads generated from A fixtures and annotated wireframes | Every visible metric tied to source/unit/freshness; A and B separated; unavailable/stale/partial cases |
| B endpoint telemetry | Daemon peer/control paths, daemon link schema and collectors | Duplicate/out-of-order reports, forged peer IDs, source restart, clock skew, no double-counting, bounded frames/cardinality, telemetry loss cannot affect agents |
| B optional infrastructure | Local TURN adapter and deployment qualification | Real isolated TURN transfer in both directions, counter unit/reset validation, unknown attribution and unreachable collector |
| Mac UI | Feature model/client methods/navigation/native views | Admin gating, origin/user switching, stable updates, no-data/permission-loss/offline states, keyboard/VoiceOver and compact layout |

Run `just check-changed --dry-run`, then `just check-changed`. Run focused Go
tests with race detection for gateway/auth/hub/relay and affected server/CLI/
daemon code. Regenerate with `just proto`; support only the contract from
`api/contract-version` and reject mismatches. Shared schema changes require
generated Swift/copied schemas and applicable Android/shared-client checks even
though the first admin UI is Mac-only.

Use disposable gateway/daemon fixtures, temporary data roots and random loopback
listeners. Never restart, replace or install over the operator daemon/app. Run
native UI integration only under the Mac lifecycle rules; report an unavailable
run rather than disrupting an existing operator app. Register long-running
checks as conversation background processes.

Backend A is ready for UI implementation when its authorization/CLI paths and
traffic fixtures pass, its data policy is documented and the wireframes have
returned. Backend B can land independently; the UI must continue showing honest
coverage while B is unavailable. Deployment and destructive administration are
separate later operational work.
