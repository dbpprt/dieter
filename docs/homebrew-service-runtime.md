# Homebrew service runtime

Homebrew owns package distribution and the launchd service. The formula installs
the release into the Cellar as usual. Its declarative post-install step calls
`dieter __service-stage --root {{var}}/dieter/service` before any Dieter user store
is constructed. This internal command only copies and verifies installation
files; it never starts a service, requests permission, or touches a user's data.

The real service paths are:

```
$(brew --prefix)/var/dieter/service/bin/dieter
$(brew --prefix)/var/dieter/service/bin/dieter-capture
```

These must be regular signed files, with no symlink components in the runtime
path. Keep the release Developer ID team and designated requirements compatible.
The daemon identifier is `com.dbpprt.dieter.daemon`; the helper identifier is
`com.dbpprt.dieter.capture`. Both are verified against Dieter's Developer ID team
before staging and again before activation. Local ad-hoc builds are rejected.

## Install, update, recover

First installation publishes the verified pair in `bin`. Upgrades copy into a
temporary directory and atomically publish `pending`, leaving `bin` untouched.
The installation lock serializes stage, activate, commit, and recovery. A second
lifetime lock prevents activation while another fixed-runtime service is alive;
it survives the startup exec but is not inherited by normal helper processes.

On `brew services restart dieter`, the directly launched fixed-path daemon:

1. Verifies the staged pair and writes a durable activation journal containing
   hashes of both complete pairs and a random startup token.
2. Atomically exchanges the `bin` and candidate directories. Both fixed paths
   change together; neither goes missing and no symlink is introduced.
3. Executes the new daemon at the same fixed path with the lifetime lock.
4. Commits after initialization and successful API listener binding, before
   scheduler dispatch. It then collects the previous pair.

If the new executable cannot start, crashes, or cannot bind its listener before
commit, its next service start restores the previous verified pair using the
journal. Failures after this startup boundary are ordinary daemon failures, not
automatic application/data rollback. Never roll back user data.

The atomic directory exchange is implemented separately for macOS and Linux.
Developer ID verification remains macOS-specific; Linux verifies the signed
release manifest and ELF architecture, and its managed runtime stages the daemon
and native capture helper as one pair.
The runtime holds at most an active pair, pending pair, and activation candidate
during a normal update. The next staging operation reclaims interrupted private
temporary directories while holding the installation lock.

The existing native-client and CLI machine-update operation still runs Homebrew
update, formula upgrade, and service restart. The new formula must ship with the
new binaries; the release recipe generates it from this repository rather than
patching an independently maintained formula template.

## Permission migration and verification

Restart an old Cellar-based service once after installing the new formula so
Homebrew refreshes its launch definition. Then run `dieter daemon permissions`.
Grant Screen & System Audio Recording and Accessibility to the fixed **daemon**
path. Existing grants for another Cellar path do not migrate. A Keychain grant
does not imply screen or input permission.

`dieter screen permissions` and `dieter daemon permissions --check` ask the
running service to execute its production capture helper. They discard one
encoded frame, check event-posting permission without injecting input, and
report the actual daemon/helper paths. Neither changes settings. A failed RPC
never falls back to a helper started by the caller. `--request-control` on the
screen command explicitly allows an OS Accessibility prompt on the daemon host.

When macOS asks for a restart after granting access, use `brew services restart
dieter` and repeat the probe. Permission persistence across different signed
builds is an acceptance criterion, not something unit tests can establish.

Run the signed acceptance harness in a disposable logged-in macOS account/VM:

```
python3 scripts/homebrew_runtime_acceptance.py \
  --release-a /absolute/path/to/signed-release-a \
  --release-b /absolute/path/to/signed-release-b \
  --evidence /absolute/path/to/new-evidence-directory
```

Both release directories must contain this implementation, differently built
Developer ID-signed daemons, and their matching signed capture helpers. The
harness creates a unique temporary runtime, data home, random loopback listener,
and a unique user LaunchAgent. It checks the initial grant, stages B while A is
running, verifies A is unchanged, restarts the fixture, and requires capture and
input permission to pass without another grant. It retains JSON/signature
evidence and unloads only its own LaunchAgent. It never changes an operator's
Homebrew formula, live daemon, or TCC database. The OS grant remains a user action.

The native screen media/input integration suites remain `just mac
screens-native-test` and `just mac screens-test`; they complement the signed
permission test and do not substitute for it.

## Uninstall

Run `brew services stop dieter` before `brew uninstall dieter`. Homebrew preserves
the fixed runtime under `var`. It can be removed separately once no service uses
it. All user conversations, credentials and settings remain under `DIETER_HOME`.
Do not put user data or project metadata into the installation directory.

## References

- [Homebrew post-install steps](https://docs.brew.sh/Formula-Cookbook#running-commands-after-installation)
- [Homebrew service definitions](https://docs.brew.sh/Formula-Cookbook#service-files)
- [Apple path-based privacy identities](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary/identity)
- [Apple code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
