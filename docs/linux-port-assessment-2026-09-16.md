# Porting Dieter to Linux (Garuda on box) — assessment

Date: 2026-09-16 · Evidence: repo scouting (both repos) + live probes of `box` (Ubuntu 24.04) and `garuda-box` (Garuda Dr460nized, Plasma X11, kernel 6.18.47-1-lts).

## Headline

**The daemon already runs on Linux today.** Every GitHub release publishes static
`dieter-linux-amd64`/`arm64` binaries (`release.yml:38-91`, `CGO_ENABLED=0`). I
downloaded the latest release (`v0.4.160`) onto the Garuda guest, ran
`dieter serve`, and it came up healthy (`ready`, `/healthz` → 200). The port is
therefore not "make it run" but "make it install, boot-persist, and self-update
like the macOS Homebrew path does" — plus a small set of darwin-only features
that degrade gracefully on Linux.

## What the target actually is

| | |
|---|---|
| Guest | `garuda-box`, Garuda Dr460nized 260819, Plasma 6 on X11, `linux-lts` pinned `6.18.47-1` (IgnorePkg; newer kernels trip an AMD GART bug with the passthrough iGPU) |
| Resources | 16 host-passthrough vCPUs, 48 GiB RAM, 250 GB qcow2 (235 GB free) |
| Network | Bridged on `br0` (LAN DHCP `192.168.254.15` observed), first-class Tailscale node `garuda-box.tail65e91.ts.net` (`100.125.250.119`) |
| Access | Key-only SSH as `dbpprt`; passwordless **sudo is NOT provisioned in the guest** (only on the box host); `loginctl enable-linger` already set |
| Lifecycle | libvirt autostart on host boot; box is "intermittently powered" (WoL). No suspend — cold boots only. Host shutdown gracefully `virsh shutdown`s the guest |
| Reconciliation convention | root-run idempotent guest scripts (`configure_garuda_guest.sh` pattern: pacman `--needed`, version-guarded pins, `systemctl enable --now`, firewalld rich rules). No guest systemd timers exist anywhere in the box repo yet |
| firewalld | loopback untouched by default → a loopback-only daemon needs **no firewall change** |

## Portability findings (repo evidence)

### Already works on Linux (zero or near-zero work)

- Static linux release binaries shipped every release; no CGO needed.
- `serviceruntime` staging/activation/rollback: `flock` install+service locks
  (`unix.go:1` `darwin || linux`), journalled activation, crash-rollback
  candidate pair, RENAMEAT2 exchange (`exchange_linux.go`). Portable as-is.
- Machine restart/shutdown via systemd-logind `busctl` (`control_linux.go:12-64`).
- GPU telemetry: NVIDIA `nvidia-smi` + AMD sysfs (`gpu_linux.go`).
- Terminal durability via tmux, remote exec, statfs disk probe, xdg-open auth
  URL, atomic writes, 0600 credential files (no Keychain dependency).
- Gateway: multi-arch linux/amd64+arm64 container already published to ghcr
  (`gateway-image.yml:64-69`). Zero work.

### Darwin-only blockers

1. **Screen capture / remote desktop** (`internal/remotedesktop` + Swift
   `native/macos-capture`): capture helper, TCC permission probing, H264 path.
   Linux gets the synthetic source only. Fine for a daemon/CLI host; PipeWire
   portal capture would be a separate future project.
2. **`VerifySignedPair` shells `/usr/bin/codesign`** with TeamID
   (`runtime.go:69-84`). The fixed pair is `[dieter, dieter-capture]`
   (`runtime.go:27`) — Linux has no capture helper. Needs a Linux verify path
   (sha256 manifest — releases already publish `SHA256SUMS` — or detached
   ed25519 sig; trust infra exists in `internal/trust`) and a single-binary
   pair mode.
3. **Homebrew-coupled lifecycle**: `setup` installs/starts via
   `brew services` (`daemon_ops.go:390-479`); `machine update` is
   Homebrew-managed-macOS-only (`control_linux.go:25` hardcodes the
   "unavailable" answer).
4. **macOS onboarding**: System Settings/TCC panes in `setup`. Trivial: no-op
   the permission flow on Linux.

### Missing-but-easy

- **systemd unit** mirroring the Homebrew launchd block
  (`homebrew_formula.py:38-47`): `ExecStart=<root>/bin/dieter daemon start
  --service --runtime <root>`, `Restart=always`, `RestartSec=5`, PATH including
  tmux/node.
- **Linux auto-update**: the worker architecture
  (`RunDaemonUpdateWorker`, `control.go:105-147` — detached worker runs from
  the already-running executable, bounded steps, noninteractive env, writes
  `~/.dieter/logs/update.log`) ports 1:1. Only the delivery steps differ:
  brew update/upgrade/services-restart → download release tarball → verify
  checksums → serviceruntime `Stage` → `systemctl restart dieter`.
