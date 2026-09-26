# One-version compatibility and update plan

Date: 2026-09-26

## Decision

Dieter will have one product release version. Gateway, daemon, CLI, macOS,
iOS, and Android builds all report that release version. The gateway publishes
two compatibility floors:

- `minimum_client_version`
- `minimum_daemon_version`

Compatibility is `release_version >= minimum_version`. It is not exact version
equality. A newer client or daemon remains compatible unless a future gateway
policy raises the relevant floor.

The application-contract counter is removed. In particular, the current change
must not merely change contract `3` back to `1`; reusing an old protocol number
would give different software the same identity. Delete `api/contract-version`,
its generator, the exact-equality checks, and the product-visible contract
constants instead.

The Changes/workspace implementation, removal of first-board publishing, new
Git operations, RPC additions, and native-client behavior remain. Only their
temporary contract bump and contract-based gating are replaced by release-based
compatibility.

`dieter.v1` and `dieter.gateway.v1` remain stable protobuf package and method
names. They are a wire namespace, not multiple supported product versions.
Renaming them would change every RPC path, make old software fail as
`Unimplemented` instead of showing Update Required, and prevent a controlled
rollout. Dieter will not create `v2` packages or parallel service
implementations.

Internal persistence and implementation revisions remain independent where they
are actually required: SQLite schema versions, sync cursor projection versions,
conversation projection versions, and harness-runtime protocol versions are not
client/gateway compatibility versions.

## Target behavior

| Participant | Version source | Gateway decision | Too old |
| --- | --- | --- | --- |
| Gateway | linked `buildinfo.ReleaseVersion` | Publishes policy | Continues serving the compatibility bootstrap and health surface; deployment owns gateway upgrades |
| Daemon | linked `buildinfo.ReleaseVersion` | Compared with `minimum_daemon_version` after daemon proof | Starts its existing signed automatic updater once, then becomes incompatible if it still cannot meet the floor |
| CLI | linked `buildinfo.ReleaseVersion` | Compared with `minimum_client_version` | Exits with a typed Update Required error and the installed/required versions |
| macOS/iOS | bundle marketing version | Compared with `minimum_client_version` | Shows a blocking Update Required surface with the appropriate update action |
| Android | `BuildConfig.VERSION_NAME` | Compared with `minimum_client_version` | Shows Update Required and hands off to the existing app updater |

The release version is normalized Semantic Versioning:

- accept an optional leading `v` at ingestion;
- store and return canonical `major.minor.patch[-prerelease][+build]`;
- use SemVer precedence, ignoring build metadata for ordering;
- treat missing, malformed, or non-release versions as incompatible on a
  production gateway;
- never fall back to lexical or integer comparison.

Development fixtures use valid explicit versions such as `0.0.0-dev.1`.
Production release artifacts use the same marketing version across components.
Android's version code and Apple's bundle build number remain platform-specific
monotonic build identifiers, not compatibility inputs.

The checked-in deployment policy pins an explicit SemVer prerelease floor for
each breaking cutover (for this cutover, `0.4.309-dev.0`). It must never use a
moving `this_release` sentinel: that would turn every later release into an
unnecessary lockstep minimum. The stable release selected by CI has higher
SemVer precedence than its prerelease floor.

## Gateway policy

Add required production configuration:

```text
DIETER_MINIMUM_CLIENT_VERSION=0.x.y
DIETER_MINIMUM_DAEMON_VERSION=0.x.y
```

Both values are parsed and canonicalized at gateway startup. Invalid or missing
production values fail startup. Disposable `DIETER_GATEWAY_DEV_INSECURE=1`
gateways may default both floors to `0.0.0-dev.0`, while tests should normally
provide exact values.

The floors are deployment policy, not automatically equal to the gateway build.
This matters because App Store/TestFlight propagation and daemon release
availability are independent of gateway deployment. A floor is raised only
after the corresponding signed release is downloadable on every supported
platform.

Expose one bounded `CompatibilityPolicy` value everywhere compatibility is
needed:

```text
gateway_release_version
minimum_client_version
minimum_daemon_version
policy_revision
```

