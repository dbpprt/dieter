# Environment variables

Contributor reference for every environment variable the Go binaries read, with
the code that consumes it. The user-facing subset is on the website
([environment reference](https://getdieter.com/docs/environment/),
[source](../../site/content/docs/reference/environment.md)); keep both in step
when you add or change a variable.

`internal/platform/config` is the only package that reads the process
environment by name (`LoadDaemon`, `LoadClient`, `LoadServiceHandoff`,
`DefaultHome`, `LoadEnvFile`); the gateway parses an injected snapshot with
`gateway.ConfigFromEnv`. `forbidigo` in `.golangci.yml` rejects `os.Getenv`
elsewhere. Child processes still inherit the environment where documented.

## Load order

- **Daemon:** flags → `DIETER_HOME` or `--store` → service handoff →
  `--env-file PATH` or `$DIETER_HOME/.env` (must be mode 0600; never overrides a
  variable that is already set) → `config.LoadDaemon`.
- **Gateway:** `DIETER_GATEWAY_HOME` or `--store` → `--env-file PATH` or
  `<home>/.env` (mode 0600) → `gateway.ConfigFromEnv`.

## dieter (CLI and daemon)

| Variable                                                                                  | Consumer                                                         | Meaning                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DIETER_HOME`                                                                             | `config.DefaultHome` (CLI and daemon; `--store` overrides)       | Central data directory, default `~/.dieter`. Also set for harness workers so an agent's `dieter` calls reach this daemon.                                                                   |
| `DIETER_GATEWAY`                                                                          | `config.LoadClient` → CLI                                        | Gateway origin to require when `--gateway` is not given.                                                                                                                                    |
| `DIETER_TURN_TOKEN`                                                                       | `config.LoadClient` → CLI; set by the daemon for harness workers | Identifies the agent turn behind a CLI call made inside that turn (vault access).                                                                                                           |
| `DIETER_REMOTE_DESKTOP_HELPER`                                                            | daemon, `dieter doctor`                                          | Path of the screen-capture helper (`dieter-capture`).                                                                                                                                       |
| `SHELL`                                                                                   | daemon (default terminal shell), `dieter doctor`                 | Standard.                                                                                                                                                                                   |
| `DIETER_HARNESS_CONFIG`                                                                   | daemon (`harness.CatalogOptions`)                                | Harness registry YAML when `--harness-config` is not given; otherwise `$DIETER_HOME/harnesses.yaml`, then the embedded `internal/harness/catalog/harnesses.yaml`. Honoured from `.env` too. |
| `DIETER_SERVICE_MANAGER`                                                                  | daemon; terminal systemd scope                                   | `homebrew`, `systemd-user` or `managed`. Written into the unit by `dieter daemon service install`.                                                                                          |
| `NOTIFY_SOCKET`                                                                           | daemon                                                           | systemd readiness socket.                                                                                                                                                                   |
| `DIETER_ENABLE_MOCK_HARNESS`                                                              | daemon → `harness.CatalogOptions.Mock`                           | `1` registers the deterministic mock harness. Fixtures only; tests inject `testkit.MockCatalog()` instead.                                                                                  |
| `DIETER_MIN_FREE_BYTES`                                                                   | daemon → engine                                                  | Free disk space a turn requires (default 2 GiB).                                                                                                                                            |
| `DIETER_HARNESS_RUNTIME_DIR`                                                              | daemon → `harness.Environment.RuntimeDir`                        | Use a staged harness runtime instead of the embedded one (development).                                                                                                                     |
| `DIETER_HARNESS_ENV`                                                                      | daemon → `harness.Environment.PassThrough`; `runner.mjs`         | Comma-separated extra variable names forwarded to harness workers, which otherwise get an allowlisted environment.                                                                          |
| `CODEX_HOME`, `CLAUDE_CONFIG_DIR`                                                         | daemon → provider quotas; harness discovery                      | Active provider profiles.                                                                                                                                                                   |
| `DIETER_CODEX_ACCOUNT_HOMES`, `DIETER_CLAUDE_ACCOUNT_HOMES`                               | daemon → provider quotas                                         | `:`-separated lists of additional provider profiles (up to eight) for quota correlation.                                                                                                    |
| `PI_AGENT_DIR`, `OMP_PROFILE`, `DSH_HOME`                                                 | harness workers and discovery                                    | Provider configuration selection; DSH defaults to `~/.dsh`.                                                                                                                                 |
| `DIETER_REMOTE_DESKTOP_SOURCE`                                                            | daemon → remote desktop source                                   | `screen` (default) or `synthetic` (transport diagnostics).                                                                                                                                  |
| `DIETER_REMOTE_DESKTOP_DISPLAY`                                                           | daemon → remote desktop source                                   | Display selector.                                                                                                                                                                           |
| `DIETER_SCREEN_FEC`                                                                       | daemon → `remotedesktop.Tuning`                                  | `0` disables forward error correction (default on).                                                                                                                                         |
| `DIETER_SCREEN_FAST_BITRATE`                                                              | daemon → `remotedesktop.Tuning`                                  | `0` disables fast bitrate reduction (default on).                                                                                                                                           |
| `DIETER_SCREEN_LTR`                                                                       | daemon → `remotedesktop.Tuning`                                  | `0` disables acknowledged reference recovery (default on).                                                                                                                                  |
| `DIETER_SCREEN_CONTENT_ADAPTATION`                                                        | daemon → `remotedesktop.Tuning`                                  | `1` enables content-class adaptation (experimental).                                                                                                                                        |
| `DIETER_SCREEN_OVERLAP`                                                                   | daemon → remote desktop source                                   | `1` lets native encode overlap the previous send (experimental).                                                                                                                            |
| `DIETER_SCREEN_VIRTUAL_DISPLAY`                                                           | daemon → `remotedesktop.Tuning`                                  | `1` enables experimental macOS virtual displays.                                                                                                                                            |
| `DIETER_SCREEN_VIRTUAL_DISABLE`                                                           | daemon → `remotedesktop.Tuning`                                  | `1` additionally allows disabling the physical main display (hardware-qualified opt-in).                                                                                                    |
| `DIETER_SERVICE_LOCK_FD`, `DIETER_SERVICE_ACTIVATION`                                     | `config.LoadServiceHandoff` → `serviceruntime.Runtime`           | Internal handoff to a re-executed service process. Not user-facing.                                                                                                                         |
| `XDG_CONFIG_HOME`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `PATH`                  | CLI Linux service install and status                             | Standard; systemd user unit location and `systemctl --user` session.                                                                                                                        |
| `DIETER_CARD_ID`                                                                          | set by the daemon for harness workers                            | Card of the running turn.                                                                                                                                                                   |
| `DIETER_QUOTA_ACTION`, `DIETER_QUOTA_IDEMPOTENCY_KEY`, `DIETER_QUOTA_EXPECTED_ACCOUNT_ID` | set by the daemon for its quota probes                           | Internal probe protocol.                                                                                                                                                                    |

## dieter-gateway

| Variable                                                         | Meaning                                                                                           |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `DIETER_GATEWAY_HOME`                                            | State directory (default `~/.dieter-gateway`); `--store` overrides.                               |
| `DIETER_GATEWAY_ADDR`                                            | Listen address (default `127.0.0.1:4243`).                                                        |
| `DIETER_PUBLIC_URL`                                              | Public origin (required; HTTPS outside development mode).                                         |
| `DIETER_GATEWAY_ISSUER`                                          | Durable identity and trust origin when it differs from the public URL (after moving an endpoint). |
| `DIETER_GITHUB_CLIENT_ID`, `DIETER_GITHUB_CLIENT_SECRET`         | GitHub OAuth app.                                                                                 |
| `DIETER_GITHUB_ALLOWED_USER_IDS`                                 | Comma-separated immutable numeric GitHub user IDs allowed to sign in.                             |
| `DIETER_GITHUB_BASE_URL`, `DIETER_GITHUB_API_URL`                | GitHub endpoints (defaults `https://github.com`, `https://api.github.com`).                       |
| `DIETER_AUTH_SECRET`                                             | Hex session-signing secret.                                                                       |
| `DIETER_NATIVE_SESSION_TTL`                                      | Native client session lifetime.                                                                   |
| `DIETER_NATIVE_REDIRECT_URIS`                                    | Comma-separated allowed native OAuth redirect URIs.                                               |
| `DIETER_GATEWAY_TLS_CERT`, `DIETER_GATEWAY_TLS_KEY`              | TLS certificate and key when the gateway terminates TLS.                                          |
| `DIETER_GATEWAY_PROXY_MODE`                                      | `1` behind a same-host TLS-terminating proxy (loopback listener, HTTPS public URL).               |
| `DIETER_GATEWAY_DEV_INSECURE`                                    | `1` for a disposable development gateway: plain HTTP allowed, development floors.                 |
| `DIETER_MINIMUM_CLIENT_VERSION`, `DIETER_MINIMUM_DAEMON_VERSION` | Published compatibility floors (required outside development mode).                               |
| `DIETER_RTC_STUN_URLS`, `DIETER_RTC_TURN_URLS`                   | Comma-separated ICE server URLs for Screens and WebRTC API routes.                                |
| `DIETER_RTC_TURN_SECRET`                                         | Hex-encoded coturn REST secret, at least 32 bytes.                                                |
| `DIETER_RTC_TTL`                                                 | Signed ICE configuration lifetime (default five minutes).                                         |

## Fixtures and tests

Not product configuration.

| Variable                                                                                                                             | Consumer                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `DIETER_ISOLATED_*` (`ADDR`, `TOKEN`, `PAIRING_CODE`, `DAEMON`, `INCOMPATIBLE_DAEMON`, `SECOND_DAEMON`, `PROJECT`, `BOARD`)          | Printed by `tools/fixtures/gateway` before `READY`; read by the Kotlin, Mac and Maestro tests. A stable contract. |
| `DIETER_TEST_TURN_CONFIG`                                                                                                            | `tools/fixtures/fixtureturn`                                                                                      |
| `DIETER_PERFORMANCE_SWEEP`, `DIETER_PERFORMANCE_LONG_TURN`, `DIETER_TEST_CONTROL_WEBRTC`, `DIETER_FIXTURE_WRITER_PATH`               | `tools/fixtures/gateway`                                                                                          |
| `DIETER_TEST_CAPTURE_*`                                                                                                              | Native capture helpers and remote desktop tests                                                                   |
| `DIETER_TEST_*`, `DIETER_UPDATE_*_FIXTURE`, `DIETER_RUNTIME_TEST_ROOT`, `DIETER_SIGNED_*`, `DIETER_DSH_E2E_API_KEY`, `DIETER_PEER_*` | Opt-in Go tests and golden-vector regeneration                                                                    |

## Build and release

Read by the app builds and the release pipeline, not by the Go binaries:
`DIETER_RELEASE_VERSION` and `DIETER_RELEASE_VERSION_CODE` (app versions),
`DIETER_ANDROID_KEYSTORE_PATH`, `DIETER_ANDROID_KEYSTORE_PASSWORD`,
`DIETER_ANDROID_KEY_ALIAS`, `DIETER_ANDROID_KEY_PASSWORD` (Android release
signing), and `DIETER_IOS_SIGN_IDENTITY`, `DIETER_IOS_SIGN_STYLE`,
`DIETER_IOS_PROFILE_SPECIFIER`, `DIETER_IOS_SHARE_PROFILE_SPECIFIER` (iOS
signing). See [apps/kotlin](../../apps/kotlin/README.md) and
[apps/apple](../../apps/apple/README.md).
