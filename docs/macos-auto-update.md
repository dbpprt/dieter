# Safe automatic macOS updates

The opt-in updater checks the official stable release at **09:00 and 21:00 local
time**, plus login. macOS coalesces missed checks when the computer wakes. The
computer must be logged in and online. This updates one Mac; install separately
on each Mac. It does not update a gateway or silently re-enroll machines.

Install from this checkout using Python 3.9 or later:

```sh
python3 scripts/macos_auto_update.py install
python3 scripts/macos_auto_update.py status
```

The installer copies the updater into `DIETER_HOME/auto-update/updater.py` and
registers `com.dbpprt.dieter.auto-update` in the user's LaunchAgents. The checkout
is no longer needed. Defaults target the arm64 Homebrew fixed service runtime,
`/Applications/Dieter.app`, and `~/Library/LaunchAgents/sh.brew.dieter.plist`.
Use `--root`, `--runtime`, `--app`, and `--service-plist` for other installations.
For a manual installation at `~/.local/bin/dieter` with its capture helper,
use `--runtime "$HOME/.local" --service-plist
"$HOME/Library/LaunchAgents/com.dbpprt.dieter.daemon.plist"`. The LaunchAgent
must run that binary directly with `daemon start`. In this mode only the two
Dieter binaries are backed up/replaced; unrelated tools in the prefix are never
removed. Symlinked manual binaries are rejected.

The user must own the runtime and application bundle. No administrator prompt,
password storage, or privileged helper is involved.

## Eligibility and preservation

- Only official stable arm64 releases are considered. Verify checksums and the
  expected Apple Developer ID signatures for the daemon, capture helper, and app;
  assess the application's notarization. App and daemon must be the same release.
- The signed candidate must implement `__update-preflight --root PATH`. This
  offline installer probe reads the existing storage version and reports its API
  contract without initializing, migrating, repairing, or resetting the store.
  **Older releases without this probe are skipped.** Publishing this change in a
  signed release is required before automatic installation becomes available.
- API contract changes, unsupported storage, unavailable gateways, and unhealthy
  current daemons defer activation. They require a separate coordinated update.
- Quit Dieter normally to allow an update. The updater never force-quits it or
  discards drafts. Active agents, terminals, remote commands and screen sessions
  defer the check. A new turn can race the final idle check; normal daemon
  shutdown remains responsible for durable suspension, so this is not a promise
  of zero interruption for remotely submitted work.
- After stopping the service, take its exclusive data-directory runtime lock and
  copy the complete store (except the updater directory itself), old daemon
  runtime, and old app Contents. Preserve symbolic links without copying their
  external targets. Git repositories outside DIETER_HOME are untouched.
- Backups live under `DIETER_HOME/auto-update/backups`, with private permissions.
  They are never automatically deleted. Insufficient space or a backup failure
  leaves the previous installation in place. These local backups do not replace
  an independent backup against disk failure.
- A durable update journal allows the next check to recover after a crash. A
  failed daemon startup restores the previous binaries. **Recovery never
  replaces the live store**, because new messages may already have arrived.
  The pre-update data snapshot remains available for manual recovery.
- The fixed runtime processes rollback before opening the store. This prevents
  an incompatible candidate from failing forever before reaching rollback.

Inspect the last result without opening any chats:

```sh
python3 ~/.dieter/auto-update/updater.py status
```

A `deferred` result includes the reason. Checks are serialized and never keep
retrying in a tight loop. If recovery needs Dieter closed, quit it and run the
installed updater's `run` command, or wait for the next check.

Disable scheduling without deleting data or backups:

```sh
python3 ~/.dieter/auto-update/updater.py uninstall
```

For a custom root, pass `--root /absolute/path` to these commands.

## Testing

```sh
python3 -m unittest discover -s scripts -p macos_auto_update_test.py
go test ./internal/cli -run TestUpdatePreflight
just check-changed --dry-run
just check-changed
```

All automated lifecycle tests use disposable directories and mocked service
controls; they never restart or install over the operator's daemon. Manual
signed-release qualification on a disposable Mac is still needed before a
release containing this feature is promoted.

## One central release watcher

For a fleet, run `scripts/fleet_release_watch.py` on an always-on Linux host.
The systemd units in `deploy/fleet/` check GitHub at 09:00 and 21:00 Europe/Berlin
(with up to five minutes of jitter). The watcher atomically publishes only the
selected official release's tag, asset URLs and check timestamp. It requires no
machine credentials and never reads a Dieter store. A failed check keeps the
previous selection; clients reject it after 36 hours. Downgrades are rejected.

Install both Python scripts together under `/opt/dieter-release-watch/`, copy
the two units into `/etc/systemd/system/`, then run:

```sh
useradd --system --no-create-home --shell /usr/sbin/nologin dieter-release-watch
systemctl daemon-reload
systemctl start dieter-release-watch.service
systemctl enable --now dieter-release-watch.timer
```

Serve **only** `/var/lib/dieter-release-watch/release.json` through an existing
HTTPS server, with `Cache-Control: no-store`. Do not serve its parent directory
or any Dieter data directory. For Caddy, add this exact-path handler before the
existing gateway handler, retaining the existing gateway configuration:

```caddyfile
handle /dieter-release.json {
    root * /var/lib/dieter-release-watch
    rewrite * /release.json
    header Cache-Control no-store
    file_server
}
```

Validate the HTTPS response before enrolling clients:

```sh
python3 scripts/macos_auto_update.py install --release-feed https://YOUR-HOST/dieter-release.json
```

Keep any custom `--runtime`, `--service-plist`, `--root` and `--app` arguments
from the original installation. Installation validates the feed before replacing
the existing schedule. Managed Macs retry the central selection every 15 minutes
and at login. They do not query GitHub for the latest release. Offline Macs
catch up after reconnecting; busy Macs wait for a later retry. Each Mac still
independently enforces signatures, compatibility, backups and rollback. The
watcher selects releases; it does not collect per-machine completion telemetry.
Use the installed updater's `status` command on each machine for actual results.

This works across NAT without inbound access to the Macs. The public feed has
no credentials, machine identifiers, chat data, remote commands, or configurable
installer arguments. Tampered or stale selections cannot bypass local checks.
The feed host is trusted to select among official signed releases; it cannot
supply arbitrary binaries. Secure that host like other update infrastructure.

The watcher covers macOS app/daemon pairs. Gateway software maintenance remains
a separate operation: an API or gateway database format change needs explicit
coordination and must never reset registrations as part of an automatic update.
Do not disable existing gateway backup/maintenance timers during fleet setup.

If the gateway owns port 443 directly, do not replace or move it for this feature.
`deploy/fleet/nginx-release-feed.conf.example` shows an optional separate HTTPS
listener on 8443. Configure the actual hostname/certificate, run `nginx -t`, and
verify the exact feed path and 404 responses for other paths before opening the
port/enrolling clients. Keep the TLS certificate renewal/reload hook working.
Public network changes require an explicit operator decision. The watcher itself
does not install a proxy or modify firewall rules.
