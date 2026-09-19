//go:build linux

package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/serviceruntime"
)

const managedSystemdUnitHeader = "# Managed by Dieter. Reinstall through the CLI after changing service options."

type linuxServiceInstallOptions struct {
	start         bool
	force         bool
	address       string
	directAddress string
	directHost    string
	directNetwork string
	preserveRoute bool
	// Isolated tests may supply a known ELF. Production resolves the helper
	// beside the invoking Dieter executable, matching release installation.
	captureExecutable string
}

func platformServiceCommand(c *CLI, action string, args []string) error {
	usage := "Usage: dieter daemon service " + action + "\n"
	if action == "install" {
		usage = `Usage: dieter daemon service install [--no-start] [--force] [--addr ADDRESS]
       [--direct-addr ADDRESS --direct-host HOST [--direct-network KIND]]

Install a systemd user service backed by Dieter's fixed, rollback-capable Linux
runtime. Put persistent service-only environment values such as SSH_AUTH_SOCK
or PATH overrides in DIETER_HOME/service.env, then restart the service.
`
		set := flags("daemon service install")
		noStart := set.Bool("no-start", false, "install and enable without starting the service")
		force := set.Bool("force", false, "replace a non-Dieter systemd user unit")
		address := set.String("addr", "127.0.0.1:4242", "loopback API listen address")
		directAddress := set.String("direct-addr", "", "optional authenticated TLS listen address")
		directHost := set.String("direct-host", "", "host advertised for the direct TLS route")
		directNetwork := set.String("direct-network", "lan", "direct route kind: loopback, lan, tailscale, or public")
		help, err := parse(set, args, usage, c.Out)
		if help || err != nil {
			return err
		}
		if set.NArg() != 0 {
			return errors.New(usage)
		}
		routeFlagSet := false
		set.Visit(func(value *flag.Flag) {
			switch value.Name {
			case "addr", "direct-addr", "direct-host", "direct-network":
				routeFlagSet = true
			}
		})
		options := linuxServiceInstallOptions{
			start: !*noStart, force: *force, address: strings.TrimSpace(*address),
			directAddress: strings.TrimSpace(*directAddress), directHost: strings.TrimSpace(*directHost), directNetwork: strings.TrimSpace(*directNetwork),
			preserveRoute: !routeFlagSet,
		}
		if err := validateLinuxServiceOptions(options); err != nil {
			return err
		}
		return installSystemdUserService(c.Store.Root, options, c.Out)
	}
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			fmt.Fprint(c.Out, usage)
			return nil
		}
	}
	if len(args) != 0 {
		return errors.New(usage)
	}
	switch action {
	case "start", "restart", "stop":
		return runSystemctlUser(action, "dieter.service")
	case "status":
		cmd, err := systemctlUserCommand("status", "--no-pager", "--full", "dieter.service")
		if err != nil {
			return err
		}
		cmd.Stdout, cmd.Stderr = c.Out, c.Err
		return cmd.Run()
	case "uninstall":
		return uninstallSystemdUserService(c.Out)
	default:
		return fmt.Errorf("unsupported service action %q", action)
	}
}

func installAndStartPlatformService(root string, out interface{ Write([]byte) (int, error) }) error {
	return installSystemdUserService(root, linuxServiceInstallOptions{start: true, address: "127.0.0.1:4242", directNetwork: "lan", preserveRoute: true}, out)
}

func serviceStartHint() string {
	return "Skipped; install it later with `dieter daemon service install`."
}

func systemdUserUnitPath() (string, error) {
	config := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME"))
	if config == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		config = filepath.Join(home, ".config")
	}
	return filepath.Join(config, "systemd", "user", "dieter.service"), nil
}

