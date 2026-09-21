# Gateway deployment bundle

A gateway release binds one multi-platform container image to its configuration,
operator scripts, pinned dependencies, application contract, and storage schema.
The GitHub release and durable OCI artifact contain the same signed manifest.
The gateway remains a machine-only service: its public root returns 404, and
projects, conversations, provider credentials and harness execution stay on daemons.

## Get a verified release

Release assembly calls the gateway publisher directly with the same commit and
version. The publisher runs Go vulnerability checks, deployment tests and real
UDP/TCP/TLS TURN payload tests before publishing. It signs the manifest and image
using GitHub OIDC and includes BuildKit provenance and an SBOM. The verifier
accepts only the exact main-branch distribution/release workflow identities.

Use the release's `gateway-release.lock.json`:

```sh
just gateway bundle fetch gateway-release.lock.json /tmp/gateway-release
just gateway bundle verify /tmp/gateway-release
```

The lock pins `ghcr.io/dbpprt/dieter-gateway-deploy@sha256:…`. Permanent
`digest-…` tags preserve both artifacts and images independently of the two-release
GitHub cleanup policy. These tags have no automated deletion policy; deployments
also archive runnable image bytes in encrypted off-host backups. Retain active,
previous and recovery releases for at least 90 days.

## Render configuration

Copy `profiles/example.settings.json` and adapt its explicit addresses, account
IDs, paths and resource budgets. All fields are required; unknown fields, invalid
hostnames, unpinned images and incompatible versions fail closed. Both native
redirects remain enabled. Existing gateway state uses the external named volume
and fixed UID/GID `100:101`; activation refuses a missing database or identity.

The protected JSON input must have mode 0600 and exactly these fields:

```json
{
  "githubClientID": "existing OAuth application ID",
  "githubClientSecret": "existing OAuth application secret",
  "authSecret": "existing hexadecimal authentication secret",
  "turnSharedSecret": "existing printable TURN secret, at least 32 bytes"
}
```

`turnSharedSecret` is canonical text. Coturn receives its UTF-8 bytes verbatim;
Dieter receives their hexadecimal encoding. Newlines, NUL and formats coturn
cannot preserve are rejected. Secrets are never shell-expanded. Compose 2.30 or
newer is required for `env_file.format: raw`; the bootstrap tool lock pins the
validated Compose version.

```sh
just gateway render --settings settings.json --secrets /protected/secrets.json \
  --image ghcr.io/dbpprt/dieter-gateway@sha256:IMAGE_DIGEST \
  --release rollout-ID --output /protected/rendered
```

`public/` holds reviewable Compose, Caddy and HAProxy configuration. `private/`
contains mode-0600 environment and TURN configuration. The host grants only the
coturn group read access to its installed configuration. Do not commit rendered
private output or put it into a build artifact.

## Topology and certificates

`tls: existing` reconciles the current Caddy certificate store and UDP/TCP TURN
before a topology change. `tls: managed` adds a distinct TURN hostname and a
webroot ACME certificate for each service. In the single-IP profile, HAProxy
passes TLS through by an explicit SNI allowlist: HTTPS to loopback Caddy 8443,
TURN TLS to coturn 5349. Missing/unknown SNI is rejected after bounded inspection.
The two-IP profile binds each service's public 443 directly.

Caddy serves TLS 1.3 and HTTP/2, disables HTTP/3, and proxies h2c only over loopback.
Coturn explicitly advertises its public IPv4 relay address and retains UDP/TCP
3478 while adding TLS/TCP 443. Client TCP transport is distinct from disabled
RFC 6062 TCP relay allocations. Private, loopback and multicast peers are denied;
public relay-to-relay payloads remain possible.

Certbot owns managed certificates. The host validates trust, hostname, expiry and
key pairing, publishes a generation atomically, then force-reloads Caddy through
its protected admin socket and signals coturn with `SIGUSR2`. It verifies newly
served certificates and restores the previous generation if activation fails.
Staging issuance uses a separate ACME store and never activates an untrusted chain.
The integration test proves active TURN allocations survive reload.

The example 64-per-user / 256-total allocation and bandwidth settings are
**candidates**, not a capacity guarantee. Qualify the actual host with concurrent
clients, screens, peer traffic and reconnect bursts before increasing production
limits. Preserve account/target concentration when testing coturn's quota bucket.

Legacy route removal is blocked by the host controller until the current managed
TLS operation has recorded complete Mac/Android API/screens, gateway-issued TURN,
certificate, isolation and 30-minute/5-minute workload evidence. The controller
starts its own 24-hour observation clock when that complete report is received.
It then requires a separate normal home/office-use and peer-sync observation
report covering that interval. Matching evidence is idempotent; changing it
restarts the interval. Retirement keeps the qualified gateway source fixed.
This gate covers route removal; stopping legacy services and owner agents and
the seven-day cleanup window still require their separately recorded procedure.