`policy_revision` is a digest of the canonical gateway issuer and the two
floors. It changes when either floor changes and is the stable key used for
daemon update-attempt deduplication. It is not a second version number.

Add a small unauthenticated `GetCompatibility` gateway RPC. It accepts the
caller's release version and component kind and returns the policy plus one of:

- `COMPATIBLE`
- `UPDATE_REQUIRED`
- `INVALID_VERSION`

The call contains no account, daemon, route, or project data. It lets clients
show Update Required before OAuth and remains available when the client is below
the floor. Include the same public policy in `/healthz` for operations and
deployment probes.

Every authenticated gateway request carries client release metadata. The
gateway interceptor rejects a missing, malformed, or too-old client before
account operations, directory watches, token exchange, RTC bootstrap, or relay
admission. `GetCompatibility`, OAuth completion, and sign-out remain available.
Return `FailedPrecondition` with a structured `google.rpc.ErrorInfo`:

```text
reason: CLIENT_UPDATE_REQUIRED
metadata.currentVersion
metadata.minimumVersion
metadata.gatewayVersion
```

Native clients use the typed reason and do not parse human error text.

## Gateway schema and directory

Make additive protobuf changes first, then reserve the retired fields during
cleanup:

- `GatewayInformation`: keep `release_version`; replace `api_version` with the
  compatibility policy and the requesting client's compatibility result.
- `Daemon`: rename the source-level `version` field to `release_version` while
  retaining its wire number; replace `api_version` with a computed daemon
  compatibility result and required minimum.
- `DaemonLinkFrame`: keep `version` as the daemon release version; replace
  `api_version` with the policy and a handshake compatibility result.
- `BuildInformation`: retain release version, source revision, and build time;
  remove `api_version`.
- `HealthResponse`: report daemon release/build information and the cached
  policy instead of returning the application contract in `version`.

The gateway database keeps the daemon release version it already records.
Remove `api_version` from the active model. A small gateway-database migration
may leave the old column unused before a later schema rebuild; do not overload
it with release or status data. Compatibility is computed from the current
floor on every directory projection, so raising the floor immediately marks
known old daemons Update Required without rewriting every record.

An incompatible daemon is never `online`, has no relay link, and exposes no
direct/RTC route through new directory projections. Its row remains visible to
its account with last-seen time, installed release, required release, and
`UPDATE_REQUIRED`. This is how clients explain an unavailable machine instead
of presenting it as generically offline.

## Authenticated daemon handshake

The new tunnel sequence is:

1. Daemon sends ID, release version, capabilities, and routes.
2. Gateway loads the enrolled record and completes the existing Ed25519
   challenge. Version information never bypasses proof of enrollment.
3. Gateway stores the authenticated attempted release and last-seen time.
4. Gateway compares the normalized daemon release with the daemon floor.
5. If compatible, it registers the link and returns a normal hello
   acknowledgement containing the current policy.
6. If too old or invalid, it returns a hello acknowledgement containing
   `UPDATE_REQUIRED` and the policy, does not register routes or relay streams,
   then closes the stream with typed `FailedPrecondition`.

The daemon verifies the acknowledgement identity/generation as it does today.
It no longer requires exact gateway/daemon contract equality. Heartbeats carry
the daemon release version, allowing the gateway to withdraw a link if a future
policy reload raises the floor while it is connected.

Gateway policy reload should be atomic. Existing links below a newly loaded
daemon floor are closed after their next heartbeat or an immediate hub scan;
new RPC streams are not admitted after the policy change.

## Daemon automatic update: exactly one attempt

Reuse the existing signed Homebrew and managed-Linux update paths. Do not add a
second updater and never invoke package-manager elevation or accept a password.
Refactor the current manual machine operation into one internal entry point:

```text
StartDaemonUpdate(root, reason, minimum_version)
```

The manual `machine update` command calls it with reason `manual`. The gateway
compatibility handler calls it with reason `compatibility`.

Before starting, the daemon atomically stores a bounded update receipt under
`DIETER_HOME`, using the central cross-process lock. The deduplication key is:

