package cli

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

type daemonStatusView struct {
	Status               string `json:"status"`
	Running              bool   `json:"running"`
	APIHealthy           bool   `json:"apiHealthy"`
	Service              string `json:"service"`
	ServiceStatus        string `json:"serviceStatus,omitempty"`
	PID                  int    `json:"pid,omitempty"`
	Version              string `json:"version,omitempty"`
	StartedAt            string `json:"startedAt,omitempty"`
	Store                string `json:"store"`
	ListenAddress        string `json:"listenAddress"`
	LogPath              string `json:"logPath"`
	Enrolled             bool   `json:"enrolled"`
	DaemonID             string `json:"daemonId,omitempty"`
	DaemonName           string `json:"daemonName,omitempty"`
	GatewayURL           string `json:"gatewayUrl,omitempty"`
	GatewayState         string `json:"gatewayState"`
	GatewayConnectedAt   string `json:"gatewayConnectedAt,omitempty"`
	GatewayLastAckAt     string `json:"gatewayLastAcknowledgedAt,omitempty"`
	GatewayLastError     string `json:"gatewayLastError,omitempty"`
	CertificateExpiresAt string `json:"certificateExpiresAt,omitempty"`
	Projects             int    `json:"projects"`
	NodeReady            bool   `json:"nodeReady"`
}

func (c *CLI) daemonStatus(args []string) error {
	const usage = "Usage: dieter daemon status [--format table|json]\n"
	set := flags("daemon status")
	format := set.String("format", "table", "table or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || (*format != "table" && *format != "json") {
		return errors.New(usage)
	}

	view := daemonStatusView{
		Status: "stopped", Service: "foreground", Store: c.Root,
		ListenAddress: "127.0.0.1:4242", LogPath: link.LogPath(c.Root),
		GatewayState: link.GatewayNotEnrolled,
	}
	identity, identityErr := link.LoadIdentity(c.Root)
	if identityErr == nil {
		view.Enrolled = identity.Enrolled()
		view.DaemonID, view.DaemonName = identity.ID, identity.Name
		view.GatewayURL = identity.GatewayURL
		view.CertificateExpiresAt = identity.CertificateExpiresAt
		if view.Enrolled {
			view.GatewayState = link.GatewayDisconnected
		}
	} else if !errors.Is(identityErr, os.ErrNotExist) {
		return identityErr
	}

	runtimeStatus, runtimeErr := link.LoadRuntimeStatus(c.Root)
	if runtimeErr == nil {
		view.PID, view.Version, view.StartedAt = runtimeStatus.PID, runtimeStatus.Version, runtimeStatus.StartedAt
		view.ListenAddress = runtimeStatus.ListenAddress
		view.GatewayState = runtimeStatus.GatewayState
		view.GatewayConnectedAt = runtimeStatus.GatewayConnectedAt
		view.GatewayLastAckAt = runtimeStatus.GatewayLastAckAt
		view.GatewayLastError = runtimeStatus.GatewayLastError
		if runtimeStatus.LogPath != "" {
			view.LogPath = runtimeStatus.LogPath
		}
		if runtimeStatus.ServiceManaged {
			view.Service = strings.TrimSpace(runtimeStatus.ServiceManager)
			if view.Service == "" {
				if runtime.GOOS == "darwin" {
					view.Service = "homebrew"
				} else {
					view.Service = "managed"
				}
			}
			view.ServiceStatus = managedServiceStatus(c.env.Environment, view.Service)
		}
	} else if !link.IsRuntimeStatusMissing(runtimeErr) {
		return runtimeErr
	}
	view.APIHealthy, view.Projects = daemonHealthProjects(c.Root, view.ListenAddress)
	view.Running = view.APIHealthy && runtimeErr == nil && link.RuntimeStatusCurrent(runtimeStatus, time.Now().UTC())
	if view.Running {
		switch {
		case !view.Enrolled:
			view.Status = "local-only"
		case view.GatewayState == link.GatewayConnected:
			view.Status = "healthy"
		default:
			view.Status = "degraded"
		}
	} else if view.APIHealthy {
		view.Status = "unmanaged"
	}
	_, nodeErr := exec.LookPath("node")
	view.NodeReady = nodeErr == nil

	if *format == "json" {
		return jsonOut(c.Out, view)
	}
	fmt.Fprintf(c.Out, "Dieter daemon: %s\n", view.Status)
	fmt.Fprintf(c.Out, "  Service:  %s", view.Service)
	if view.ServiceStatus != "" {
		fmt.Fprintf(c.Out, " (%s)", view.ServiceStatus)
	}
	fmt.Fprintln(c.Out)
	if view.PID > 0 {
		fmt.Fprintf(c.Out, "  Process:  pid %d · %s\n", view.PID, view.Version)
	}
	fmt.Fprintf(c.Out, "  Local API: %s · %s\n", view.ListenAddress, healthLabel(view.APIHealthy))
	if view.Enrolled {
		fmt.Fprintf(c.Out, "  Machine:  %s · %s\n", view.DaemonName, view.DaemonID)
		fmt.Fprintf(c.Out, "  Gateway:  %s · %s\n", view.GatewayURL, view.GatewayState)
		if view.GatewayLastAckAt != "" {
			fmt.Fprintf(c.Out, "  Last ack: %s\n", view.GatewayLastAckAt)
		}
		if view.GatewayLastError != "" {
			fmt.Fprintf(c.Out, "  Last error: %s\n", view.GatewayLastError)
		}
	} else {
		fmt.Fprintln(c.Out, "  Gateway:  not enrolled · run `dieter setup`")
	}
	fmt.Fprintf(c.Out, "  Projects: %d\n", view.Projects)
	fmt.Fprintf(c.Out, "  Store:    %s\n", view.Store)
	fmt.Fprintf(c.Out, "  Logs:     %s\n", view.LogPath)
	return nil
}

