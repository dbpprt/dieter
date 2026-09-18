# Linux daemon support

Dieter supports Linux as an unprivileged, headless daemon host on amd64 and
arm64. The supported managed configuration is a modern systemd distribution
with a user manager. Foreground operation is available on non-systemd systems,
WSL, and containers, but managed startup, rollback updates, power operations,
and restart-durable terminals may be unavailable there.

Official viewer clients remain macOS and Android. Linux hosts do not advertise
screen displays or codecs: native screen capture, input control, and clipboard
hosting remain macOS-only. Clients show the daemon's unavailable reason and
prevent starting an unsupported screen session.

## Requirements

- Node.js 22.19 or newer and npm
- Git
- `cosign` for signed installation and managed updates
- systemd user manager for the supported managed service
- `tmux` for terminal sessions that survive daemon restarts
- `busctl` plus systemd-logind for restart/shutdown operations
- a configured harness login or API key

Run `dieter doctor` to see required failures and optional degraded features.

## Install

Install cosign using the distribution package or Sigstore's documented package,
then run:

```sh
curl -fsSL https://github.com/dbpprt/dieter/releases/latest/download/install.sh | sh
dieter setup /absolute/path/to/project
```

The installer verifies `SHA256SUMS.sigstore.json` against the GitHub Actions
OIDC identity of `.github/workflows/release.yml` on `main`, verifies the selected
archive's SHA-256 digest, validates archive paths, and atomically installs the
binary. On systemd it also stages a fixed runtime under
`$DIETER_HOME/service/bin` and installs `dieter.service` under the user's systemd
configuration directory.

Use `--version VERSION` to pin a release, `--install-dir DIR` to choose the
executable directory, or `--no-service` for a foreground or non-systemd host.

Run the daemon as its normal unprivileged account, without `sudo`. The user
service intentionally retains access to that user's repositories, harness
configuration, and credentials. To start it at boot before interactive login,
an administrator can explicitly enable
lingering:

```sh
sudo loginctl enable-linger "$USER"
```

This is an administrator policy choice and is never performed automatically.

## Service management

```sh
dieter daemon service install
dieter daemon service status
dieter daemon service restart
dieter daemon logs --follow
dieter daemon service uninstall
```

`uninstall` removes only the unit and preserves `DIETER_HOME`, projects,
conversations, schedules, and managed runtime files. Add a verified direct TLS
route while installing with:

```sh
dieter daemon service install \
  --direct-addr 0.0.0.0:4243 \
  --direct-host host.example.net \
  --direct-network tailscale
```

The raw local API remains loopback-only. Put service-only environment values in
`$DIETER_HOME/service.env` using systemd EnvironmentFile syntax. Keep this file
mode `0600`; it can supply a stable PATH or credential-agent socket. Harness API
keys can remain in `$DIETER_HOME/.env`, which Dieter also keeps private.

The unit uses readiness notification, a thirty-second graceful stop window, a
private umask, and a fixed rollback-capable runtime. Dieter holds a separate
lifetime lock per `DIETER_HOME`. Durable tmux servers start in their own
transient user scopes so a daemon restart cannot reap them with the service
cgroup.

## Updates and rollback

The remote `machine update --confirm UPDATE` operation is available only when
the running executable is Dieter's managed Linux runtime and `cosign`,
`systemctl`, and `systemd-run` are available. The update worker runs in a
separate systemd unit, downloads only the official GitHub release, verifies its
Sigstore identity and checksum, stages it, and restarts `dieter.service`.

The new executable is committed after the API listener binds and systemd
readiness is sent. A crash or readiness failure leaves an activation journal;
the next systemd restart swaps the previous verified executable back. Update
output is retained in `$DIETER_HOME/logs/update.log`.

Distribution-managed packages should leave self-update disabled and upgrade
through their package manager to avoid ownership conflicts.

## Power operations

Restart and shutdown call systemd-logind over the system bus without a password
or interactive prompt. `dieter machine info` reports whether logind returns
`yes`, `challenge`, or `no`. If unattended power control is required, an
administrator must install a narrowly scoped polkit rule for the daemon user.
Dieter never accepts or stores a sudo or polkit password.

## Data and backup

`DIETER_HOME` and metadata directories are `0700`; Dieter-owned metadata,
credentials, logs, SQLite files, and journals are `0600`. Existing stores are
migrated once without changing modes inside managed Git worktrees, harness
packages, or recovery payloads.

Back up `DIETER_HOME` only while the daemon is stopped or by using a filesystem
snapshot that preserves a consistent SQLite state. Project repositories remain
at their registered paths and need their normal independent backup policy.

## Support tiers

- Supported: systemd user service on Linux amd64/arm64 with a local filesystem.
- Degraded: foreground operation on non-systemd distributions and WSL.
- Best effort: containers; graphical session, logind, and user-systemd features
  are commonly absent.
- Not supported on Linux: hosting remote screen/keyboard/clipboard sessions or
  a native Linux viewer app.
