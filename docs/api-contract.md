# Release compatibility

Dieter ships one canonical Semantic Versioning release across the gateway,
daemon/CLI, macOS, iOS, Android, and native helpers. The protobuf package names
`dieter.v1` and `dieter.gateway.v1` are stable namespaces, not independently
versioned contracts. Dieter does not keep historical wire implementations or
negotiate v1/v2 product APIs.

The gateway publishes one authenticated compatibility policy containing its
release, `minimum_client_version`, `minimum_daemon_version`, and a digest
revision. Clients and daemons send their release on every gateway and data-plane
route. Compatibility is `installed release >= minimum release` using strict
SemVer precedence; build metadata does not affect ordering. Missing or malformed
versions are incompatible.

An additive schema or capability change does not raise a floor. A change that
would make an older client or daemon unsafe raises the corresponding floor in
the signed gateway compatibility policy. Raise the client floor only after the
Mac, iOS, and Android release is available; raise the daemon floor only after
the signed Linux and Homebrew release is available. When the final stable
release number is not known, pin a prerelease floor such as `0.4.309-dev.0`.
The eventual `0.4.309` release and every later compatible release sort above
that floor without causing future releases to raise it automatically.

Source builds can use `just release pseudo-version`, which derives a valid
SemVer such as `0.4.309-dev.439+de14862b` from the latest release line, Git
history, and source revision. Published artifacts replace that identity with
the release workflow's single numeric version. Apple build numbers and Android
version codes remain platform-specific monotonic identifiers, not compatibility
inputs.

An incompatible managed daemon persists the authenticated policy, admits one
signed automatic update attempt for the installed-release/policy tuple, verifies
the candidate checksum, Sigstore identity, and `--version >= minimum` before
activation, then stays incompatible if it still cannot meet the floor. Native
clients and the CLI present Update Required instead of entering normal product
state. The unauthenticated compatibility bootstrap and `/healthz` remain
available so old software can explain the required update.

Remote-desktop input and persisted sync projections retain their own narrowly
scoped revisions because they describe subsystem framing or stored state, not a
second Dieter product contract. Capabilities remain appropriate for genuine
platform differences such as codecs, capture permissions, clipboard formats,
and provider support.

Each daemon stores local conversations, schedule occurrences, execution state,
and credentials under `DIETER_HOME`. Shared projects, boards, labels,
placements, and portable settings replicate through the leaderless peer store;
no machine owns a project. The gateway stores account authentication, enrolled
daemon identity, routing, presence, and normalized provider quota snapshots,
never project or conversation data.

Schema changes update authoritative protobufs, generated bindings, daemon core,
CLI/help, native clients, deployment policy, and local/direct/WebRTC/relay tests
in one change. Unsupported development stores are rejected without migration;
preserve the old directory and use a fresh disposable home for development.