## Durable operations and recovery

The production repository supplies host policy, the release lock, settings and
any temporary legacy route fragment. Bootstrap imports and records the observed
running deployment without creating new gateway identities. Subsequent activation
uses the signed bundle and a durable systemd operation with an idempotent ID.

Operations progress through verification, staging, consistent off-host backup,
activation and external readiness. SSH disconnects do not cancel them. A reboot
restarts admitted work; an interrupted activation restores the known previous
release instead of replaying it. No operation removes volumes or global orphans.
A common host lock serializes deployment, certificate activation and backups.

Health is liveness only. Acceptance also requires authenticated gateway and
selected-daemon access, unauthenticated rejection, and real TURN payloads for
every enabled transport, bound to the operation's input hash and source commit.
Failure or a missing report within the deadline restores the previous deployment.
The deployment SSH identity has a fixed JSON entrypoint, without arbitrary shell
or filesystem operations.

Backups use SQLite's online backup API and retain signing/CA material, protected
configuration, release metadata and runnable image bytes. The off-host repository
is encrypted and append-only from the VPS. Retention and integrity/restore jobs
run on the backup owner. Keep recovery credentials outside the VPS. RPO/RTO claims
require a measured restore, and legacy retirement requires its recorded observation
and rollback windows.

`scripts/recover.py SNAPSHOT` inspects an already decrypted recovery point.
Recovery must run through independent administrative root access on an empty
Debian destination with Docker and the pinned Compose plugin installed. Preserve
the original origin/IP/DNS, prepare its firewall and restore the backup receiver
route before external acceptance. The restricted deployment key cannot restore
production data.

```sh
python3 scripts/recover.py /protected/exact-snapshot
python3 scripts/recover.py /protected/exact-snapshot --operation recovery-ID \
  --expected-ca RETAINED_CA_SHA256 --acknowledge-loss-after EXACT_CREATED_AT \
  --confirm-host EMPTY_DESTINATION_HOSTNAME --activate
```

The exact timestamp declares the possible loss of newer sessions/enrollments.
Existing application paths, installed host policy, a controller, named state
volume or running project cause rejection before installation. Cold validation
starts a cloned gateway with no network. Recovery then restores images by their
archived image IDs, configuration, certificates, UID/GID 100:101 state and units.
It validates every bind source and never fabricates an omitted legacy file.
It does not enable backup/certificate timers until their external dependencies
have been retested. Partial failure is recorded and never erased or silently
overwritten on retry. Inspect the protected recovery record before intervention.

With `--activate`, services start and local identity/liveness are checked. The
result remains `active-awaiting-external-verification`: use the existing enrolled
client to verify gateway/directory/daemon access and all selected TURN transports
before recording recovery acceptance. A fast restore inside an already provisioned
fixture is not a measured bare-host provisioning or production RTO guarantee.

## Validation

```sh
just gateway deployment-test
just gateway deployment-integration
just gateway test
just gateway vulncheck
```

The integration test builds the actual gateway image, creates named disposable
volumes and a private Docker network, and tests TLS/HTTP2, rejected unauthenticated
RPCs, all three TURN client transports, invalid credentials and certificate reload.
It uses no operator daemon, OAuth session, data directory or container. Test
fixtures are copied into Docker volumes so a remote Docker engine needs no host
filesystem sharing.

`just gateway turn-test` takes a bounded JSON request on stdin and prints only
probe results. It verifies the allocated public relay IP and bidirectional random
payloads between two allocations; credentials never appear in arguments or logs.
# Disposable Debian lifecycle qualification

`tests/debian-vm.yaml` creates a separate Lima VM with one CPU, 1 GiB memory,
no operator mounts and no automatic port forwarding. Transfer a verified signed
distribution into `/opt/dieter-distribution` and the reviewed
`tests/lifecycle_vm.py` into `/opt/lifecycle_vm.py`. The fixture refuses every
hostname except `lima-dieter-gateway-test`; run it as root inside that VM.

Its `setup`, `admit`, `inspect`, `accept` and `restore` commands exercise the real
images, systemd workers, encrypted fixture snapshots and isolated cold restore.
Use a distinct `--operation` for each admission. After a candidate reaches
`checking`, stop and restart only this disposable VM to verify automatic recovery
to the previous release. Repeat admission with the same ID to check idempotence.
`accept` uses real HTTPS and TURN payload probes and a trusted fixture controller
report; production client authentication is verified separately by the enrolled
operator readiness driver. The fixture repository is local to the VM and does
not establish that production off-host backup storage is available.
