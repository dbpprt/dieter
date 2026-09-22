# Security policy

Dieter is pre-release software. Security fixes target the current source and
latest release; there is no promised maintenance window for older development
builds. Keep the daemon, gateway, CLI, and native clients on the same application
contract.

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/dbpprt/dieter/security/advisories/new)
if it is enabled for this repository. Include affected versions/components,
reproduction steps, impact, and a minimal proof of concept with disposable data.
Never include live access tokens, provider credentials, or private keys.

If private reporting is unavailable, open a minimal public issue requesting a
private security contact without exploit details. If Issues is also unavailable,
use the maintainer contact shown on the GitHub profile. Wait for a private channel
before sharing the report. No response-time SLA is currently promised.

## Trust boundaries

Harness workers run unsandboxed with the daemon user's permissions. Authenticated
clients have account-wide operator access, not granular read-only scopes. The
raw daemon data plane must remain loopback-only. Public access uses authenticated
TLS routes or the gateway relay.

The gateway does not store project code, transcripts, or provider credentials,
but relayed API payloads can pass through it. Cloud model providers may receive
prompts and code according to their configuration. Read the complete
[security model](landingpage/content/docs/security.md) before deploying.
