# Contributing to Dieter

Dieter is a native workspace for coding agents, built from a Go daemon and
gateway, SwiftUI macOS/iOS clients, and a Kotlin/Compose Android client.
Small fixes, documentation, accessibility improvements, and focused feature
contributions are welcome.

## Before you start

Read [AGENTS.md](AGENTS.md) for the application invariants and
[the development guide](landingpage/content/docs/development.md) for the repository
map. For a large feature, describe the problem and proposed behavior before
investing in a broad implementation. Search existing issues and pull requests.

Use [GitHub Issues](https://github.com/dbpprt/dieter/issues) when enabled for bugs
and proposals. If the repository's issue tracker is unavailable, a focused draft
pull request is a reviewable alternative. Report vulnerabilities through
[SECURITY.md](SECURITY.md), not a public bug report.

## Set up

```sh
git clone https://github.com/dbpprt/dieter.git
cd dieter
bundle install
just pipeline config_init
just doctor
npm --prefix internal/harness/runtime ci
just build
```

Pipelines need Ruby from `.ruby-version` and Bundler 2.6.9.
See [the pipeline guide](fastlane/README.md) for local profiles and release policy.

Go work uses Go 1.26.8+, Node.js 22.19+, npm, Python 3, Git, and just 1.58+.
Install only the native toolchain relevant to your change:

- [macOS development](apps/mac/README.md)
- [Android development](apps/android/README.md)
- [iOS development](apps/ios/README.md)
- [Website and documentation](landingpage/README.md)

Install local commit checks once in each Mac or Linux checkout/worktree with
`just hooks` (Python 3.11+, Go, Node 22+, and Ruby from `.ruby-version` required;
Kotlin formatting uses Java 11+).
The setup prepares pinned Go/Kotlin/Swift, Prettier, Ruff, Syntax Tree, shfmt,
and Gitleaks tools in an ignored worktree-local cache.
Use `just format` to format changed source, review and stage it, then
`just pre-commit` to check staged bytes. The hook also runs on `git commit`;
it does not stash, format, or stage working files. See the
[local hook guide](fastlane/README.md#local-commit-checks) for scope, offline
operation, partial commits, and isolated qualification.

## Verify the change

```sh
just check-changed --dry-run
just check-changed
# Include committed branch changes when appropriate:
just check-changed --base origin/main
# Execute related device/desktop gates explicitly:
just check-changed --native
git diff --check
```

The selector includes all uncommitted files by default. It executes affected fast
checks and lists related native checks separately. Run focused catalog cases for
the behavior you changed, or use `--native` for every related device/desktop gate.
Native integration is needed for related app, shared schema, or fixture changes;
a documentation correction does not require a device suite.
Shared Swift package, dependency-lock, vendor, and core/client test changes
also select iOS validation. iOS sources and tests select iOS; policies in the
shared Swift package additionally run their portable unit tests on the Mac host.
Installer changes select the release regression suite; Mac lifecycle changes
select process-ownership tests before native qualification.
The website has an explicit `just site check` for links and assets.

During implementation, rerun only a failed or newly affected check. Run the
affected package and contract checks once when the change is ready for review;
do not repeatedly run `just check` or full device catalogs. For pipeline-only
changes, contract checks plus a focused native case through each changed adapter
are sufficient local verification. Main CI performs full qualification once
before the immutable development release. See [the pipeline guide](fastlane/README.md)
for common modules, exact local target profiles, signing, and retained products.

Use `just format` for authored source, web/config files, and Markdown changes. Tests should verify
observable behavior and meaningful failure cases, rather than repeat the code.

## Protect the development environment

Do not stop, restart, replace, or install over an operator's live daemon for a
test. Use the existing disposable gateway/daemon fixtures, temporary data roots,
random loopback listeners, and mock harnesses. Mac UI smoke refuses a running
Dieter app. Android commands pin the selected emulator and retain app data.
If a native integration environment is unavailable, say so in the PR.

Keep Dieter metadata under `DIETER_HOME`; never add project-local runtime metadata.
Do not commit credentials, production transcript captures, private signing
material, or generated build output.

## Keep release compatibility coherent

Native operations, protobuf RPCs, core server implementation, Connect adapter,
CLI, help, documentation, and local/direct-TLS/relay tests belong in the same
change. Run `just proto` for schema edits. Use the one canonical release version
and the gateway's reviewed client/daemon floors; do not add old-version branches
or development-store migrations. See [release compatibility](docs/api-contract.md)
and [API documentation](api/proto/README.md).

## Write a useful pull request

Lead with the concrete problem and resulting behavior. Include the relevant
checks, platform limitations, and screenshots for visible native or website
changes. Keep unrelated cleanup out of the patch. A draft is useful when you
want feedback before the implementation is ready.

Documentation has one public source in `landingpage/content/docs`. Keep the root
README short, link to the guide, and put implementation detail in `docs/`.
Dated investigations remain historical evidence, not current setup instructions.
Screenshot changes need captions and capture provenance; see
[the screenshot guide](docs/screenshots/README.md).

By contributing, you agree that your contribution is licensed under the
repository's [MIT license](LICENSE).
