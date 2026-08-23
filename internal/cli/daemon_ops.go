package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/app"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/model"
)

const (
	daemonLogLimit   = 10 << 20
	daemonLogBackups = 3
)

type rotatingLogWriter struct {
	mu   sync.Mutex
	path string
	file *os.File
	size int64
}

func openRotatingLog(path string) (*rotatingLogWriter, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	writer := &rotatingLogWriter{path: path}
	if err := writer.open(); err != nil {
		return nil, err
	}
	return writer, nil
}

func (w *rotatingLogWriter) open() error {
	file, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return err
	}
	w.file, w.size = file, info.Size()
	return nil
}

func (w *rotatingLogWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.size+int64(len(data)) > daemonLogLimit {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	written, err := w.file.Write(data)
	w.size += int64(written)
	return written, err
}

func (w *rotatingLogWriter) rotate() error {
	if err := w.file.Close(); err != nil {
		return err
	}
	for index := daemonLogBackups; index >= 1; index-- {
		destination := fmt.Sprintf("%s.%d", w.path, index)
		if index == daemonLogBackups {
			_ = os.Remove(destination)
		}
		source := w.path
		if index > 1 {
			source = fmt.Sprintf("%s.%d", w.path, index-1)
		}
		if err := os.Rename(source, destination); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	w.file, w.size = nil, 0
	return w.open()
}

func (w *rotatingLogWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	return w.file.Close()
}

func daemonLogger(root string, serviceMode, verbose bool, stderr io.Writer) (*slog.Logger, string, func(), error) {
	level := slog.LevelInfo
	if verbose {
		level = slog.LevelDebug
	}
	if !serviceMode {
		return slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level})), "", func() {}, nil
	}
	path := dieterdaemon.LogPath(root)
	writer, err := openRotatingLog(path)
	if err != nil {
		return nil, "", nil, err
	}
	logger := slog.New(slog.NewTextHandler(writer, &slog.HandlerOptions{Level: level}))
	return logger, path, func() { _ = writer.Close() }, nil
}

func runStatusHeartbeat(ctx context.Context, writer *dieterdaemon.StatusWriter) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = writer.Touch()
		}
	}
}

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
		Status: "stopped", Service: "foreground", Store: c.Store.Root,
		ListenAddress: "127.0.0.1:4242", LogPath: dieterdaemon.LogPath(c.Store.Root),
		GatewayState: dieterdaemon.GatewayNotEnrolled,
	}
	identity, identityErr := dieterdaemon.LoadIdentity(c.Store.Root)
	if identityErr == nil {
		view.Enrolled = identity.Enrolled()
		view.DaemonID, view.DaemonName = identity.ID, identity.Name
		view.GatewayURL = identity.GatewayURL
		view.CertificateExpiresAt = identity.CertificateExpiresAt
		if view.Enrolled {
			view.GatewayState = dieterdaemon.GatewayDisconnected
		}
	} else if !errors.Is(identityErr, os.ErrNotExist) {
		return identityErr
	}

	runtimeStatus, runtimeErr := dieterdaemon.LoadRuntimeStatus(c.Store.Root)
	if runtimeErr == nil {
		view.PID, view.Version, view.StartedAt = runtimeStatus.PID, runtimeStatus.Version, runtimeStatus.StartedAt
		view.ListenAddress = runtimeStatus.ListenAddress
		view.GatewayState = runtimeStatus.GatewayState
		view.GatewayConnectedAt = runtimeStatus.GatewayConnectedAt
		view.GatewayLastError = runtimeStatus.GatewayLastError
		if runtimeStatus.LogPath != "" {
			view.LogPath = runtimeStatus.LogPath
		}
		if runtimeStatus.ServiceManaged {
			view.Service = "homebrew"
			view.ServiceStatus = homebrewServiceStatus()
		}
	} else if !dieterdaemon.IsRuntimeStatusMissing(runtimeErr) {
		return runtimeErr
	}
	view.APIHealthy = daemonHealth(view.ListenAddress)
	view.Running = view.APIHealthy && runtimeErr == nil && dieterdaemon.RuntimeStatusCurrent(runtimeStatus, time.Now().UTC())
	if view.Running {
		switch {
		case !view.Enrolled:
			view.Status = "local-only"
		case view.GatewayState == dieterdaemon.GatewayConnected:
			view.Status = "healthy"
		default:
			view.Status = "degraded"
		}
	} else if view.APIHealthy {
		view.Status = "unmanaged"
	}
	projects, _ := c.Store.ListProjects()
	view.Projects = len(projects)
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

func daemonHealth(address string) bool {
	if strings.TrimSpace(address) == "" {
		return false
	}
	client := &http.Client{Timeout: 1200 * time.Millisecond}
	response, err := client.Get("http://" + address + "/healthz")
	if err != nil {
		return false
	}
	defer response.Body.Close()
	return response.StatusCode == http.StatusOK
}

func homebrewServiceStatus() string {
	brew, err := exec.LookPath("brew")
	if err != nil {
		return "unknown"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(ctx, brew, "services", "info", "--all", "--json").Output()
	if err != nil {
		return "unknown"
	}
	var items []struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	}
	if json.Unmarshal(raw, &items) != nil {
		return "unknown"
	}
	for _, item := range items {
		if item.Name == "dieter" {
			return item.Status
		}
	}
	return "not registered"
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
	path := dieterdaemon.LogPath(c.Store.Root)
	if runtimeStatus, statusErr := dieterdaemon.LoadRuntimeStatus(c.Store.Root); statusErr == nil && runtimeStatus.LogPath != "" {
		path = runtimeStatus.LogPath
	}
	return streamLog(c.Out, path, *lines, *follow)
}