- **`dieter setup` Linux branch**: install binary to fixed runtime +
  `systemctl enable --now`; make `--skip-screen-sharing` a no-op.
- Trivia: `just/daemon.just:38` uses `rg` in the test recipe (not on Garuda).

## Recommended install path (Garuda)

Follow the box repo's existing guest conventions
(`apps/virtualization/scripts/`):

1. **Artifact**: the official GitHub release tarball `dieter-linux-amd64.tar.gz`
   (or a rebuilt one during bring-up). Land at `/opt/dieter/service/bin/dieter`
   (Linux analogue of Homebrew's `var/dieter/service` fixed runtime; serviceruntime
   takes the root as a parameter, nothing brew-specific inside).
2. **Installer script** `scripts/install_dieter.sh` in `apps/virtualization/`,
   styled after `install_pinned_sunshine.sh`: version-guarded download,
   SHA256SUMS verification (do **not** add curl piping to shell; the box repo
   convention is checksum-pinned artifacts), idempotent `systemctl enable --now`,
   no unattended-sudo dependency — run once by hand as root via SSH.
3. **System unit** (not user unit): the daemon is machine-wide state
   (`DIETER_HOME=/var/lib/dieter` or keep `~/.dieter` if user-scoped is
   preferred); `Restart=always`, `RestartSec=5` mirrors the launchd contract.
   Wire into `configure_garuda_guest.sh`'s `systemctl enable --now` block for
   fresh installs; the standalone installer covers the existing VM.
4. **Smoke**: extend `apps/virtualization/scripts/smoke.sh` with a
   `systemctl is-active dieter` + loopback health check.

Do not put the daemon in Plasma autostart — that path is reserved for
session-bound Sunshine; linger is already enabled but a system unit is the
correct owner for machine state.

## Recommended auto-update

Two viable mechanisms; recommendation depends on how "product" vs "infra" the
Linux daemon is:

- **A (product parity — in-daemon, recommended eventually):** port the macOS
  worker verbatim: `machine update` capability for Linux when
  `serviceManaged` + fixed runtime detected; worker steps = fetch pinned
  release asset from GitHub (checksum-verify), `Stage` into the fixed runtime,
  `systemctl restart dieter`. The staging/rollback core already guarantees
  crash-safe activation, so a failed update leaves the previous pair running
  (failed listener-bind → rollback on next start, same as Homebrew).
  Keep it **on-demand** (`dieter --machine <id> machine update --confirm UPDATE`)
  initially — this preserves the repo invariant that Dieter never surprises the
  operator.
- **B (infra parity — systemd timer, recommended now):** a guest
  `dieter-update.service` + `.timer` (e.g. weekly) running a root script:
  compare `dieter --version` against the latest GitHub release
  (`releases/latest/download/` + SHA256SUMS), download → verify →
  `Stage` semantics (install to `service/bin.new`, exchange, restart) →
  health-check → rollback on failure. The box repo has **no guest timer
  precedent**; this would be the first, so keep it simple and bounded, log to
  `/var/log/dieter-update.log`, and gate it behind the same checksum pinning
  discipline as Sunshine.

B can exist before any in-daemon work; A supersedes it later and is the
version worth upstreaming into `control_linux.go` so remote
`machine update` works fleet-wide.

## Suggested sequencing

1. **Bring-up (no dieter-repo changes)**: run installer + unit on Garuda via
   box-repo conventions; enroll with `dieter setup <project>`; verify from the
   Mac: `dieter --machine <garuda-id> status`, remote exec, tmux terminal.
   Limitation to accept: remote desktop shows synthetic source only.
2. **Dieter repo (small PRs)**: Linux `VerifySignedPair` (SHA256SUMS) +
   single-binary pair; `dieter setup` systemd branch; Linux branch of
   `machine update` (worker A).
3. **Box repo**: committed installer script + unit + smoke extension; optional
   update timer (B) once (2) lands, or immediately with script-side staging.

## Verification performed

- Live: `box` SSH, `virsh dumpxml garuda-box` (bridged br0, iGPU hostdevs),
  guest SSH over Tailnet, package/toolchain probes (paru present, no Go pkg,
  linger on, no failed relevant units), firewall model review.
- Live port proof: downloaded official `dieter-linux-amd64` v0.4.160 tarball in
  the guest, ran `serve` on `127.0.0.1:4299` with a temp `DIETER_HOME` —
  daemon `ready`, `/healthz` 200; `daemon status` correct; `machine update`
  correctly reports unsupported-on-Linux today. Test artifacts cleaned up.