func healthLabel(healthy bool) string {
	if healthy {
		return "healthy"
	}
	return "unreachable"
}

func daemonHealth(root, address string) bool {
	healthy, _ := daemonHealthProjects(root, address)
	return healthy
}

// daemonHealthProjects probes the local API and, when it is healthy, counts
// its active projects. The CLI never reads central storage, so a stopped
// daemon reports zero projects.
func daemonHealthProjects(root, address string) (bool, int) {
	if strings.TrimSpace(address) == "" {
		return false, 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()
	connection, err := grpc.NewClient(address, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithPerRPCCredentials(localauth.FileCredentials{Root: root}))
	if err != nil {
		return false, 0
	}
	defer connection.Close()
	client := dieterclient.New(connection)
	health, err := client.Health(ctx, &emptypb.Empty{})
	if err != nil || health.GetStatus() != "ok" || health.GetReleaseVersion() == "" {
		return false, 0
	}
	state, err := client.GetState(ctx, &dieterv1.GetStateRequest{AllProjects: true})
	if err != nil {
		return true, 0
	}
	return true, len(state.GetProjects())
}

func (c *CLI) daemonLogs(args []string) error {
	const usage = "Usage: dieter daemon logs [--lines N] [--follow]\n"
	set := flags("daemon logs")
	lines := set.Int("lines", 100, "number of recent lines")
	follow := set.Bool("follow", false, "continue streaming new log entries")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || *lines < 0 {
		return errors.New(usage)
	}
	path := link.LogPath(c.Root)
	if runtimeStatus, statusErr := link.LoadRuntimeStatus(c.Root); statusErr == nil && runtimeStatus.LogPath != "" {
		path = runtimeStatus.LogPath
	}
	return streamLog(c.Out, path, *lines, *follow)
}

func streamLog(out io.Writer, path string, lines int, follow bool) error {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("daemon log %q does not exist; start the daemon service first", path)
	}
	if err != nil {
		return err
	}
	chunks := bytes.Split(raw, []byte{'\n'})
	if len(chunks) > 0 && len(chunks[len(chunks)-1]) == 0 {
		chunks = chunks[:len(chunks)-1]
	}
	start := 0
	if lines < len(chunks) {
		start = len(chunks) - lines
	}
	for _, line := range chunks[start:] {
		if _, err := fmt.Fprintln(out, string(line)); err != nil {
			return err
		}
	}
	if !follow {
		return nil
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	offset := int64(len(raw))
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			info, statErr := os.Stat(path)
			if statErr != nil {
				continue
			}
			if info.Size() < offset {
				offset = 0
			}
			if info.Size() == offset {
				continue
			}
			file, openErr := os.Open(path)
			if openErr != nil {
				continue
			}
			_, _ = file.Seek(offset, io.SeekStart)
			written, copyErr := io.Copy(out, file)
			_ = file.Close()
			offset += written
			if copyErr != nil {
				return copyErr
			}
		}
	}
}

