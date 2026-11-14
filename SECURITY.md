# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub:
**[Report a vulnerability](https://github.com/dbpprt/dieter/security/advisories/new)**
(the repository's Security tab → _Report a vulnerability_). Do not open a public
issue, discussion or pull request for a security problem.

Please include:

- the affected component (daemon/CLI, gateway, macOS, iOS or Android app,
  installer, release artifacts) and release version;
- the route involved, if any (local, direct TLS, WebRTC, gateway relay);
- steps to reproduce and the impact you observed;
- a minimal proof of concept that uses disposable data.

Never include live access tokens, provider credentials, private keys or real
transcripts. The maintainer answers in the private advisory, keeps you informed
while investigating, and credits you in the published advisory unless you
prefer otherwise. No response-time guarantee is promised.

## Supported versions

Security fixes go into the next release and are published on the latest
**stable** release line. Older releases and dev prereleases are not patched;
update to the latest stable release. Gateway, daemon/CLI and apps share one
version, and the gateway's minimum versions make outdated software update.

## Scope

In scope: this repository's code and its official release artifacts
(binaries, the installer, app builds, the gateway image and deployment bundle).
The [threat model](docs/threat-model.md) describes what Dieter does and does
not defend against. In particular, these are **by design** and not
vulnerabilities on their own:

- agents run unsandboxed with the daemon user's permissions and can do anything
  that user can, including in response to prompt injection;
- a trusted device of an account has full operator access to every machine of
  that account (there are no read-only scopes), and a person who types a
  device's pairing code on a trusted device, or who holds the roster recovery
  key, adds a device;
- the gateway sees metadata (devices, presence, routes, tunnel timing and sizes,
  provider quota snapshots) and can deny service or withhold roster entries;
- model providers receive the prompts and code their harness sends.

A way to cross one of those boundaries (another account's machines, a daemon
without its key, a device that is not in the account's device roster, relayed
content or a pairing the gateway can read or forge, the loopback API without
its token, vault content without a member key, a release signer other than the
one below) is in scope.

Out of scope: third-party services (GitHub, model providers, Apple, Google),
self-hosted gateways' own infrastructure, and findings that need an already
compromised device or OS account.

## Release signing contract

Every release publishes `SHA256SUMS` signed with Sigstore cosign keyless
signing. The only valid signer identity is:

```text
certificate identity: https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main
OIDC issuer:          https://token.actions.githubusercontent.com
```

The Linux installer and installed Linux updaters verify exactly this identity,
macOS binaries are Developer ID signed and notarized, and the Android updater
checks the APK digest published with the release. Treat any artifact that does
not verify against this identity as untrusted, and report it. See
[docs/releasing.md](docs/releasing.md#signing-identity) for verification
commands.
