# Move Dieter to getdieter.com

The website is live on GitHub Pages at `https://getdieter.com`, with
`www` redirecting to the apex. The service layout is:

| Service | Public endpoint | DNS |
| --- | --- | --- |
| Gateway, native OAuth, machine directory and bounded relay | `https://gateway.getdieter.com` | A `gateway` → `91.132.146.140` |
| STUN / TURN UDP and TCP | `turn.getdieter.com:3478` | A `turn` → `91.132.146.140` (already installed) |
| TURN TLS after native qualification | `turns:turn.getdieter.com:443?transport=tcp` | Same IPv4; SNI dispatch |

Do not add TURN AAAA records while the relay has no IPv6 listener. Keep GitHub
Pages apex/www records, domain-verification TXT and unrelated mail records intact.

## Accepted transport migration

Operation `rollout-20260922-k` accepted signed gateway `v0.4.269` (`8886035e`)
on 22 September at 12:33:19 UTC. Both gateway hosts passed trusted TLS; the new
origin passed TLS 1.3/h2, intentional root 404, unauthenticated RPC rejection,
fresh native-style OAuth/PKCE and authenticated relay to all four online daemons.
All STUN and UDP/TCP TURN advertisements and the coturn realm use the new TURN
host. Bidirectional UDP/TCP payloads passed without raising production quotas.

Garuda, mbp-office, mini-home and mini-office run `v0.4.270`, preserving enrolled
IDs, peer actors, shared account, 311 peer records and three project identities
at comparison. mbp-home remains offline on `v0.4.230`; keep its old transport
route and OAuth callback until it returns and updates. New and saved public
native defaults use the new gateway and require fresh sign-in; custom gateways
are unchanged and bearer credentials stay isolated by origin.

The post-transition encrypted snapshot cold-restored offline in 43.18 seconds,
retaining matching host policy, the original issuer/CA, schema and trusted
gateway-alias/TURN certificates. Exact release, snapshot and operational evidence
is recorded in the private VPS repository's `docs/gateway-rollout-status.md`.

The broader native acceptance is still incomplete: local Mac smoke failed to
open the new-chat composer, Android frame/screen-fixture checks failed, and
iPad CI timed out changing simulator orientation. Go, Mac and Android unit
checks, deployment/container tests, signed release and macOS CI passed. Fresh
production sign-in and complete journeys in both native clients are not yet
claimed. Public TURN TLS 443, native capacity, observation and legacy retirement
remain gated separately.

## Identity is not a DNS address

The current production issuer is `https://board.dbpprt.com`. It is bound into
possession proofs, access tokens, relay/RTC assertions and the peer-account hash.
Owner signatures on replicated checkout/schedule records also bind that account.
Renaming the issuer or re-enrolling machines would not be an endpoint migration.

The implementation separates the public endpoint from this immutable namespace.
The original issuer remains a string used to verify identity; relocated daemons
do not resolve or connect to it. New enrollments receive the same issuer, so they
join the existing shared account. Every application still uses contract 1.

`GetAccount` carries a five-minute signed endpoint assertion bound to the account,
issuer and application contract. Before starting workers, an updated daemon
verifies that assertion with its already-enrolled Ed25519 gateway key, then
checks the proposed destination using its enrolled possession proof. Only after
both checks succeed does it save the new address under the central writer lock.
It retains the private key, certificate, CA, generation, daemon ID, peer actor,
account database and owner signatures. Failure leaves the previous route intact.
No bearer credentials are copied into another site's native credential storage.

## Ordered rollout

1. Publish and test issuer/endpoint separation, signed discovery, all TURN URLs
   using `turnHost`, alias routing, and coherent pre/post-transition backups.
   Keep current client defaults and production origin until the new route works.
2. Add the gateway A record in Namecheap and verify authoritative and public DNS.
   The record is now saved and verified on both authoritative nameservers,
   the public resolver and the VPS.
3. Under the host operation lock, authorize a selection with
   `gatewayHost=gateway.getdieter.com`,
   `gatewayIdentityHost=board.dbpprt.com`, and
   `gatewayAliases=[board.dbpprt.com]`. Preserve allowlist, volume, keys and secrets.
   First install the new backup controller while the old gateway remains selected,
   so the pre-transition snapshot records its actual gateway hostname and aliases.
4. Activate a signed bundle with existing Caddy TLS automation and both gateway
   hosts. Prove TLS 1.3/h2, new-host root 404, old-host transport continuity and
   unauthenticated rejection before accepting. Keep the existing TURN quotas and
   port bounds. The TURN realm and UDP/TCP advertisements move to `turnHost`.
5. The existing GitHub OAuth app now has homepage `https://getdieter.com`,
   Dieter branding and an additional exact callback
   `https://gateway.getdieter.com/auth/github/callback`. Its original callback is
   retained for transition/rollback, alongside the same client ID and secret. The retained gateway alias redirects OAuth start to the canonical
   host before creating the state cookie. Native callback schemes stay unchanged.
6. Prove fresh browser OAuth and native sign-in on the new origin, then change
   CLI, macOS, iOS, Android, website and current operational-document defaults.
   Migrate saved default addresses without copying origin-bound credentials;
   leave explicitly configured custom gateways unchanged.
7. Use verified signed daemon updates on each online enrolled machine. Verify
   endpoint relocation at startup, unchanged IDs/CA/peer account, tunnel acks,
   local/direct-TLS/relay API, peer convergence and screens. Coordinate updates
   with active work. At inventory, Garuda, mini-home, mini-office and mbp-office
   were online; mbp-home was offline and needs the retained route on return.
8. Capture an off-host post-transition snapshot and cold-restore it with matching
   route policy. Publish accepted operation/release identities and evidence in
   the private VPS repository. Observe normal fleet use before alias retirement.

## TURN TLS is a separate acceptance gate

DNS and a trusted `turn.getdieter.com` certificate already exist. UDP/TCP can move
without activating the SNI multiplexing edge. Public TURN 443 requires native
Mac/Android SNI API/screens qualification, gateway certificate coverage for every
retained gateway alias, certificate reload/renewal tests, and the planned native
capacity/observation acceptance. Do not count the one-allocation readiness probe
as a restricted-network native TURN TLS test.

## Completion and rollback

Completion means every public default and online daemon uses the new endpoint,
fresh OAuth succeeds, both native clients reach the same project/card data, all
TURN advertisements use the TURN hostname, and pre/post snapshots restore the
exact accepted route configuration. An offline enrolled machine remains a named
exception until it returns. Historical rollout records and the immutable issuer
are retained deliberately, not rewritten as if the old origin never existed.

Keep both DNS names and Caddy routes throughout rollback retention. Restore the
accepted public URL/OAuth callback pair together and retain identical issuer,
state volume and keys. Updated daemons can verify a signed move back on their
next startup; changing only a DNS redirect is not sufficient. Never delete or
rebind local stores to make a migration test pass.