func installSystemdUserService(root string, options linuxServiceInstallOptions, out interface{ Write([]byte) (int, error) }) error {
	if !filepath.IsAbs(root) {
		return errors.New("DIETER_HOME must be absolute for a managed service")
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return err
	}
	unitPath, err := systemdUserUnitPath()
	if err != nil {
		return err
	}
	var existingUnit []byte
	if raw, readErr := os.ReadFile(unitPath); readErr == nil {
		existingUnit = raw
		if !strings.HasPrefix(string(raw), managedSystemdUnitHeader) && !legacyDieterUnit(raw) && !options.force {
			return fmt.Errorf("%s is not managed by Dieter; rerun with --force to replace it", unitPath)
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return readErr
	}
	if err := os.MkdirAll(filepath.Dir(unitPath), 0o700); err != nil {
		return err
	}
	runtimeRoot := filepath.Join(root, "service")
	stageDirectory, err := os.MkdirTemp(root, ".service-install-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stageDirectory)
	if err := copyServiceExecutable(executable, filepath.Join(stageDirectory, "dieter")); err != nil {
		return err
	}
	captureExecutable := options.captureExecutable
	if captureExecutable == "" {
		captureExecutable = filepath.Join(filepath.Dir(executable), "dieter-capture")
	}
	if err := copyServiceExecutable(captureExecutable, filepath.Join(stageDirectory, "dieter-capture")); err != nil {
		return fmt.Errorf("stage Linux capture helper %s: %w; reinstall the complete Dieter release", captureExecutable, err)
	}
	stageCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
	err = serviceruntime.PlatformRuntime(runtimeRoot).Stage(stageCtx, stageDirectory)
	cancel()
	if err != nil {
		return fmt.Errorf("stage managed Linux runtime: %w", err)
	}
	managedExecutable := filepath.Join(runtimeRoot, "bin", "dieter")
	pathValue := servicePATH(filepath.Dir(executable))
	arguments := []string{"--store", root, "daemon", "start", "--service", "--runtime", runtimeRoot, "--addr", options.address}
	if options.directAddress != "" {
		arguments = append(arguments, "--direct-addr", options.directAddress, "--direct-host", options.directHost, "--direct-network", options.directNetwork)
	}
	execStart := systemdQuote(managedExecutable)
	for _, argument := range arguments {
		execStart += " " + systemdQuote(argument)
	}
	if options.preserveRoute && strings.HasPrefix(string(existingUnit), managedSystemdUnitHeader) {
		if previous := managedExecStart(existingUnit); strings.HasPrefix(previous, systemdQuote(managedExecutable)+" ") && strings.Contains(previous, systemdQuote("--store")+" "+systemdQuote(root)) {
			execStart = previous
		}
	}
	unit := managedSystemdUnitHeader + "\n" + `[Unit]
Description=Dieter local daemon
Documentation=https://github.com/dbpprt/dieter
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=main
ExecStart=` + execStart + `
Restart=always
RestartSec=5s
TimeoutStopSec=30s
KillMode=mixed
UMask=0077
Environment=` + systemdQuote("DIETER_SERVICE_MANAGER=systemd-user") + `
Environment=` + systemdQuote("PATH="+pathValue) + `
EnvironmentFile=-` + systemdEscapeWord(filepath.Join(root, "service.env")) + `
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
`
	if err := atomicWriteServiceFile(unitPath, []byte(unit), 0o600); err != nil {
		return err
	}
	if err := runSystemctlUser("daemon-reload"); err != nil {
		return fmt.Errorf("reload systemd user manager: %w", err)
	}
	if err := runSystemctlUser("enable", "dieter.service"); err != nil {
		return fmt.Errorf("enable Dieter systemd user service: %w", err)
	}
	if options.start {
		if err := runSystemctlUser("restart", "dieter.service"); err != nil {
			return fmt.Errorf("start Dieter systemd user service: %w", err)
		}
	}
	fmt.Fprintf(out, "Installed systemd user service at %s.\n", unitPath)
	if options.start {
		fmt.Fprintln(out, "Started Dieter through the systemd user manager.")
	}
	return nil
}

func validateLinuxServiceOptions(options linuxServiceInstallOptions) error {
	host, _, err := net.SplitHostPort(options.address)
	if err != nil {
		return fmt.Errorf("invalid loopback API address: %w", err)
	}
	ip := net.ParseIP(host)
	if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("the local API address must be loopback")
	}
	if (options.directAddress == "") != (options.directHost == "") {
		return errors.New("--direct-addr and --direct-host must be supplied together")
	}
	switch options.directNetwork {
	case "loopback", "lan", "tailscale", "public":
	default:
		return errors.New("--direct-network must be loopback, lan, tailscale, or public")
	}
	if options.directAddress != "" {
		if _, _, err := net.SplitHostPort(options.directAddress); err != nil {
			return fmt.Errorf("invalid direct TLS address: %w", err)
		}
	}
	return nil
}

func legacyDieterUnit(raw []byte) bool {
	text := string(raw)
	return strings.Contains(text, "dieter daemon start --service") || strings.Contains(text, "daemon start --service")
}

func managedExecStart(raw []byte) string {
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(line, "ExecStart=") {
			return strings.TrimPrefix(line, "ExecStart=")
		}
	}
	return ""
}

func copyServiceExecutable(source, target string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	_, copyErr := out.ReadFrom(in)
	syncErr := out.Sync()
	closeErr := out.Close()
	return errors.Join(copyErr, syncErr, closeErr)
}

