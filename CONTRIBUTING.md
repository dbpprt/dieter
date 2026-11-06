# Contributing to Dieter

Thanks for helping. Bug fixes, documentation, accessibility improvements and
focused features are welcome. For a large change, open an issue or a draft pull
request describing the problem and the behaviour you propose before investing
in the implementation. Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md).

## Set up

```sh
git clone https://github.com/dbpprt/dieter.git
cd dieter
mise trust
just setup          # pinned tools (mise.toml) and the harness runtime
just hooks          # optional pre-commit hook: just lint --staged
```

Install [mise](https://mise.jdx.dev/getting-started.html) first. Platform SDKs
(Xcode, the Android SDK) are needed only for the apps you change.
[docs/building.md](docs/building.md) covers every component, running a local
daemon or gateway safely, and forking.

## Commands

| Command                                       | Does                                                        |
| --------------------------------------------- | ----------------------------------------------------------- |
| `just build`, `just test`, `just test-e2e`    | Build and test the Go daemon, CLI and gateway               |
| `just lint` (`--staged`), `just fmt`          | Check or fix formatting and lint for every language         |
| `just generate`                               | Regenerate code from `api/proto` and `config/identity.json` |
| `just check-changed [--base REF] [--dry-run]` | Run the checks your change affects                          |
| `just kotlin <tasks>`                         | Gradle in `apps/kotlin` (core, shared UI, Android)          |
| `just framework`, `just mac …`, `just ios …`  | Apple apps                                                  |
| `just e2e <android\|ios\|mac>`                | Maestro device flows against an isolated fixture            |
| `just site serve\|check`                      | Website and user docs                                       |

## Make the change

- Read [docs/invariants.md](docs/invariants.md); they are binding.
  [docs/architecture.md](docs/architecture.md) shows where code belongs.
- Put tests next to the code they cover; [docs/testing.md](docs/testing.md)
  explains the layers, the Go `testkit`, Kotlin `commonTest`, Swift packages and
  Maestro flows. Tests should check observable behaviour and meaningful failure
  cases.
- A new or changed daemon operation needs the proto, the `internal/api` handler,
  the CLI command with offline help and route tests in the same pull request;
  the checklist is in [AGENTS.md](AGENTS.md#adding-or-changing-an-operation-cli-parity).
- Client rules go into the Kotlin core, not into an app.
- User documentation lives in `site/content/docs`; contributor documentation in
  `docs/`. Update the page your change makes wrong.
- Never test against a daemon or app you are running for real work; use a
  temporary `DIETER_HOME`, a free port and the fixture gateway.

### Code style

| Language                    | Style                                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------- |
| Go                          | `gofmt`; `golangci-lint` rules in `.golangci.yml`; errors carry an `internal/platform/fault` kind |
| Kotlin                      | `ktfmt`; follow the surrounding code                                                              |
| Swift                       | `swift-format` with `apps/apple/.swift-format`                                                    |
| Shell, Markdown, YAML, JSON | `shfmt` and Prettier                                                                              |

`just fmt` applies all of them; `just lint` checks them in CI. Keep native
clients accessible and adaptive. Vendored code in `third_party/` keeps its
upstream formatting.

## Pull requests

1. Branch from `main` and keep the change focused; leave unrelated cleanup out.
2. Sign off every commit with `git commit -s` (see below).
3. Run `just check-changed` and `just lint`, plus the device flow for app
   changes when you can. Say which checks you ran and what you could not run.
4. Lead the description with the problem and the resulting behaviour. Add
   screenshots for visible changes.
5. The required check is `ci-ok`. A maintainer reviews and squash-merges.

### Developer Certificate of Origin

Contributions are accepted under the [Developer Certificate of Origin
1.1](https://developercertificate.org/): by signing off you certify that you
wrote the change or otherwise have the right to submit it under the project's
license. Add the sign-off with `git commit -s`, which appends:

```text
Signed-off-by: Your Name <you@example.com>
```

Use your real name and an email address you control. CI rejects commits without
a sign-off; fix a branch with `git rebase --signoff main`.

## Security issues

Do not open a public issue for a vulnerability. Report it privately as
described in [SECURITY.md](SECURITY.md).

## License

Dieter is [MIT-licensed](LICENSE); your contribution is licensed the same way.
The Dieter name and logo are covered by [TRADEMARKS.md](TRADEMARKS.md).
