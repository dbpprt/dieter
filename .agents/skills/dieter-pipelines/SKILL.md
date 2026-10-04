---
name: dieter-pipelines
description: Develop or diagnose Dieter's Fastlane builds, test selection, CI qualification, signing, and immutable releases. Use for pipeline changes and contributor setup; use native app skills for live UI or device operation.
---

# Dieter pipelines

Read [the pipeline guide](../../../fastlane/README.md) and relevant platform
instructions before changing builds, device lifecycle, or release compositions.
Use `just pipeline`; local and CI commands execute the same pinned Fastlane.

Local commit checks use `just hooks` once per checkout/worktree, `just format`
for explicit working-source fixes, and `just pre-commit` for read-only staged
checks. The no-stash dispatcher preserves concurrent working edits; do not run
`pre-commit install` over it or add automatic staging. Tool pins/caches and the
isolated `just hooks-test` gate are documented in the pipeline guide. These
local commands require Python 3.11+; setup also needs Go, Node 22+, and Ruby
from `.ruby-version`. The lean formatters cover source, web/config files and
Markdown; they do not change CI qualification.

Inspect `just check-changed --dry-run` before verification. It includes dirty
files; add `--base REF` for the branch. Run affected contracts/packages once at
the integration boundary. During implementation, rerun only a failed or newly
affected check. Generic orchestration edits do not justify every native build.
Device/desktop checks are listed separately and require `--native` or explicit
catalog cases. Use registered processes and collect their results before ending.

Keep assertions in native tests and shared-core/Go tests. The catalog standardizes
selection, requirements and results. Do not create another journey language or
host test loop. Device tests qualify native surfaces; shared rules belong in the
core. Missing/skipped/duplicate/unavailable assertions and cleanup failures fail.

Put reusable process, lease, evidence and product contracts in
`fastlane/lib/dieter/pipeline`. `NativeAction` delegates XCTest and archive/export
to Fastlane inside owned subprocesses; keep launch environments and signing
credentials private. Stream sanitized output and show measured phase/case times.
Upload bounded diagnostics, never caches, archives or duplicate producer bytes.
Diagnostic upload outages are distinct from mandatory checkpoint retention.
For latency work, compare compilation, per-case execution and cache transfer
separately. Hosted Apple checks share the Mac SwiftPM test/build graph and cache
unsigned compiler state in Actions; producers keep independent release graphs.
Do not claim a ten-minute gate from a cold build or relabel a full catalog smoke.

Named profiles in ignored `fastlane/local.json` select exact targets. CI ignores
that file and uses tracked defaults on GitHub-hosted workers. Android, Mac desktop,
and physical-device journeys use explicit local profiles.
Never choose an arbitrary phone, replace an operator app, delete leases, clean
build caches, or restart the live daemon. Use the Mac/Android skills when operating
their devices. `ios_qualify` builds once and verifies products before each explicit
simulator layout; physical tests use `ios e2e` with exact profiles and existing
development signing/TLS fixtures.

The reusable qualification workflow owns affected PR/main checks and full
scheduled/manual checks. Routine iOS uses policies and both-layout connection
journeys. Full catalogs remain available through scheduled/manual qualification.
Main qualifies once, then CI
calls Release. Manual releases qualify first. Keep one canonical SemVer, exact
producer checkpoints, byte-preserving reruns, retained-IPA TestFlight delivery,
and protected stable promotion. Local configuration cannot change release policy.
Do not publish releases, rotate signing accounts, or activate production merely
to test pipeline changes; verify those contracts with disposable fixtures.