```text
gateway issuer + policy_revision + installed release + minimum daemon release
```

The receipt records attempted time, update capability, worker admission, final
known outcome, and a bounded error. A daemon process restart reads the receipt.
The same installed release and policy can never launch a second automatic
worker. A newer installed release or a new gateway policy creates a new key and
permits one new attempt.

State transitions are:

```text
compatible
  -> update_required
  -> checking_update_capability
  -> update_started
  -> process_restart_expected

update_required
  -> incompatible_update_unavailable
  -> incompatible_update_failed
  -> incompatible_already_attempted
```

On macOS, automatic update is available only for the existing Homebrew-managed
service. On Linux, it is available only for Dieter's managed systemd user
service with the current signature-verification dependencies. An unmanaged or
distribution-managed daemon records `update_unavailable` and becomes
incompatible immediately; it never tries `sudo` or changes its installation.

Pass the required minimum to the detached worker. Before activation/restart,
execute the staged candidate's version command and require a valid release at
or above the floor. Linux continues verifying the signed release manifest and
checksums. Homebrew continues using the installed tap and fixed service runtime.
If `latest`/Homebrew has not propagated a sufficiently new release, the worker
fails safely without replacing a working daemon. The one-attempt receipt then
prevents a restart loop.

The local daemon API remains available while the machine is gateway-
incompatible, subject to client compatibility. `dieter daemon status` reports:

- installed daemon release;
- cached gateway and both minimum versions;
- compatible/updating/update-required state;
- last automatic attempt and bounded failure reason;
- the existing update log path.

Automatic update tests use disposable homes and fake package managers/release
servers. They never restart or replace the operator daemon.

## Client behavior

All clients perform `GetCompatibility` before OAuth recovery, directory
selection, or connecting to a daemon. The current release is injected in tests
rather than read from global process state.

If the client is below the floor:

- show a full Update Required state, not Offline or Connection failed;
- show installed and minimum versions;
- stop gateway directory, relay, direct-TLS, WebRTC, sync, screen, terminal,
  process, and mutation retries;
- retain only update, diagnostics/version copy, sign out, and quit/back actions;
- never fall back to another daemon, because the client itself is incompatible.

Update actions are platform-native:

- Android invokes the existing `AppUpdateManager` forced check/download flow.
- macOS opens the signed latest Dieter release/update destination until a native
  updater exists.
- iOS opens the App Store/TestFlight product page.
- CLI prints the normal installation/update command and exits nonzero.

For a compatible client, each machine row uses the gateway-computed daemon
status. An old daemon reads `Daemon update required · installed X · requires Y`.
It cannot be selected for conversations, utilities, screens, or project
creation. Other compatible machines remain usable; one incompatible daemon does
not create a global application error.

Direct and local routes cannot bypass the policy. Clients attach their release
metadata to every daemon connection. The daemon permits an unauthenticated or
pre-gate health/compatibility probe, then applies its cached minimum-client
policy in the common gRPC core before Connect and relay adapters diverge. Local,
direct TLS, WebRTC control, and gateway relay therefore have the same decision.

The daemon persists the last authenticated gateway policy atomically. During a
gateway outage, initialized clients and daemons may continue using the last
policy; they do not invent a lower floor. A fresh installation with no cached
policy requires the gateway compatibility bootstrap before remote operation.

## Removing the global contract from sync and screens

The gateway floor replaces the global application-contract check. Remove the
generated `DieterContract`, `DIETER_API_VERSION`, and `protocol.Version/Number`
usages.

For sync:

- reserve and stop sending `SyncRequest.protocol_version`;
- remove exact-version rejection from `WatchSync`;
- retain `SyncCursor.projection_version`, because it invalidates incompatible
  cached projections and is not a product compatibility lane;
- keep protobuf evolution additive and raise the gateway client/daemon floors
  before relying on a newly required field or meaning.

For native screen input:

- use stable channel labels (`dieter-pointer`, `dieter-input-state`, and
  `dieter-session`) instead of labels derived from the global contract;
- reserve and stop using the global protocol fields in input, feedback,
  request, capability, and binding messages;