func (c *CLI) setup(args []string) error {
	const usage = `Usage: dieter setup [--gateway URL] [--name NAME] [--no-open] [--no-start]

Authorize this machine with GitHub and start the platform-managed daemon service.
On macOS, setup also registers the signed background privacy helper and guides
Screen Recording, Accessibility, Login Items approval and Input Monitoring.
Privacy stays off until explicitly enabled. --no-open and --no-start skip privacy
helper registration; use "dieter machine privacy setup" later on this Mac.
Project registration is separate; use
"dieter project open PATH" explicitly after setup.
The default gateway is https://gateway.getdieter.com; use --gateway for self-hosting.
Retrying incomplete enrollment updates the gateway while preserving the machine key.
`
	set := flags("setup")
	gatewayURL := set.String("gateway", buildinfo.DefaultGatewayURL, "gateway origin")
	hostname, _ := os.Hostname()
	name := set.String("name", hostname, "machine display name")
	noOpen := set.Bool("no-open", false, "do not open the verification URL or System Settings")
	noStart := set.Bool("no-start", false, "do not install, start, or restart the daemon service")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("setup does not accept project paths; register a project explicitly with `dieter project open PATH`")
	}
	if strings.TrimSpace(c.Machine) != "" {
		return errors.New("setup is local-only; omit --machine")
	}

	identity, identityErr := link.LoadIdentity(c.Root)
	if errors.Is(identityErr, os.ErrNotExist) || identityErr == nil && !identity.Enrolled() {
		enrollArgs := []string{"--gateway", *gatewayURL, "--name", *name}
		if *noOpen {
			enrollArgs = append(enrollArgs, "--no-open")
		}
		fmt.Fprintln(c.Out, "\n1. GitHub authorization")
		if err := c.daemonEnroll(enrollArgs); err != nil {
			return err
		}
	} else if identityErr != nil {
		return identityErr
	} else {
		fmt.Fprintf(c.Out, "\n1. GitHub authorization\nAlready enrolled as %s (%s).\n", identity.Name, identity.ID)
	}

	fmt.Fprintln(c.Out, "Projects are not registered by setup; add one explicitly with `dieter project open PATH`.")

	fmt.Fprintln(c.Out, "\n2. Daemon service")
	if *noStart {
		fmt.Fprintln(c.Out, serviceStartHint())
	} else if err := setupServicePreflight(c.Root); err != nil {
		return err
	} else if runtime.GOOS == "linux" {
		if err := installAndStartPlatformService(c.env.Environment, c.Root, c.Out); err != nil {
			return err
		}
	} else {
		started, startErr := restartHomebrewService(c.Err)
		if startErr != nil {
			return startErr
		}
		if !started {
			fmt.Fprintln(c.Out, "Homebrew installation not detected; run `dieter daemon start` in the foreground.")
			return nil
		}
		if err := waitForDaemon(c.Root, 20*time.Second); err != nil {
			fmt.Fprintln(c.Out, "Homebrew service started, but onboarding is not fully healthy.")
			fmt.Fprintln(c.Out)
			_ = c.daemonStatus(nil)
			return err
		}
	}
	fmt.Fprintln(c.Out, "\n3. Required screen sharing permissions")
	capabilities, capabilityErr := c.remoteDesktopCapabilities()
	if capabilityErr != nil {
		return capabilityErr
	}
	if capabilities.GetAvailability() == dieterv1.RemoteDesktopAvailability_REMOTE_DESKTOP_AVAILABILITY_UNSUPPORTED {
		fmt.Fprintf(c.Out, "Screen sharing is unsupported: %s. Other daemon features remain available.\n", capabilities.GetUnavailableReason())
	} else if err := c.ensureRemoteDesktopPermissions(false, *noOpen); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		fmt.Fprintln(c.Out, "\n4. Privacy input helper")
		if err := c.setupPrivacyHelper(*noOpen || *noStart); err != nil {
			return err
		}
	}

	fmt.Fprintln(c.Out)
	return c.daemonStatus(nil)
}

