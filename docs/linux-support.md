# Linux daemon support

Dieter supports Linux as an unprivileged daemon and remote-screen host on amd64
and arm64. The supported managed configuration is a modern systemd distribution
with a user manager. Foreground operation is available on non-systemd systems,
WSL, and containers, but managed startup, rollback updates, power operations,
restart-durable terminals, and graphical-session discovery may be unavailable.

Official viewer clients remain macOS, iOS, and Android; there is no native Linux
viewer yet. Linux can host H.264 screen sessions through the release's companion
`dieter-capture` helper. X11 uses XImage/XDamage capture and XTest input. Wayland
uses the standard ScreenCast/RemoteDesktop portals and PipeWire, including a
local source/permission prompt. Screen hosting degrades independently when its
optional dependencies or a graphical login are absent.

Controlling Mac sessions use an immediate viewer-side cursor while the Linux
capture backend hides its embedded cursor. This keeps pointer feedback off the
capture/encode/network/decode path. View-only sessions and touch clients keep an
embedded host cursor because Linux does not yet publish separate cursor metadata.

The assessed path to general Wayland, X11, hardware/software encoder, and
headless-virtual support is documented in the
[Linux screen-sharing plan](linux-screen-sharing-plan-2026-09-18.md).

## Requirements

Dependencies are feature-scoped. The daemon continues to run when an optional
integration is absent, and `dieter doctor` reports the resulting degraded
feature.

| Dependency | Needed for |
| --- | --- |
| Node.js 22.19 or newer and npm | Bundled AI SDK Harness runtime |
| Git | Registered projects and worktree operations |
| A configured harness login or API key | Starting agent turns |
| `curl`, `tar`, `awk`, `install`, `mktemp`, and `sha256sum` or `shasum` | Portable signed installer |
| `cosign` | Portable signed installation and managed daemon updates |
| systemd user manager with `systemctl` and `systemd-run` | Supported managed service, rollback updates, and keeping durable terminals outside the service cgroup |
| `tmux` | Terminal sessions that survive daemon restarts; ordinary reconnectable terminals still work without it |
| `busctl` and systemd-logind | Remote restart and shutdown operations |
| `xdg-open` | Opening browser authentication from the CLI; a printed URL remains available without it |
| `dieter-capture` from the same release | Linux screen hosting; staged and activated with the daemon as one verified managed-service pair |
| GStreamer core, app/video base libraries, tools, H.264 parser, conversion, X11/PipeWire sources, and at least one H.264 encoder | Linux capture and encoding |
| `json-glib`, X11, XRandR, and XTest runtime libraries | Helper protocol, X11 monitor enumeration, and X11 control |
| `xdg-desktop-portal`, a desktop portal backend, PipeWire, and WirePlumber | Wayland capture/control and local consent |

Install the common host packages with the distribution package manager. For
example:

```sh
# Arch Linux / Garuda (daemon plus X11/Wayland screen hosting)
sudo pacman -S --needed curl git nodejs npm tmux json-glib libxtst libxrandr \
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
  gst-plugin-pipewire pipewire wireplumber xdg-desktop-portal
# Add the portal backend for the desktop, for example:
sudo pacman -S --needed xdg-desktop-portal-kde

# Debian / Ubuntu (choose the GNOME or KDE portal backend for the desktop)
sudo apt-get update
sudo apt-get install -y ca-certificates curl git nodejs npm tmux \
  libjson-glib-1.0-0 libxtst6 libxrandr2 gstreamer1.0-tools \
  gstreamer1.0-x gstreamer1.0-pipewire gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-gnome

# Fedora (encoder availability varies with enabled repositories)
sudo dnf install -y ca-certificates curl git nodejs npm tmux json-glib \
  libXtst libXrandr gstreamer1 gstreamer1-plugins-base \
  gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-vaapi \
  pipewire pipewire-gstreamer wireplumber xdg-desktop-portal xdg-desktop-portal-gnome
```