- bind the session to its existing nonce, offer digest, daemon identity,
  control generation, display, and input epoch; the removed global integer is
  not a security boundary;
- negotiate optional screen features with explicit capabilities and reject a
  required missing capability;
- make schema changes additive, with gateway floors raised before a breaking
  semantic becomes required.

The capture helper is shipped and activated as a pair with the daemon. Replace
its generated contract integer with build identity: release version and source
revision. The daemon requires the installed helper to match its own staged
build identity before using capture/input. Existing service activation and
rollback continue to keep the pair atomic.

Capability and transport names may retain a stable descriptive token; do not
create `*_v2` alternatives. A feature is either present in the current release
or absent. Persisted schema/projection identifiers and third-party protocol
versions are outside this rule.

## Release and deployment workflow

The release workflow becomes the source of the one Dieter release number:

- Go gateway/daemon/CLI linker identity;
- macOS marketing version;
- iOS marketing version;
- Android version name;
- capture-helper build identity;
- signed manifests and deployment metadata.

Add an assembly check that opens every produced artifact and proves that the
canonical release version matches. Keep Apple build numbers and Android version
codes separate.

Gateway deployment inputs include both compatibility floors. Deployment tests
fail if either floor is invalid or names a release not present in the signed
release metadata. A deployment may keep an older floor intentionally. Raising
a floor is a distinct reviewed deployment action and is logged at startup.

Do not automatically raise client minimums on every gateway deploy. In
particular, wait until the same client release is available through Android,
macOS, and iOS distribution. Do not automatically raise daemon minimums until
the signed Linux and Homebrew releases are available.

## Safe migration from the current contract

An old daemon cannot implement the new one-attempt updater after the gateway has
already rejected it. Use one explicit bridge release, then remove the bridge
code. This is a rollout sequence, not permanent multi-contract support.

### Release A: bridge on the current contract

1. Add the policy messages, release metadata, typed errors, cached policy, and
   one-attempt update machinery additively.
2. Keep emitting the current contract value only for the bridge release so the
   installed fleet can connect.
3. New software prefers the signed release policy when present; it uses the
   old exact contract check only when talking to the pre-cutover gateway.
4. Publish all client and daemon artifacts with one canonical release number.
5. Update every managed daemon to Release A through the existing machine-update
   operation. Update unmanaged installations manually.
6. Verify gateway inventory shows every daemon at Release A or explicitly
   accepted as requiring manual recovery.

### Release B: cut over to release floors

1. Deploy the gateway with minimum client and daemon floors set to Release A.
2. Stop sending/reading application-contract values. Old pre-bridge clients see
   the missing legacy value through their existing checks and show Update
   Required rather than attempting work.
3. Release A daemons understand the new policy and remain connected because they
   meet the floor.
4. Remove the contract source, generated constants, exact checks, and bridge
   fallback from main. Reserve retired protobuf fields.
5. Verify local, direct TLS, WebRTC, and relay operation using different but
   compatible release versions above the floors.

### Future floor raise

1. Publish signed clients and daemons first.
2. Confirm update feeds and stores serve those versions.
3. Raise `minimum_daemon_version`. Old bridge-or-newer managed daemons attempt
   one automatic update; failures become visible incompatible machines.
4. Raise `minimum_client_version` only after all client distribution channels
   are ready. Old clients immediately show Update Required.
5. Observe compatibility counts and update failures before relying on new
   semantics.

Rollback lowers a gateway floor to the last known compatible release; it never
reintroduces an old contract implementation. A daemon update activation failure
continues using the existing service-runtime rollback.

## Implementation slices

### 1. Version and policy core

- Add one Go package for strict normalization/comparison and policy evaluation.
- Add gateway configuration, public compatibility RPC, typed status details,
  health output, and policy revision.
- Add table-driven SemVer, config, and policy tests.

### 2. Daemon handshake and directory

- Update gateway protobufs, generated Go/Swift copies, and Android generation.
- Store authenticated attempted daemon releases and compute directory status.
- Admit only compatible links and withdraw routes for incompatible machines.
- Cover authentication ordering, link admission, presence watch, and dynamic
  floor changes.