func streamLog(out io.Writer, path string, lines int, follow bool) error {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("daemon log %q does not exist; start the Homebrew service first", path)
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
	const usage = `Usage: dieter setup [--gateway URL] [--name NAME] [--no-open] [--no-start] [PROJECT_PATH...]

Authorize this machine with GitHub, register Git projects, and start the
Homebrew-managed daemon. With no path, the current Git working tree is used.
`
	set := flags("setup")
	gatewayURL := set.String("gateway", "https://board.dbpprt.com", "gateway origin")
	hostname, _ := os.Hostname()
	name := set.String("name", hostname, "machine display name")
	noOpen := set.Bool("no-open", false, "do not open the verification URL")
	noStart := set.Bool("no-start", false, "do not start or restart the Homebrew service")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}

	identity, identityErr := dieterdaemon.LoadIdentity(c.Store.Root)
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

	paths := set.Args()
	if len(paths) == 0 {
		cwd, cwdErr := os.Getwd()
		if cwdErr == nil {
			if root, rootErr := gitWorkingTreeRoot(cwd); rootErr == nil {
				paths = []string{root}
			}
		}
	}
	fmt.Fprintln(c.Out, "\n2. Project registration")
	if len(paths) == 0 {
		fmt.Fprintln(c.Out, "No Git project supplied; add one later with `dieter project open PATH`.")
	}
	for _, path := range paths {
		project, existing, registerErr := c.setupProject(path)
		if registerErr != nil {
			return registerErr
		}
		label := "Registered"
		if existing {
			label = "Already registered"
		}
		fmt.Fprintf(c.Out, "%s %s (%s).\n", label, project.Path, project.ID)
	}

	fmt.Fprintln(c.Out, "\n3. Daemon service")
	if *noStart {
		fmt.Fprintln(c.Out, "Skipped; start it with `brew services start dieter`.")
		return nil
	}
	started, startErr := restartHomebrewService(c.Err)
	if startErr != nil {
		return startErr
	}
	if !started {
		fmt.Fprintln(c.Out, "Homebrew installation not detected; run `dieter daemon start` in the foreground.")
		return nil
	}
	if err := waitForDaemon(c.Store.Root, 20*time.Second); err != nil {
		fmt.Fprintln(c.Out, "Homebrew service started, but onboarding is not fully healthy.")
		fmt.Fprintln(c.Out)
		_ = c.daemonStatus(nil)
		return err
	}
	fmt.Fprintln(c.Out, "Homebrew service started.")
	fmt.Fprintln(c.Out)
	return c.daemonStatus(nil)
}

func (c *CLI) setupProject(path string) (model.Project, bool, error) {
	absolute, err := gitWorkingTreeRoot(path)
	if err != nil {
		return model.Project{}, false, err
	}
	active, err := c.Store.ListProjects()
	if err != nil {
		return model.Project{}, false, err
	}
	archived, err := c.Store.ListArchivedProjects()
	if err != nil {
		return model.Project{}, false, err
	}
	for _, project := range append(active, archived...) {
		if project.Path == absolute {
			return project, true, nil
		}
	}
	project, err := c.service().RegisterProject(context.Background(), app.ProjectInput{Path: absolute})
	return project, false, err
}

func gitWorkingTreeRoot(path string) (string, error) {
	absolute, err := filepath.Abs(strings.TrimSpace(path))
	if err != nil {
		return "", err
	}
	if resolved, resolveErr := filepath.EvalSymlinks(absolute); resolveErr == nil {
		absolute = resolved
	}
	command := exec.Command("git", "-C", absolute, "rev-parse", "--show-toplevel")
	raw, err := command.CombinedOutput()
	if err != nil {
		message := strings.TrimSpace(string(raw))
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("project path %q must be inside an existing Git working tree: %s", path, message)
	}
	root := strings.TrimSpace(string(raw))
	if resolved, resolveErr := filepath.EvalSymlinks(root); resolveErr == nil {
		root = resolved
	}
	return filepath.Clean(root), nil
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

func waitForDaemon(root string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var last dieterdaemon.RuntimeStatus
	for time.Now().Before(deadline) {
		status, err := dieterdaemon.LoadRuntimeStatus(root)
		if err == nil {
			last = status
		}
		if err == nil && dieterdaemon.RuntimeStatusCurrent(status, time.Now().UTC()) && daemonHealth(status.ListenAddress) {
			if !status.Enrolled || status.GatewayState == dieterdaemon.GatewayConnected {
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	if last.GatewayState != "" && daemonHealth(last.ListenAddress) {
		if last.GatewayLastError != "" {
			return fmt.Errorf("daemon local API is healthy, but the gateway is %s: %s", last.GatewayState, last.GatewayLastError)
		}
		return fmt.Errorf("daemon local API is healthy, but the gateway is %s", last.GatewayState)
	}
	return errors.New("daemon did not become healthy within 20 seconds; run `dieter daemon logs` for details")
}
