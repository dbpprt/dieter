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