### 3. Automatic daemon update

- Refactor manual update admission into the shared internal entry point.
- Add the locked, atomic, bounded attempt receipt.
- Pass/verify the minimum version in macOS and Linux workers.
- Expose status and logs without restarting the operator daemon in tests.

### 4. Common daemon client gate

- Carry client release metadata through CLI and native transports.
- Cache the authenticated policy centrally under `DIETER_HOME`.
- Enforce the same rule in the core server for loopback, direct TLS, WebRTC,
  and relay.
- Preserve offline use with the last authenticated policy.

### 5. Native clients and CLI

- Implement preflight and blocking Update Required state in macOS, iOS, and
  Android.
- Implement per-machine daemon incompatibility without disabling healthy
  machines.
- Wire platform update actions and CLI errors/help.
- Remove all exact `apiVersion == contract` selection logic.

### 6. Sync, screen, helper, and contract cleanup

- Remove application-contract generation and runtime checks.
- Stabilize screen channel names and use feature capabilities.
- Replace helper contract identity with paired build identity.
- Reserve retired protobuf fields and update trust fixtures.
- Update `AGENTS.md`, README, API docs, CLI skill, native docs, and issue
  templates to use release-floor terminology.

### 7. Release and deployment controls

- Stamp one release into every artifact.
- Verify artifact identity during release assembly.
- Add gateway minimum-version deployment inputs and validation.
- Add rollout inventory/status output and deployment integration coverage.

## Required end-to-end evidence

The change is complete only with these scenarios:

1. Client below floor gets Update Required before login and cannot list, relay,
   connect directly, start WebRTC, or mutate data.
2. Client exactly at and newer than the floor works against a compatible daemon
   over local, direct TLS, WebRTC direct/TURN, and gateway relay.
3. One old daemon and one current daemon appear together; the old machine is
   visibly Update Required while the current machine remains fully usable.
4. A managed old macOS daemon receives a raised floor, admits exactly one fake
   Homebrew worker, validates the candidate, restarts in the fixture, and
   reconnects compatible.
5. The equivalent managed Linux fixture verifies signatures/checksums,
   candidate minimum, activation, and reconnect.
6. Failed, unavailable, and same-version updates stay incompatible and do not
   launch again across daemon restarts.
7. A new policy revision permits one new attempt; an unchanged policy does not.
8. Gateway policy raise withdraws an already connected below-floor daemon and
   removes its routes.
9. Gateway outage uses the cached floor without downgrading compatibility.
10. Sync resume and native screen control work across different release versions
    that are both above the floors.
11. Mac, iOS, and Android native journeys verify the global client Update
    Required state, per-machine daemon state, and update action.
12. Release assembly proves identical canonical release versions in every
    gateway, daemon, CLI, helper, and native artifact.
13. A repository check proves there are no active application-contract files,
    generated constants, `api_version` gates, dynamic global-version screen
    labels, or alternate v2 service packages.

Run affected checks first with `just check-changed --dry-run` and
`just check-changed`, then the full Go race/vet suites, gateway deployment
integration, Mac tests, Android tests/instrumentation, iOS tests, generated
schema verification, and isolated route E2E. Native UI runs must use the
approved visible Mac/emulator lifecycle and must report unavailable evidence
rather than substituting a headless claim.

## Acceptance criteria

- There is no `api/contract-version` and no product-visible application contract
  integer.
- There is one canonical Dieter release version across shipped components.
- Gateway policy has exactly one client floor and one daemon floor.
- Compatible versions form a range (`>= floor`), not an exact pair.
- Too-old clients always show Update Required and cannot operate.
- Too-old managed daemons attempt one safe signed update per policy/install
  tuple; no retry or restart loop is possible.
- Too-old or unupdatable daemons remain visible as incompatible and expose no
  remote routes.
- One incompatible machine does not block healthy machines.
- All routes enforce the same decision and offline operation never lowers the
  last authenticated floor.
- No old contract implementation, v2 service tree, store conversion path, or
  silent fallback remains in the final source.