func (c *CLI) setupPrivacyHelper(skip bool) error {
	if skip {
		fmt.Fprintln(c.Out, "Skipped helper registration; run `dieter machine privacy setup` on this Mac when ready to approve it.")
		return nil
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	information, err := client.GetMachineInformation(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	privacy := information.GetPrivacy()
	if privacy.GetRequested() {
		fmt.Fprintln(c.Out, "Privacy is already requested; its helper registration is preserved.")
		return nil
	}
	if privacy.GetSupported() && !privacy.GetHelperSetupRequired() {
		fmt.Fprintln(c.Out, "Privacy input helper is already available. Privacy remains off.")
		return nil
	}
	response, err := client.PerformMachineOperation(rpcCtx, &dieterv1.MachineOperationRequest{
		Action: dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_PRIVACY_SETUP,
	})
	if err != nil {
		return fmt.Errorf("privacy helper setup: %w", err)
	}
	if !response.GetAccepted() {
		return errors.New("daemon did not accept privacy helper setup")
	}
	fmt.Fprintln(c.Out, response.GetMessage())
	return nil
}

func (c *CLI) remoteDesktopCapabilities() (*dieterv1.RemoteDesktopCapabilities, error) {
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, err
	}
	return client.GetRemoteDesktopCapabilities(rpcCtx, &emptypb.Empty{})
}

func (c *CLI) daemonPermissions(args []string) error {
	const usage = `Usage: dieter daemon permissions [--check] [--no-open]

Verify capture and input permission through the running daemon, including with
--machine ID|NAME. --check discards one encoded frame and checks event-posting
permission without injecting input or changing settings. No local fallback is
used when the daemon is unavailable. Screen sharing is always available when
the required permissions are granted. Onboarding never restarts the daemon.
`
	set := flags("daemon permissions")
	check := set.Bool("check", false, "check the running daemon without changing settings")
	noOpen := set.Bool("no-open", false, "do not open macOS System Settings or request a control prompt")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New(usage)
	}
	return c.ensureRemoteDesktopPermissions(*check, *noOpen || *check)
}

func (c *CLI) ensureRemoteDesktopPermissions(checkOnly, noOpen bool) error {
	return c.runRemoteDesktopPermissionGuide(checkOnly, noOpen)
}

func (c *CLI) runRemoteDesktopPermissionGuide(checkOnly, noOpen bool) error {
	capabilities, err := c.remoteDesktopCapabilities()
	if err != nil {
		return fmt.Errorf("running daemon capability check failed: %w", err)
	}
	if !capabilities.GetGraphicalSessionActive() || !capabilities.GetEncoderAvailable() || !capabilities.GetControlSupported() {
		return fmt.Errorf("screen sharing is unsupported: %s", capabilities.GetUnavailableReason())
	}
	reader := bufio.NewReader(c.In)
	requestControl := !checkOnly && !noOpen && (capabilities.GetPlatform() == "linux" || capabilities.GetCapturePermission() == "granted")
	for attempt := 0; attempt < 5; attempt++ {
		value, err := c.probeRemoteDesktopPermissions(requestControl)
		if err != nil {
			return fmt.Errorf("running daemon permission check failed: %w", err)
		}
		fmt.Fprintf(c.Out, "Daemon: %s\nCapture helper: %s\n", value.GetDaemonExecutable(), value.GetCaptureExecutable())
		if value.GetCaptureVerified() && value.GetControlVerified() {
			fmt.Fprintln(c.Out, "Screen capture verified by the running daemon with a disposable encoded frame; no image was saved.")
			if value.GetPlatform() == "linux" {
				fmt.Fprintln(c.Out, "Linux input backend verified without injecting input; a Wayland portal may request its device grant when a remote session starts.")
			} else {
				fmt.Fprintln(c.Out, "Input permission verified; no click, keystroke, or cursor movement was injected.")
			}
			fmt.Fprintln(c.Out, "Required screen-sharing permissions are verified. No enable switch is required.")
			return nil
		}
		requestControl = !checkOnly && !noOpen && (value.GetPlatform() == "linux" || value.GetCaptureVerified())
		reason := fmt.Sprintf("capture: %s; control: %s", value.GetCaptureError(), value.GetControlError())
		if checkOnly || attempt == 4 {
			return fmt.Errorf("daemon screen sharing is not ready: %s", reason)
		}
		if value.GetPlatform() == "linux" {
			fmt.Fprintf(c.Out, "Screen sharing is not ready: %s\nApprove the desktop portal prompt in the active Linux login, or verify the documented GStreamer/X11 dependencies.\n", reason)
		} else {
			fmt.Fprintf(c.Out, "Screen sharing is not ready: %s\nGrant the running daemon (%s) access on its Mac.\n", reason, value.GetDaemonExecutable())
		}
		for _, permission := range []struct {
			verified    bool
			title, pane string
		}{
			{value.GetCaptureVerified(), "Screen & System Audio Recording", "Privacy_ScreenCapture"},
			{value.GetControlVerified(), "Accessibility", "Privacy_Accessibility"},
		} {
			if permission.verified || value.GetPlatform() != "darwin" {
				continue
			}
			fmt.Fprintf(c.Out, "Required: Privacy & Security → %s\nEnable the running daemon listed above. If it is missing, click +, press Command-Shift-G, and paste its full path.\n", permission.title)
			if !noOpen && c.Machine == "" && runtime.GOOS == "darwin" {
				if err := exec.Command("open", "x-apple.systempreferences:com.apple.preference.security?"+permission.pane).Run(); err != nil {
					fmt.Fprintf(c.Out, "Could not open System Settings: %v\n", err)
				}
			}
			break // Guide one permission at a time, then verify through the service.
		}
		if value.GetPlatform() == "darwin" {
			fmt.Fprintln(c.Out, "If macOS requires a restart, restart the daemon service when your active work has finished, then run this check again.")
		}
		fmt.Fprint(c.Out, "After granting access, press Return to check the service again: ")
		if c.In == nil {
			return errors.New("permission onboarding requires input; use --check for non-interactive diagnostics")
		}
		if _, err := reader.ReadString('\n'); err != nil {
			return errors.New("permission change was not confirmed")
		}
	}
	return errors.New("daemon permissions remain unavailable")
}