Confirm that the distribution's Node.js package is version 22.19 or newer;
otherwise install a current Node.js 22 release from a trusted package source.
Install `cosign` using
[Sigstore's documented method](https://docs.sigstore.dev/cosign/system_config/installation/).
The Dieter installer deliberately does not invoke a package manager or `sudo`.

Published archives already contain `dieter-capture`. A source install with
`just install` builds it locally and additionally needs a C compiler, `pkg-config`,
and development headers. Install `base-devel pkgconf glib2 gstreamer
gst-plugins-base-libs json-glib libx11 libxtst libxrandr` on Arch;
`build-essential pkg-config libglib2.0-dev libgstreamer1.0-dev
libgstreamer-plugins-base1.0-dev libjson-glib-dev libx11-dev libxtst-dev
libxrandr-dev` on Debian/Ubuntu; or `gcc make pkgconf-pkg-config glib2-devel
gstreamer1-devel gstreamer1-plugins-base-devel json-glib-devel libX11-devel
libXtst-devel libXrandr-devel` on Fedora. Use `just install "$HOME/.local" "" false`
only for an intentionally headless source installation.

Install `tmux` before starting the daemon when possible. If it is added while
the daemon is already running, finish active agent turns and then run
`dieter daemon service restart`; newly created terminals will then use the
restart-durable backend. Never run the Dieter service itself as root.

Headless machines may omit every screen-only package. A screen host needs at
least one encoder reported by `gst-inspect-1.0`: `vah264enc`, `nvh264enc`,
`v4l2h264enc`, `x264enc`, or `openh264enc`. Hardware encoders are preferred;
software encoding is bounded by host capacity. Run `dieter doctor` to see the
installed helper, active session, displays, encoder, and other optional degraded
features.

## Install

After the dependencies above are available, run:

```sh
curl -fsSL https://github.com/dbpprt/dieter/releases/latest/download/install.sh | sh
dieter setup
dieter project open /absolute/path/to/project
```

The installer verifies `SHA256SUMS.sigstore.json` against the GitHub Actions
OIDC identity of `.github/workflows/release.yml` on `main`, verifies the selected
archive's SHA-256 digest, validates archive paths, and replaces each executable
by atomic rename. On systemd it also stages the verified pair under
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

The service may start before the desktop login and intentionally does not rely on
one global `$DISPLAY`. Each helper launch discovers only allow-listed variables
from a same-user graphical process. If the account has multiple simultaneous
seats/sessions, set `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`,
`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, and `XDG_SESSION_TYPE` explicitly
in `$DIETER_HOME/service.env` to select the intended session, then restart the
service after active work finishes.

## Screen permissions and limits

Screen hosting is available automatically when this enrolled daemon has a
supported graphical session, encoder, capture permission, and input permission.
There is no saved enable/disable policy. Headless hosts keep the other daemon
features and report screen hosting as unsupported with a dependency/session reason.

Complete the required desktop grants through the running daemon:

```sh
dieter daemon permissions
dieter screen capabilities
```

Capabilities report ready, permission required, or unsupported. On Wayland,
`not_requested` means the portal can request source/device consent when a session
starts; it does not bypass the compositor's consent dialog. No frame is streamed
until the desktop permits it. Sessions may choose not to take control.

All operations support global `--machine ID|NAME`. Grant permissions on the
host, then retry the connection. To prevent screen access, revoke the OS grant
or the daemon's enrollment. For diagnostics:

```sh
dieter daemon permissions --check
dieter screen permissions --request-control
dieter screen capabilities
```

Checks do not write settings; a Wayland check may open the compositor's prompt.

On X11, the check captures and discards one encoded frame and verifies XTest
without injecting input. On Wayland, the desktop portal owns source selection and
permission UI. Dieter stores only the opaque restore token under `DIETER_HOME`
with private permissions; the compositor may ignore/revoke it or prompt again.
Declining a prompt leaves the daemon and other features running.

Linux currently advertises H.264 video, adaptive bitrate/geometry, pointer,
buttons, scrolling, and physical-key input. Wayland uses the portal's bounded
Notify methods; X11 uses XTest and releases held state on control loss or helper
exit. Committed Unicode text, clipboard text/images/files, separate cursor-shape
metadata, HEVC, audio, physical display-mode switching, and virtual/headless
desktops remain unavailable and are not silently emulated. Embedded cursor is
available when the selected backend supplies it.

Disabling host control retires active Linux screen sessions so the helper drops
its portal device grant immediately; viewers can reconnect in view-only mode.

## Updates and rollback

The remote `machine update --confirm UPDATE` operation is available only when
the running executable is Dieter's managed Linux runtime and `cosign`,
`systemctl`, and `systemd-run` are available. The update worker runs in a
separate systemd unit, downloads only the official GitHub release, verifies its
Sigstore identity and checksum, prepares the candidate's immutable harness
runtime, stages it, and restarts `dieter.service`.

An in-flight turn checkpoints and resumes with its pinned runtime digest. That
affinity ends when the turn finishes; the next message in the same conversation
uses the current runtime. The new executable is committed after the API listener
binds, recovered workers report protocol activity, and systemd readiness is sent.
A crash or readiness failure leaves an activation journal; the next systemd
restart swaps the previous verified executable back. Update output is retained
in `$DIETER_HOME/logs/update.log`.

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
credentials, logs, SQLite files, and journals are created as `0600`. Permission
checks never change modes inside managed Git worktrees, harness packages, or
recovery payloads. Unsupported development stores require a fresh home; no
historical permission or data migration is provided.

Back up `DIETER_HOME` only while the daemon is stopped or by using a filesystem
snapshot that preserves a consistent SQLite state. Project repositories remain
at their registered paths and need their normal independent backup policy.

## Support tiers

- Supported: systemd user service on Linux amd64/arm64 with a local filesystem.
- Screen host: active X11 with XImage/XTest, or Wayland with current
  ScreenCast/RemoteDesktop portals and PipeWire; exact encoder/backend is
  capability-detected.
- Degraded: foreground operation on non-systemd distributions and WSL.
- Best effort: containers; graphical session, logind, and user-systemd features
  are commonly absent.
- Not supported on Linux: native viewer app, hosted clipboard/file transfer,
  system audio, physical mode switching, or implicit DRM/KMS/uinput access.