func uninstallSystemdUserService(out interface{ Write([]byte) (int, error) }) error {
	unitPath, err := systemdUserUnitPath()
	if err != nil {
		return err
	}
	if raw, readErr := os.ReadFile(unitPath); errors.Is(readErr, os.ErrNotExist) {
		fmt.Fprintln(out, "Dieter systemd user service is not installed; DIETER_HOME was preserved.")
		return nil
	} else if readErr != nil {
		return readErr
	} else if !strings.HasPrefix(string(raw), managedSystemdUnitHeader) {
		return fmt.Errorf("refusing to remove non-Dieter unit %s", unitPath)
	}
	// An explicit uninstall authorizes stopping this service. Failure to stop a
	// missing/inactive unit is harmless, but other manager failures are useful.
	cmd, commandErr := systemctlUserCommand("disable", "--now", "dieter.service")
	if commandErr != nil {
		return commandErr
	}
	if output, runErr := cmd.CombinedOutput(); runErr != nil && !strings.Contains(string(output), "not loaded") && !strings.Contains(string(output), "does not exist") {
		return fmt.Errorf("disable Dieter systemd user service: %w: %s", runErr, strings.TrimSpace(string(output)))
	}
	if err := os.Remove(unitPath); err != nil {
		return err
	}
	if err := runSystemctlUser("daemon-reload"); err != nil {
		return err
	}
	fmt.Fprintln(out, "Removed the Dieter systemd user service; DIETER_HOME and projects were preserved.")
	return nil
}

func systemdQuote(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\"", "\\\"")
	value = strings.ReplaceAll(value, "%", "%%")
	return "\"" + value + "\""
}

func systemdEscapeWord(value string) string {
	const hexadecimal = "0123456789abcdef"
	var escaped strings.Builder
	for index := 0; index < len(value); index++ {
		character := value[index]
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || strings.ContainsRune("/._-", rune(character)) {
			escaped.WriteByte(character)
			continue
		}
		escaped.WriteString("\\x")
		escaped.WriteByte(hexadecimal[character>>4])
		escaped.WriteByte(hexadecimal[character&0x0f])
	}
	return escaped.String()
}

func servicePATH(executableDirectory string) string {
	home, _ := os.UserHomeDir()
	items := []string{executableDirectory}
	// Preserve absolute interactive PATH entries selected during installation
	// so nvm/asdf-installed Node and user-installed harnesses remain available
	// after systemd starts without a login shell. Relative entries are never
	// embedded in the service definition.
	for _, item := range filepath.SplitList(os.Getenv("PATH")) {
		if filepath.IsAbs(item) {
			items = append(items, filepath.Clean(item))
		}
	}
	items = append(items, filepath.Join(home, ".local", "bin"), filepath.Join(home, ".bun", "bin"), "/usr/local/bin", "/usr/bin", "/bin")
	seen := make(map[string]bool)
	var unique []string
	for _, item := range items {
		if item != "" && !seen[item] {
			seen[item] = true
			unique = append(unique, item)
		}
	}
	return strings.Join(unique, ":")
}

func atomicWriteServiceFile(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".dieter-service-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func systemctlUserCommand(args ...string) (*exec.Cmd, error) {
	path, err := exec.LookPath("systemctl")
	if err != nil {
		return nil, errors.New("systemctl is required for the Linux user service")
	}
	cmd := exec.Command(path, append([]string{"--user"}, args...)...)
	return cmd, nil
}

func runSystemctlUser(args ...string) error {
	cmd, err := systemctlUserCommand(args...)
	if err != nil {
		return err
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl --user %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

func managedServiceStatus(manager string) string {
	if manager != "systemd-user" && manager != "managed" {
		return "unknown"
	}
	cmd, err := systemctlUserCommand("is-active", "dieter.service")
	if err != nil {
		return "unknown"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd = exec.CommandContext(ctx, cmd.Path, cmd.Args[1:]...)
	raw, err := cmd.Output()
	status := strings.TrimSpace(string(raw))
	if status != "" {
		return status
	}
	if err != nil {
		return "inactive"
	}
	return "unknown"
}

func notifyServiceReady(manager string) error {
	if manager != "systemd-user" {
		return nil
	}
	socket := strings.TrimSpace(os.Getenv("NOTIFY_SOCKET"))
	if socket == "" {
		return errors.New("systemd service did not provide NOTIFY_SOCKET")
	}
	if strings.HasPrefix(socket, "@") {
		socket = "\x00" + strings.TrimPrefix(socket, "@")
	}
	connection, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: socket, Net: "unixgram"})
	if err != nil {
		return fmt.Errorf("connect systemd notification socket: %w", err)
	}
	defer connection.Close()
	if err := connection.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return err
	}
	_, err = connection.Write([]byte("READY=1\nSTATUS=Dieter daemon is ready\nMAINPID=" + strconv.Itoa(os.Getpid())))
	return err
}
