# Lean pre-commit setup for Dieter

Research date: 2026-10-04. This is a recommendation, not an installed hook or a
formatting migration. Repository source, upstream documentation, implementation
code, release metadata, and a read-only Kotlin formatter trial inform it.

Implementation follow-up: the local phase was subsequently implemented at the
user's request, after pulling `origin/main`. The current commands and supported
platforms are documented in [the local hook guide](../fastlane/README.md#local-commit-checks).
It uses pinned standalone swift-format 604.0.0 bottles on Linux and Apple Silicon
Macs, so neither Xcode nor a Linux Swift toolchain is needed for local formatting.
The original research limits below refer to the earlier research run. Local
formatter and Git-fixture qualification now runs through `just hooks-test`.
CI changes and a full-source mechanical formatting migration remain separate.
The subsequent lean local expansion adds pinned Prettier, Ruff, Syntax Tree,
and shfmt to the same snapshot-based commands. See `fastlane/README.md` for
current coverage and setup requirements; the research below records the
original narrower recommendation.

## Recommendation

Use **gofmt, ktfmt, and Apple's swift-format**, with **Gitleaks** and a few cheap
file checks. Keep the existing **pre-commit** framework rather than introduce
Lefthook, Husky, or a second formatting framework. Make commit-time checks
read-only; run fixes explicitly before staging. Enforce the same formatting
policy in CI, independently of whether contributors installed hooks.

There is one Dieter-specific qualification: ordinary pre-commit execution
temporarily removes unstaged edits. That is unsuitable while another turn edits
the same checkout. The rollout must use an index-only checking path for that
case, described below. Changing `gofmt -w` to a read-only command alone does not
solve the framework's checkout mutation.

Start with these responsibilities:

| Area                         | Tool/policy                                                     | At commit                                   | In CI                                                   |
| ---------------------------- | --------------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------- |
| Go                           | Existing toolchain's `gofmt`                                    | Compare staged source with formatted source | Check all authored Go                                   |
| Kotlin and Gradle Kotlin DSL | Pinned `ktfmt 0.64`, `--kotlinlang-style`                       | Check staged `.kt` and `.kts`               | Check authored Kotlin in both builds                    |
| Swift                        | Existing Apple `swift-format` and configuration                 | Strict lint of staged Swift                 | Strict lint of all authored Swift                       |
| Secrets                      | Existing Gitleaks `8.30.1`                                      | Scan staged additions, redact output        | Explicit commit-range scan; separate full-history audit |
| File integrity               | Conflict markers, JSON/YAML/TOML syntax, accidental large files | Changed staged files                        | Same policy on repository files                         |
| Whitespace                   | Language formatters plus modest text checks                     | Changed staged text                         | Same exclusions and policy                              |
| Tests and deeper analysis    | Existing Fastlane affected-check planner                        | Run explicitly during development           | Existing required component checks                      |

Do not initially add Go imports tooling, SwiftLint, detekt, Spotless, RuboCop,
ESLint, or a formatter for every file extension. Each can have value, but none is
necessary to establish a consistent, fast formatting gate.

## What the repository already does

The current [.pre-commit-config.yaml](../.pre-commit-config.yaml) has a local
`gofmt -w` hook and the upstream Gitleaks hook at `v8.30.1`.
[justfile](../justfile) exposes `just hooks` and `just pre-commit`; the latter
runs `pre-commit run --all-files`.

Swift already has a deliberate policy in
[apps/mac/.swift-format](../apps/mac/.swift-format): four spaces, 120 columns,
one consecutive blank line, preserved existing line breaks, and no multiline
string reflow. Three style rules are explicitly disabled. Keep these choices.
[format-swift.sh](../apps/mac/scripts/format-swift.sh) supports write and strict
check modes, excludes generated clients and Vendor through selected roots, and
is called by the Mac CI composition in
[ci.rb](../fastlane/lib/dieter/ci.rb). It currently processes its whole root list
and cannot take staged filenames.

The inventory found **394 authored Swift files**, of which that script covers
**375**. The 19 omitted files include:

- `apps/ios/DieterIOSShare/ShareViewController.swift`.
- The two handwritten Swift files immediately under `Sources/DieterAPI`.
- Fourteen Swift files under `native/macos-capture`, including two tests.
- The Fastlane desktop helper and the landing-page social-image renderer.

Add these deliberately to the shared scope; exclude `DieterAPI/Generated`, not
the entire `DieterAPI` directory. Use the explicit configuration path for iOS
and files outside `apps/mac`, where automatic configuration discovery would
otherwise choose different defaults.

There is no Kotlin formatter configuration, root `.editorconfig`, ktlint,
detekt, or Spotless setup. There are **408 `.kt` and 12 `.kts` files** across
Android and the shared KMP build, including its included `build-logic` build.
The core catalog pins Kotlin `2.4.10`; Android shares those versions.

Go uses `go 1.26.8`. All **459 Go files outside `internal/gen/`** passed a
read-only `gofmt -l` audit. `internal/store/generated_title.go` is handwritten
code about generated titles; a filename containing `generated` is not a valid
generated-code exclusion.

[checks.rb](../fastlane/lib/dieter/checks.rb) and
[internal/pipeline/checks.go](../internal/pipeline/checks.go) already own affected
checks, package dependency selection, native builds, and integration selection.
They are the right place to integrate CI formatting. `just check-changed` can
select race tests, app builds, and native journeys; calling it on every commit
would make the hook unnecessarily expensive.

The inspected CI compositions enforce Swift formatting in the Mac component,
but do not explicitly run the existing Go formatting hook, Kotlin formatting,
or Gitleaks. iOS-only changes can select iOS without selecting Mac, so Swift
format enforcement should also be reachable for those changes. Hook/config
changes need an explicit formatting-policy selection path in the planner.

## Kotlin: prefer ktfmt for the first rollout

Both **ktfmt** and **ktlint** are credible. The difference is how much policy we
want in the formatting gate. [K1][K2][K3]

| Choice                      | Strength                                                                                       | Cost for Dieter                                                                                      | Decision                                     |
| --------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| ktfmt                       | Opinionated layout and wrapping; few settings; executable JAR                                  | JVM startup and an approximately 71 MB bundled JAR                                                   | Prefer for formatting                        |
| ktlint                      | Formatting plus style rules, EditorConfig integration, current documented native distributions | Rules can introduce naming and other findings that formatting cannot fix; Compose requires attention | Good alternative if style lint is wanted     |
| Spotless with either engine | Gradle integration, incremental checks, cache support, ratcheting                              | Additional plugin/configuration across Android, KMP, and included build logic                        | Defer unless Gradle ownership becomes useful |
| detekt                      | Kotlin bug patterns, complexity, optional type-aware analysis                                  | Rule tuning, compiler/AGP compatibility, classpaths and baselines                                    | Evaluate separately as static analysis       |

`ktfmt --kotlinlang-style` uses four-space indentation. Its upstream policy
limits configurability and supports preserving lambda-body line breaks, useful
for Compose and Gradle DSLs. Version 0.64 has limited opt-in EditorConfig
support. Start with the named style and its default width rather than invent a
large custom rule set. Align Android Studio's formatter with the chosen engine
using its ktfmt plugin; default IDE reformatting can otherwise fight the gate.

If choosing ktlint instead, select one code style explicitly and test Compose
files. Its current rule documentation recommends
`ktlint_function_naming_ignore_when_annotated_with=Composable` when appropriate;
do not respond to Compose naming findings by renaming UI functions blindly.
Some findings are intentionally not autocorrectable. The current docs also
describe native binaries that cannot dynamically load external rule JARs, so
adding Compose rules may require using the executable JAR. [K3]

Spotless is a wrapper around engines, not a replacement engine. Its own docs
warn that default source discovery does not automatically find all Android
sources; targets must include `src/*/java/**/*.kt` as well as Kotlin roots.
Our KMP source sets and included build also need explicit coverage. A direct
JAR invocation on a tracked-file inventory avoids configuring AGP or a Kotlin
Native build just to format text. [K4]

### Actual compatibility trial

GitHub release metadata reported ktfmt **v0.64**, published 2026-06-24, as the
latest release during this research. The upstream asset digest was verified:

```text
ktfmt-0.64-with-dependencies.jar
sha256:b8fbb814808d8da33f74a7bbacb6d1748cef81c0202a7f829b87139520b51273
```

The read-only command was the equivalent of:

```sh
java -Xmx1g -jar ktfmt-0.64-with-dependencies.jar \
  --kotlinlang-style --dry-run --set-exit-if-changed FILES...
```

| Measurement                         | Result                                       |
| ----------------------------------- | -------------------------------------------- |
| Tracked Kotlin inputs               | 420                                          |
| Files reported as needing changes   | 398, about 95%                               |
| Parser/formatter errors             | None reported                                |
| Formatter exit                      | 1, because formatting changes were found     |
| Elapsed time                        | 1.85 seconds on this Linux host with Java 21 |
| Original source hashes before/after | Identical for all inputs                     |

This supports adoption against the **current source syntax**. It does not prove
compatibility with every Kotlin 2.4 feature or prove the formatted app compiles.
The timing is one local observation, not a cross-platform benchmark. The wide
change count argues for a dedicated mechanical migration, with affected
component checks, rather than noisy formatting edits mixed into features.

Three additional stdin trials covered the KMP convention plugin, Android's
settings script, and the largest Android Kotlin file (the approximately 81 KB
`WorkspaceChangesScreen.kt`). Formatting succeeded, a second formatting pass
produced identical bytes, and the original files remained unchanged in all
three trials.

## Swift: extend the existing Apple formatter

Keep **swiftlang/swift-format**, which the repository already invokes as
`xcrun swift-format`. Swift 6 toolchains include it, and upstream documents both
`swift format` and `xcrun --find swift-format`. Strict lint needs `--strict`:
warnings otherwise do not necessarily produce a failing exit code. [S1]

Do not confuse it with **nicklockwood/SwiftFormat**, whose executable is
`swiftformat` and whose configuration is `.swiftformat`. That is a capable
different tool with additional idiom transformations; replacing the existing
engine would create a migration without a demonstrated benefit here. [S2]

Avoid adding SwiftLint just to enforce layout already owned by swift-format.
If later needed, select a small set of useful correctness rules and keep them
in a separate analysis gate. [S3]

For staged input, invoke strict lint on explicit materialized filenames without
`--recursive`. Retain recursive/full-inventory operation for manual checks and
CI. Every path must use the same explicit `apps/mac/.swift-format` file.

The formatter release must be reproducible, not simply whatever a moving
`macos-26` runner provides. Dieter's hosted Apple CI already selects
`/Applications/Xcode_26.5.app/Contents/Developer` in `fastlane/lib/dieter/ci.rb`.
Verify the formatter version from that toolchain and match it on development
machines, or pin a separately distributed Apple formatter on both platforms.
`swift-tools-version: 6.2` in Package.swift is a package minimum, not a formatter
pin. Upstream release metadata currently reports `604.0.0`; that is evidence of
availability, not a recommendation to change Dieter's Swift toolchain today.

Because Dieter is actively developed on both Mac and Linux, install a pinned
standalone Linux Swift toolchain/formatter as well as the Mac formatter. Source
formatting does not need SwiftUI, an Apple SDK, a simulator, or an app build.
Select the same formatter release and explicit configuration on both machines;
compare representative formatter output across platforms before rollout. A
Linux toolchain installation is a separate setup step, not something the commit
hook should download. If required tooling is missing for a changed language,
print a clear setup instruction rather than silently pass.

### Mac and Linux development

The intended matrix is:

| Check                                                   | Mac development host              | Linux development host                      |
| ------------------------------------------------------- | --------------------------------- | ------------------------------------------- |
| Go formatting, Kotlin formatting, Gitleaks, text checks | Local                             | Local                                       |
| Swift source formatting                                 | Local, matching pinned formatter  | Local, standalone matching pinned formatter |
| Portable Fastlane/repository checks                     | Local with Ruby/Bundler installed | Local with Ruby/Bundler installed           |
| macOS/iOS build and native tests                        | Xcode on a suitable Mac           | Run on a Mac or required Apple CI           |
| Android/shared JVM checks                               | Relevant local JDK/SDK            | Relevant local JDK/SDK                      |

Ruby/Bundler is a cross-platform development dependency. Its absence on the
Linux host used for this research is a local setup gap, not a reason to route
portable checks to a Mac permanently. Use the repository's `.ruby-version`,
Bundler pin, and lockfile on both machines. The common facade should separate
portable results from required Apple results instead of trying to launch
Xcode-only operations on Linux.

For optional remote Apple qualification, Dieter's authenticated machine-targeted
execution can run the checks on a selected Mac. Qualify the exact reviewed
revision or a digest-identified source snapshot in an isolated workspace; a
passing run against another machine's different checkout does not validate
unstaged Linux edits. CI can perform this qualification once the revision is
pushed. Remote native work must preserve operator app/device lifecycle rules.

## Go: gofmt is enough initially

Keep gofmt as the sole formatting authority. The codebase already passes it.
Do not add `gofumpt` or aggressive import grouping without a concrete style
problem. `goimports` is useful for editing imports, but adds another versioned
tool and import-resolution behavior; it is not required to enforce gofmt. [G1][G2]

For a read-only checker, format staged contents and compare bytes, or collect
`gofmt -l` output and fail when it is nonempty. **`gofmt -l` can exit zero while
listing unformatted files**; making it a bare hook entry would not enforce
formatting. `gofmt -d` likewise needs output interpreted as a failure.

The current `language: system` hook uses `gofmt` from PATH. It does not inherit
an exact formatter pin merely because `go.mod` specifies a Go version. Use the
repository's selected Go toolchain and verify its identity in setup/CI. Keep
`go vet`, race tests, vulnerability scans, and package analysis in their
existing explicit Fastlane gates.

## Staged files, partial commits, and concurrent turns

This is the most consequential implementation detail. pre-commit's own docs
say it temporarily stashes unstaged changes. Its **v4.6.2 source** shows it
saves an unstaged patch, runs `git checkout -- .`, runs the hooks, then restores
the patch. If autofixes conflict, it rolls back fixes before restoration.
The source also shows this happens for read-only hooks. [H1][H2]

This works for ordinary single-writer partial commits. It does not coordinate
another agent writing files while that checkout/restore sequence runs. Dieter's
Git-operation serialization does not by itself serialize harness file edits;
the current commit path invokes regular Git hooks. Do not solve this by adding
a global cap on concurrent turns.

Recommended behavior:

1. Hooks check the **staged Git objects**, including partially staged files.
   They leave the index and working tree untouched.
2. Developers run an explicit formatter, review its changes, then stage the
   desired result. Hooks print a useful fix instruction when checks fail.
3. CI checks committed bytes with the same tool versions, config, and scope.
4. For a concurrently edited checkout, the Git entrypoint uses a no-stash
   dispatcher and an index-snapshot checker. Ordinary pre-commit installation
   is only appropriate where the checkout is not concurrently being edited.

Keep the checker small: obtain NUL-delimited staged paths, read their indexed
blobs into an ignored temporary directory preserving path suffixes, check those
bytes, and remove the temporary files. Record the index tree before and after
and fail if it changes. Handle initial commits, renames, deletions, symlinks,
spaces, and unusual filenames explicitly. Gitleaks can scan the index directly.
Formatter configuration affecting staged source must be consistent with the
configuration being committed.

There is a way to retain pre-commit as the manager without its default stash
path: v4.6.2 skips that path with explicit `--files` (also with `--all-files`).
**This alone is not staged-content checking**: ordinary filename hooks then
read live working-tree bytes. Any such dispatcher must call index-aware
checker entries. This behavior was inspected in source; an adapter has not
been implemented or qualified here. [H2]

If that adapter becomes more elaborate than the checks themselves, use one
thin native Git hook calling the shared Fastlane index checker, with pre-commit
retained for explicit manual tooling. There is no reason to migrate to another
general-purpose hook framework solely to solve this issue.

Avoid auto-staging (`git add -A`, `stage_fixed`, or equivalent) in formatting
hooks: it can expand the intended commit. `git-format-staged` is worth knowing
about for explicit index formatting, but it adds machinery and working-tree
merge behavior we do not need for a read-only gate. [H3][H4]

## Small supporting checks

Start with conflict markers, JSON/YAML/TOML parsing, and accidental-large-file
checks. The pre-commit-hooks project has maintained implementations. [F1]

- Scope large-file detection to newly added files. Choose a threshold around
  2–5 MiB only after auditing legitimate assets; approve specific paths for
  necessary binaries. The tracked Gradle wrapper JARs and images must remain
  usable. Existing assets need not become retroactive failures.
- YAML checks must support the constructs the project uses. `--unsafe` means
  syntax-only parsing, not execution, but drops portability guarantees; use
  only if the stricter safe loader rejects legitimate source.
- Let each language formatter own its source whitespace. For other text,
  preserve Markdown's intentional two-space hard breaks and test fixtures.
  A global trim-all-files rule is too blunt.
- Add a small `.editorconfig` for UTF-8, final newline, and language indentation.
  Use tabs for Go and four spaces for Kotlin/Swift. Validate LF adoption and
  Windows `.bat` exceptions before applying a blanket line-ending policy.

Formatting exclusions and secret-scanning exclusions have different purposes.
Exclude Swift Vendor, generated API output, vendored browser bundles, generated
Wire/build output, Gradle wrappers, and intentional byte fixtures from rewriting.
Do not automatically exclude those same paths from secret detection.
Existing `.gitattributes` already documents whitespace exceptions for Markdown
bundles and the imported markdown engine; preserve that policy.

For authored `.mjs`/JS/JSON/YAML/Markdown, **Prettier** is a reasonable later
addition if churn is a real problem. Use a narrow scope and pinned local
dependency; never format the generated MarkdownPreview resources or apply a
Go-template-unaware formatter across Hugo templates. The repository's Node
runtime exists, but that does not make a Husky/lint-staged migration necessary.
Ruby/Python/shell formatters can also wait for demonstrated need. [F2]

## Gitleaks: keep it, distinguish local and CI scans

The repository's exact upstream v8.30.1 hook executes:

```sh
gitleaks git --pre-commit --redact --staged --verbose
```

It has `pass_filenames: false` and `language: golang`: pre-commit builds/caches
the tool, and the tool chooses staged input. [L1]

Consequently, `pre-commit run --all-files` still executes a **staged** secret
scan; it does not scan all tracked files or history. In a fresh CI checkout it
cannot substitute for explicit CI secret scanning. [L1][L2]

Keep the local scan and add a Fastlane CI operation that scans the PR/push
commit range with `gitleaks git --redact --log-opts=...`, using sufficient fetched
history and the same rules. Use the actual PR merge base and push-before SHA;
first pushes and unavailable ranges need an explicit conservative fallback.
Run an initial full-history audit and optionally a periodic one. Limit
false-positive allowances to documented fixtures or exact findings; do not
baseline unexplained findings or hide real credentials. Redact all output.

Pin external hook revisions to full commit SHAs with version comments; update
them in reviewed maintenance changes. `pre-commit autoupdate --freeze` can help.
Pin the framework itself (v4.6.2 was current during research), formatter JAR and
checksum, and Apple/Go toolchains. Populate caches at setup rather than download
tools during every commit. After setup, relevant checks should work offline;
missing required tooling should fail with an actionable message.

When updating pre-commit, migrate its configuration vocabulary as well. Current
documentation names externally managed executable hooks `language: unsupported`
and scripts `unsupported_script`, replacing the old `system` and `script` names.
The inspected v4.6.2 client translates the old local configuration names; use
`pre-commit migrate-config` and the current names in a reviewed rollout. This
does not install or version external Go/Swift/JVM tools. [H1][H2]

## Ownership, rollout, and acceptance

Keep compositions under `fastlane/lib/dieter`, typed check selection/contracts
under `internal/pipeline`, and Just as the existing facade. Add shared
`format_check`/`format` operations with source selection and explicit filenames;
reuse them from local commands and CI. Do not add native builds, emulator
launches, protobuf regeneration, or dependency installation to the commit hook.

A useful rollout sequence is:

1. Agree on ktfmt's named style and the authored-file inventory. Add tool pins,
   cache/bootstrap support, and a small EditorConfig.
2. Land a separate Kotlin mechanical migration (398 current files), extend
   Swift scope in a reviewed formatting change, and run affected component
   checks. Consider a `.git-blame-ignore-revs` entry for the migration commit.
3. Add read-only format operations and the required CI gates, including the
   independent Gitleaks scan. Run a full baseline once.
4. Wire commit checks, including the no-stash indexed path for shared-checkout
   concurrency. Document install, fix, and missing-tool behavior in the actual
   contributing/development guides; this dated report is historical research.

For the implementation, test observable boundaries in isolated Git repositories:
correct failure exits, partially staged source, an unstaged edit in another
file, an edit arriving during checking, filenames with spaces/newlines, initial
commit, rename/delete, symlink exclusions, generated/vendor exclusions, staged
formatter-config changes, missing tools, offline caches, and CI findings when
the index is clean. Verify index and unstaged bytes remain unchanged. Include a
fixture-only secret whose output stays redacted. Do not install hooks into the
operator's shared Git directory during tests.

Target **under five seconds for ordinary cached commits**, with a documented
budget for larger batches. Measure one-file commits, mixed-language commits,
cold setup, and worst-case staged batches on macOS and Linux. Avoid multiple
parallel JVM startups: batch Kotlin files into one process (and use
`require_serial` if using a pre-commit entry that would otherwise split them).
The observed whole-corpus Kotlin run suggests this is feasible, but Swift and
Gitleaks still need measurement.

Hooks remain advisory locally because Git permits bypassing them. CI should
remain the merge gate. A broad pre-push build/test gate is unnecessary initially;
the explicit affected checks already provide that workflow. [H5]

## Research limits and verification

Only this report was added to tracked source. No hook was installed and no
source formatting was changed. The Go audit and Kotlin corpus dry run were
completed. Representative Kotlin stdin formatting/idempotence checks supplement
the corpus parse trial. No Swift executable/Xcode was available on this Linux
host, so Swift behavior was assessed from repository code and upstream docs;
Apple formatter execution and latency remain unmeasured.

This Linux research host also lacks Ruby/Bundler and pre-commit, so both
`just check-changed --dry-run` and `just check-changed` stopped at
`bundle: command not found`; hook integration could not be executed here.
This says nothing about tool installation on the account's other machines.
The follow-up machine listing confirmed online Linux and Mac daemons; no remote
Mac formatter or app checks were performed as part of this research.
Those limitations affect implementation qualification, not the completed
research. Upstream web pages that rejected direct access were read through
their official GitHub source instead. Release/version observations are dated;
they are not perpetual latest-version claims.

## Sources

- **H1:** [pre-commit official documentation source: staged execution and configuration](https://github.com/pre-commit/pre-commit.com/blob/main/sections/advanced.md), [hook definitions and language behavior](https://github.com/pre-commit/pre-commit.com/blob/main/sections/new-hooks.md).
- **H2:** [pre-commit v4.6.2 staged-file implementation](https://github.com/pre-commit/pre-commit/blob/v4.6.2/pre_commit/staged_files_only.py), [runner and no-stash conditions](https://github.com/pre-commit/pre-commit/blob/v4.6.2/pre_commit/commands/run.py), [configuration language migration](https://github.com/pre-commit/pre-commit/blob/v4.6.2/pre_commit/clientlib.py), [release](https://github.com/pre-commit/pre-commit/releases/tag/v4.6.2).
- **H3:** [Lefthook overview](https://github.com/evilmartians/lefthook), [stage_fixed implementation contract](https://github.com/evilmartians/lefthook/blob/master/docs/configuration/stage_fixed.md).
- **H4:** [Prettier's documented git-format-staged guarantees and alternatives](https://prettier.io/docs/precommit).
- **H5:** [Git's official hook documentation source](https://github.com/git/git/blob/master/Documentation/githooks.adoc), [core.hooksPath](https://github.com/git/git/blob/master/Documentation/config/core.adoc).
- **K1:** [ktfmt 0.64 documentation](https://github.com/Kotlin/ktfmt/blob/v0.64/README.md), [release and assets](https://github.com/Kotlin/ktfmt/releases/tag/v0.64), [actual CLI options](https://github.com/Kotlin/ktfmt/blob/v0.64/core/src/main/java/com/facebook/ktfmt/cli/ParsedArgs.kt).
- **K2:** [ktlint official project](https://github.com/ktlint/ktlint), [CLI distributions and use](https://ktlint.github.io/ktlint/latest/install/cli/).
- **K3:** [ktlint configuration](https://ktlint.github.io/ktlint/latest/rules/configuration-ktlint/), [standard rules, including function naming and Compose](https://ktlint.github.io/ktlint/latest/rules/standard/).
- **K4:** [Spotless Gradle documentation: Kotlin engines, explicit Android targets, requirements and ratcheting](https://github.com/diffplug/spotless/blob/main/plugin-gradle/README.md).
- **K5:** [detekt Gradle integration, type-aware tasks and baselines](https://detekt.dev/docs/gettingstarted/gradle/).
- **S1:** [Apple swift-format: toolchain installation, strict lint and explicit configuration](https://github.com/swiftlang/swift-format), [release 604.0.0](https://github.com/swiftlang/swift-format/releases/tag/604.0.0).
- **S2:** [Nick Lockwood SwiftFormat: separate formatter and transformations](https://github.com/nicklockwood/SwiftFormat).
- **S3:** [SwiftLint: rule-based analysis and integration](https://github.com/realm/SwiftLint).
- **G1:** [gofmt official documentation source](https://github.com/golang/go/blob/master/src/cmd/gofmt/doc.go).
- **G2:** [goimports documentation](https://pkg.go.dev/golang.org/x/tools/cmd/goimports).
- **L1:** [Gitleaks v8.30.1 exact hook manifest](https://github.com/gitleaks/gitleaks/blob/v8.30.1/.pre-commit-hooks.yaml).
- **L2:** [Gitleaks v8.30.1 CLI, Git ranges, baselines and redaction](https://github.com/gitleaks/gitleaks/blob/v8.30.1/README.md).
- **F1:** [Maintained pre-commit file checks and their flags](https://github.com/pre-commit/pre-commit-hooks), [EditorConfig specification and integrations](https://editorconfig.org/).
- **F2:** [Prettier commit integration](https://prettier.io/docs/precommit).