func (c *CLI) probeRemoteDesktopPermissions(requestControl bool) (*dieterv1.RemoteDesktopPermissionProbe, error) {
	timeout := c.connectionTimeout()
	if runtime.GOOS == "linux" && c.Timeout <= 0 {
		timeout = 170 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, err
	}
	return client.ProbeRemoteDesktopPermissions(rpcCtx, &dieterv1.ProbeRemoteDesktopPermissionsRequest{RequestControl: requestControl})
}

func restartHomebrewService(output io.Writer) (bool, error) {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return false, nil
	}
	brew, err := exec.LookPath("brew")
	if err != nil {
		return false, nil
	}
	if err := exec.Command(brew, "list", "--formula", "dieter").Run(); err != nil {
		return false, nil
	}
	command := exec.Command(brew, "services", "restart", "dieter")
	command.Stdout, command.Stderr = output, output
	if err := command.Run(); err != nil {
		return true, fmt.Errorf("restart Homebrew service: %w", err)
	}
	return true, nil
}

func setupServicePreflight(root string) error {
	status, err := link.LoadRuntimeStatus(root)
	if err == nil && link.RuntimeStatusCurrent(status, time.Now().UTC()) && !status.ServiceManaged && daemonHealth(root, status.ListenAddress) {
		return fmt.Errorf("foreground Dieter daemon (pid %d) is already running; stop it in its terminal with Ctrl-C, then rerun `dieter setup` so the managed service can load the enrollment", status.PID)
	}
	return nil
}

func setupDaemonReady(status link.RuntimeStatus, identity *link.Identity) bool {
	return status.ServiceManaged && status.Enrolled && status.DaemonID == identity.ID &&
		status.GatewayURL == identity.GatewayURL && status.GatewayState == link.GatewayConnected
}

func waitForDaemon(root string, timeout time.Duration) error {
	identity, err := link.LoadIdentity(root)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(timeout)
	var last link.RuntimeStatus
	for time.Now().Before(deadline) {
		status, err := link.LoadRuntimeStatus(root)
		if err == nil {
			last = status
		}
		if err == nil && link.RuntimeStatusCurrent(status, time.Now().UTC()) && daemonHealth(root, status.ListenAddress) {
			if setupDaemonReady(status, identity) {
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	if last.GatewayState != "" && daemonHealth(root, last.ListenAddress) {
		if !last.ServiceManaged || !last.Enrolled || last.DaemonID != identity.ID || last.GatewayURL != identity.GatewayURL {
			return errors.New("daemon local API is healthy, but the managed service has not loaded the expected enrollment; stop any foreground daemon and rerun `dieter setup`")
		}
		if last.GatewayLastError != "" {
			return fmt.Errorf("daemon local API is healthy, but the gateway is %s: %s", last.GatewayState, last.GatewayLastError)
		}
		return fmt.Errorf("daemon local API is healthy, but the gateway is %s", last.GatewayState)
	}
	return errors.New("daemon did not become healthy within 20 seconds; run `dieter daemon logs` for details")
}
