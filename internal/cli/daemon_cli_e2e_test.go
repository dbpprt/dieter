package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/controlrtc"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/machine"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func initTestRepository(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if output, err := exec.Command("git", "init", "-b", "main", path).CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	if err := os.WriteFile(filepath.Join(path, "README.md"), []byte("initial\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{"user.name": "Dieter Test", "user.email": "dieter@example.test"} {
		if output, err := exec.Command("git", "-C", path, "config", key, value).CombinedOutput(); err != nil {
			t.Fatalf("git config %s: %s: %v", key, output, err)
		}
	}
	return path
}

func daemonCLIForTest(t *testing.T) (*CLI, *bytes.Buffer, *store.Store) {
	t.Helper()
	root := t.TempDir()
	data := store.New(root)
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	application := server.NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), &fakeRunner{})
	host := httptest.NewServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := dieterdaemon.NewStatusWriter(root, dieterdaemon.RuntimeStatus{
		PID: os.Getpid(), Version: "test", State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"), GatewayState: dieterdaemon.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}
	output := &bytes.Buffer{}
	client := New(data)

	client.Timeout = 10 * time.Second
	client.Out, client.Err = output, output
	t.Cleanup(client.Close)
	return client, output, data
}

func runDaemonCLI(t *testing.T, client *CLI, output *bytes.Buffer, args ...string) string {
	t.Helper()
	output.Reset()
	if err := client.Run(args); err != nil {
		t.Fatalf("dieter %s: %v\n%s", strings.Join(args, " "), err, output.String())
	}
	return output.String()
}

func TestDaemonCLIControlsLocalDaemonEndToEnd(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	client, output, data := daemonCLIForTest(t)
	repository := initTestRepository(t, "first")
	createdJSON := runDaemonCLI(t, client, output, "project", "open", "--name", "CLI fixture", "--format", "json", repository)
	var created struct {
		Project struct {
			ID string `json:"id"`
		} `json:"project"`
		Board struct {
			ID string `json:"id"`
		} `json:"board"`
	}
	if err := json.Unmarshal([]byte(createdJSON), &created); err != nil || created.Project.ID == "" || created.Board.ID == "" {
		t.Fatalf("created project JSON=%q err=%v", createdJSON, err)
	}

	boardJSON := runDaemonCLI(t, client, output, "board", "git", "--base-remote", "private", "--remote-publish", "pull_request", created.Board.ID)
	var configuredBoard struct {
		BaseRemote        string `json:"baseRemote"`
		RemotePublishMode string `json:"remotePublishMode"`
	}
	if err := json.Unmarshal([]byte(boardJSON), &configuredBoard); err != nil || configuredBoard.BaseRemote != "private" || configuredBoard.RemotePublishMode != "pull_request" {
		t.Fatalf("configured board JSON=%q parsed=%#v err=%v", boardJSON, configuredBoard, err)
	}
	runDaemonCLI(t, client, output, "board", "label", "add", "--board", created.Board.ID, "--name", "CLI", "--instructions", "Keep the CLI current")
	cardJSON := runDaemonCLI(t, client, output, "card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--lane", "todo", "--title", "Daemon parity", "--prompt", "Exercise the API", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var card struct {
		ID                  string `json:"id"`
		OwnerDaemonID       string `json:"ownerDaemonId"`
		CheckoutID          string `json:"checkoutId"`
		WorkspaceBaseRemote string `json:"workspaceBaseRemote"`
		RemotePublishMode   string `json:"remotePublishMode"`
	}
	if err := json.Unmarshal([]byte(cardJSON), &card); err != nil || card.ID == "" || card.WorkspaceBaseRemote != "private" || card.RemotePublishMode != "pull_request" {
		t.Fatalf("created card JSON=%q err=%v", cardJSON, err)
	}
	localProject, err := data.ResolveProject(created.Project.ID)
	if err != nil || len(localProject.Checkouts) != 1 {
		t.Fatalf("local project=%+v err=%v", localProject, err)
	}
	localCheckout := localProject.Checkouts[0]
	if card.OwnerDaemonID != localCheckout.DaemonID || card.CheckoutID != localCheckout.ID {
		t.Fatalf("card owner=%q checkout=%q, want local owner=%q checkout=%q", card.OwnerDaemonID, card.CheckoutID, localCheckout.DaemonID, localCheckout.ID)
	}
	chatJSON := runDaemonCLI(t, client, output, "chat", "create", "--project", created.Project.ID, "--title", "Local chat", "--prompt", "Use this machine", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var chat struct {
		ID            string `json:"id"`
		OwnerDaemonID string `json:"ownerDaemonId"`
		CheckoutID    string `json:"checkoutId"`
	}
	if err := json.Unmarshal([]byte(chatJSON), &chat); err != nil || chat.ID == "" || chat.OwnerDaemonID != localCheckout.DaemonID || chat.CheckoutID != localCheckout.ID {
		t.Fatalf("created local chat JSON=%q parsed=%#v err=%v", chatJSON, chat, err)
	}
	quickJSON := runDaemonCLI(t, client, output, "card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--lane", "todo", "--auto-title", "--prompt", "Add keyboard navigation", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var quick struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(quickJSON), &quick); err != nil || quick.ID == "" || quick.Title != "Add keyboard navigation" {
		t.Fatalf("quick task JSON=%q parsed=%#v err=%v", quickJSON, quick, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		var detail dieterv1.CardDetail
		raw := runDaemonCLI(t, client, output, "card", "show", quick.ID)
		if err := protojson.Unmarshal([]byte(raw), &detail); err != nil {
			t.Fatal(err)
		}
		if detail.GetCard().GetTitle() == "Add Keyboard Board Navigation" {
			if detail.GetCard().GetId() != quick.ID {
				t.Fatal("generated title changed the task ID")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("background title was not saved: %s", raw)
		}
		time.Sleep(10 * time.Millisecond)
	}
	runDaemonCLI(t, client, output, "workspace", "show", card.ID)
	changesJSON := runDaemonCLI(t, client, output, "workspace", "changes", "--project", created.Project.ID)
	var projectChanges struct {
		ProjectID string `json:"projectId"`
		Revision  string `json:"revision"`
		Files     []struct {
			Path     string `json:"path"`
			Unstaged bool   `json:"unstaged"`
		} `json:"files"`
	}
	if err := json.Unmarshal([]byte(changesJSON), &projectChanges); err != nil || projectChanges.ProjectID != created.Project.ID || projectChanges.Revision == "" || len(projectChanges.Files) != 1 || projectChanges.Files[0].Path != "README.md" || !projectChanges.Files[0].Unstaged {
		t.Fatalf("project changes JSON=%q value=%#v err=%v", changesJSON, projectChanges, err)
	}
	runDaemonCLI(t, client, output, "workspace", "diff", "--project", created.Project.ID, "--path", "README.md", "--section", "unstaged", "--revision", projectChanges.Revision)
	runDaemonCLI(t, client, output, "workspace", "run", "--project", created.Project.ID, "--kind", "stage", "--revision", projectChanges.Revision, "--param", "path=README.md", "--wait")
	changesJSON = runDaemonCLI(t, client, output, "workspace", "changes", "--project", created.Project.ID)
	if err := json.Unmarshal([]byte(changesJSON), &projectChanges); err != nil || projectChanges.Revision == "" {
		t.Fatalf("staged project changes JSON=%q err=%v", changesJSON, err)
	}
	runDaemonCLI(t, client, output, "workspace", "run", "--project", created.Project.ID, "--kind", "commit", "--revision", projectChanges.Revision, "--param", "subject=initial project commit", "--param", "validate=false", "--wait")

	runDaemonCLI(t, client, output, "file", "create", "--project", created.Project.ID, "--content", "one\n", "notes.txt")
	if got := runDaemonCLI(t, client, output, "file", "read", "--project", created.Project.ID, "notes.txt"); got != "one\n" {
		t.Fatalf("file content=%q", got)
	}
	runDaemonCLI(t, client, output, "file", "save", "--project", created.Project.ID, "--content", "two\n", "notes.txt")
	runDaemonCLI(t, client, output, "file", "move", "--project", created.Project.ID, "notes.txt", "moved.txt")
	runDaemonCLI(t, client, output, "file", "delete", "--project", created.Project.ID, "moved.txt")

	runDaemonCLI(t, client, output, "schedule", "preview", "--cron", "0 9 * * 1-5", "--timezone", "UTC", "--count", "2")
	scheduleJSON := runDaemonCLI(t, client, output, "schedule", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--name", "CLI daily", "--cron", "0 9 * * 1-5", "--timezone", "UTC", "--title", "Daily CLI", "--prompt", "Check parity", "--provider", "mock", "--model", "mock")
	var schedule struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(scheduleJSON), &schedule); err != nil || schedule.ID == "" {
		t.Fatalf("created schedule JSON=%q err=%v", scheduleJSON, err)
	}
	runDaemonCLI(t, client, output, "schedule", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--name", "CLI hourly", "--cron", "0 * * * *", "--timezone", "UTC", "--title", "Hourly CLI", "--prompt", "Check pagination", "--provider", "mock", "--model", "mock")
	var schedulePage struct {
		Schedules []struct {
			ID string `json:"id"`
		} `json:"schedules"`
		NextPageToken string `json:"nextPageToken"`
		TotalCount    int    `json:"totalCount"`
	}
	pageJSON := runDaemonCLI(t, client, output, "schedule", "list", "--project", created.Project.ID, "--page-size", "1", "--format", "json")
	if err := json.Unmarshal([]byte(pageJSON), &schedulePage); err != nil || len(schedulePage.Schedules) != 1 || schedulePage.TotalCount != 2 || schedulePage.NextPageToken == "" {
		t.Fatalf("first schedule page=%q parsed=%#v err=%v", pageJSON, schedulePage, err)
	}
	pageJSON = runDaemonCLI(t, client, output, "schedule", "list", "--project", created.Project.ID, "--page-size", "1", "--page-token", schedulePage.NextPageToken, "--format", "json")
	schedulePage.NextPageToken = ""
	if err := json.Unmarshal([]byte(pageJSON), &schedulePage); err != nil || len(schedulePage.Schedules) != 1 || schedulePage.NextPageToken != "" {
		t.Fatalf("second schedule page=%q parsed=%#v err=%v", pageJSON, schedulePage, err)
	}
	runDaemonCLI(t, client, output, "schedule", "pause", schedule.ID)
	runDaemonCLI(t, client, output, "schedule", "run", schedule.ID)
	runDaemonCLI(t, client, output, "schedule", "run", schedule.ID)
	runDaemonCLI(t, client, output, "schedule", "delete", schedule.ID)
	var runPage struct {
		Runs []struct {
			ID string `json:"id"`
		} `json:"runs"`
		NextPageToken string `json:"nextPageToken"`
	}
	runsJSON := runDaemonCLI(t, client, output, "schedule", "runs", "--page-size", "1", schedule.ID)
	if err := json.Unmarshal([]byte(runsJSON), &runPage); err != nil || len(runPage.Runs) != 1 || runPage.NextPageToken == "" {
		t.Fatalf("first run page=%q parsed=%#v err=%v", runsJSON, runPage, err)
	}
	runsJSON = runDaemonCLI(t, client, output, "schedule", "runs", "--page-size", "1", "--page-token", runPage.NextPageToken, schedule.ID)
	runPage.NextPageToken = ""
	if err := json.Unmarshal([]byte(runsJSON), &runPage); err != nil || len(runPage.Runs) != 1 || runPage.NextPageToken != "" {
		t.Fatalf("second run page=%q parsed=%#v err=%v", runsJSON, runPage, err)
	}

	terminalJSON := runDaemonCLI(t, client, output, "terminal", "create", "--project", created.Project.ID, "--name", "CLI shell", "--shell", "sh")
	var terminal struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(terminalJSON), &terminal); err != nil || terminal.ID == "" {
		t.Fatalf("created terminal JSON=%q err=%v", terminalJSON, err)
	}
	runDaemonCLI(t, client, output, "terminal", "write", "--data", "printf 'cli-terminal-ok\\n'\n", terminal.ID)
	runDaemonCLI(t, client, output, "terminal", "resize", "--columns", "100", "--rows", "30", terminal.ID)
	runDaemonCLI(t, client, output, "terminal", "rename", "--name", "renamed", terminal.ID)
	runDaemonCLI(t, client, output, "terminal", "close", terminal.ID)
	homeTerminalJSON := runDaemonCLI(t, client, output, "terminal", "create", "--home", "--name", "Home shell", "--shell", "sh")
	var homeTerminal struct {
		ID        string `json:"id"`
		ProjectID string `json:"projectId"`
	}
	if err := json.Unmarshal([]byte(homeTerminalJSON), &homeTerminal); err != nil || homeTerminal.ID == "" || homeTerminal.ProjectID != "" {
		t.Fatalf("created machine-home terminal JSON=%q parsed=%#v err=%v", homeTerminalJSON, homeTerminal, err)
	}
	runDaemonCLI(t, client, output, "terminal", "close", homeTerminal.ID)

	remoteOutput := runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--input", "agent-input\n", "--", "/bin/sh", "-c", "read value; printf 'stdout:%s' \"$value\"; printf ':stderr' >&2")
	if !strings.Contains(remoteOutput, "stdout:agent-input") || !strings.Contains(remoteOutput, ":stderr") {
		t.Fatalf("remote execution output=%q", remoteOutput)
	}
	remoteID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--detach", "--format", "id", "--idempotency-key", "cli-e2e", "--", "/bin/sh", "-c", "printf detached"))
	if !strings.HasPrefix(remoteID, "exec_") {
		t.Fatalf("remote execution id=%q", remoteID)
	}
	repeatedID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--detach", "--format", "id", "--idempotency-key", "cli-e2e", "--", "/bin/sh", "-c", "printf detached"))
	if repeatedID != remoteID {
		t.Fatalf("idempotent remote IDs %q != %q", repeatedID, remoteID)
	}
	runDaemonCLI(t, client, output, "remote", "wait", remoteID)
	shown := runDaemonCLI(t, client, output, "remote", "show", remoteID)
	var shownExecution struct {
		ExitCode int32 `json:"exitCode"`
	}
	if err := json.Unmarshal([]byte(shown), &shownExecution); err != nil || shownExecution.ExitCode != 0 {
		t.Fatalf("remote show=%s err=%v", shown, err)
	}
	runDaemonCLI(t, client, output, "remote", "close", remoteID)
	output.Reset()
	remoteErr := client.Run([]string{"remote", "exec", "--project", created.Project.ID, "--", "/bin/sh", "-c", "exit 23"})
	var exitErr *remoteExitError
	if !errors.As(remoteErr, &exitErr) || exitErr.Code() != 23 {
		t.Fatalf("remote exit error=%v code=%d", remoteErr, exitErr.Code())
	}
	watchID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--detach", "--format", "id", "--", "/usr/bin/printf", "watch-marker"))
	if watched := runDaemonCLI(t, client, output, "remote", "watch", watchID); watched != "watch-marker" {
		t.Fatalf("remote watch output=%q", watched)
	}
	if listed := runDaemonCLI(t, client, output, "remote", "list", "--project", created.Project.ID, "--format", "ids"); !strings.Contains(listed, watchID) {
		t.Fatalf("remote list=%q", listed)
	}
	runDaemonCLI(t, client, output, "remote", "close", watchID)

	shellID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "shell", "--project", created.Project.ID, "--detach", "--format", "id"))
	runDaemonCLI(t, client, output, "remote", "resize", "--columns", "101", "--rows", "37", shellID)
	runDaemonCLI(t, client, output, "remote", "input", "--data", "stty size; printf 'shell-marker'; exit\n", shellID)
	if shellOutput := runDaemonCLI(t, client, output, "remote", "wait", shellID); !strings.Contains(shellOutput, "37 101") || !strings.Contains(shellOutput, "shell-marker") {
		t.Fatalf("remote shell output=%q", shellOutput)
	}
	runDaemonCLI(t, client, output, "remote", "close", shellID)

	attachID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--keep-input", "--detach", "--format", "id", "--", "/bin/sh", "-c", "read value; printf 'attach:%s' \"$value\""))
	previousInput := client.In
	client.In = strings.NewReader("native\n")
	attached := runDaemonCLI(t, client, output, "remote", "attach", attachID)
	client.In = previousInput
	if !strings.Contains(attached, "attach:native") {
		t.Fatalf("remote attach output=%q", attached)
	}
	runDaemonCLI(t, client, output, "remote", "close", attachID)

	signalID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--keep-input", "--detach", "--format", "id", "--", "/bin/sh", "-c", "sleep 10"))
	runDaemonCLI(t, client, output, "remote", "signal", "--signal", "kill", signalID)
	runDaemonCLI(t, client, output, "remote", "close", signalID)
	cancelID := strings.TrimSpace(runDaemonCLI(t, client, output, "remote", "exec", "--project", created.Project.ID, "--keep-input", "--detach", "--format", "id", "--", "/bin/sh", "-c", "sleep 10"))
	runDaemonCLI(t, client, output, "remote", "cancel", cancelID)
	runDaemonCLI(t, client, output, "remote", "close", cancelID)

	runDaemonCLI(t, client, output, "settings", "show")
	runDaemonCLI(t, client, output, "prompt", "show")
	runDaemonCLI(t, client, output, "prompt", "preview", "--card", card.ID)
	runDaemonCLI(t, client, output, "screen", "capabilities")

	assertProjectHostnameCLI(t, client, output, created.Project.ID)
	relocated := initTestRepository(t, "relocated")
	updated := runDaemonCLI(t, client, output, "project", "update", "--path", relocated, created.Project.ID)
	if !strings.Contains(updated, filepath.Base(relocated)) {
		t.Fatalf("relocated project response=%s", updated)
	}
	runDaemonCLI(t, client, output, "machine", "info")
	statusJSON := runDaemonCLI(t, client, output, "status", "--format", "json")
	if !strings.Contains(statusJSON, `"route": "local"`) {
		t.Fatalf("status did not use local daemon transport: %s", statusJSON)
	}
}

func TestOperationalCLINeverFallsBackToDirectStorage(t *testing.T) {
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	repository := initTestRepository(t, "stored-only")
	if _, err := data.CreateProject(store.CreateProjectInput{Name: "Must remain hidden", Path: repository}); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	client := New(data)

	client.Out, client.Err = &output, &output
	err := client.Run([]string{"project", "list", "--format", "json"})
	if err == nil || !strings.Contains(err.Error(), "local Dieter daemon is not running") {
		t.Fatalf("project list error=%v output=%q", err, output.String())
	}
	if strings.Contains(output.String(), "Must remain hidden") {
		t.Fatalf("daemon-mode CLI read the store directly: %q", output.String())
	}
}

func TestDaemonCLIUsesDirectRouteThenRelayFallback(t *testing.T) { testDaemonRoutes(t, false) }
func TestDaemonCLIUsesWebRTCControlAndFallback(t *testing.T)     { testDaemonRoutes(t, true) }
func testDaemonRoutes(t *testing.T, withRTC bool) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	gatewayListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayListener.Close()
	publicURL, _ := url.Parse("http://" + gatewayListener.Addr().String())
	issuerURL, _ := url.Parse("https://durable-gateway.example.test")
	configuration := gateway.Config{IssuerURL: issuerURL, Root: t.TempDir(), Address: gatewayListener.Addr().String(), PublicURL: publicURL, GitHubClientID: "test", GitHubSecret: "test", AllowedUserIDs: map[int64]struct{}{42: {}}, AuthSecret: []byte("0123456789abcdef0123456789abcdef"), SessionTTL: time.Hour, NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid", DevInsecure: true}
	gatewayStore, err := gateway.OpenStore(configuration.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayStore.Close()
	gatewayServer, err := gateway.NewServer(configuration, gatewayStore, logger)
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = gatewayServer.Serve(gatewayListener) }()

	identityRoot := t.TempDir()
	identity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(identityRoot, "CLI remote", publicURL.String())
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := dieterdaemon.BeginEnrollment(ctx, identity)
	if err != nil {
		t.Fatal(err)
	}
	if err := gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), int64(42), "owner"); err != nil {
		t.Fatal(err)
	}
	credential, err := dieterdaemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
	if err != nil {
		t.Fatal(err)
	}
	identity.GatewayIssuer = credential.GetGatewayIssuer()
	if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
		t.Fatal(err)
	}

	remoteStore := store.New(t.TempDir())
	if err := remoteStore.Ensure(); err != nil {
		t.Fatal(err)
	}
	remoteRepository := initTestRepository(t, "remote-route")
	remoteProject, err := remoteStore.CreateProject(store.CreateProjectInput{Name: "Remote route", Path: remoteRepository})
	if err != nil {
		t.Fatal(err)
	}
	localListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	powerActions := make(chan machine.Operation, 2)
	screenManager := remotedesktop.New(remotedesktop.Options{
		Identity: remotedesktop.Identity{DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation, PrivateKey: identity.PrivateKey, GatewaySigningPublicKey: identity.GatewaySigningPublicKey},
		Source:   remotedesktop.SourceOptions{Kind: "synthetic"},
		SourceFactory: func(remotedesktop.SourceOptions) (remotedesktop.FrameSource, error) {
			return &configurableScreenFixture{}, nil
		},
	})
	defer screenManager.Shutdown(context.Background())
	var control *controlrtc.Manager
	if withRTC {
		transport, err := newDaemonDirectRoute(identity, localListener.Addr().String(), "control-tls", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
		if err != nil {
			t.Fatal(err)
		}
		go func() { _ = transport.server.Serve(transport.listener) }()
		defer transport.server.Stop()
		control = controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation, GatewaySigningPublicKey: identity.GatewaySigningPublicKey}, transport.listener.Addr().String())
		defer control.Close()
	}
	remoteServer := server.NewWithOptions(remoteStore, logger, server.Options{
		ControlRTC:    control,
		RemoteDesktop: screenManager,
		Runner:        &fakeRunner{},
		MachineAction: func(_ context.Context, operation machine.Operation) error {
			powerActions <- operation
			return nil
		},
		MachineCapabilities: func(context.Context) []machine.OperationCapability {
			return []machine.OperationCapability{
				{Operation: machine.OperationRestart, Supported: true, Authorized: true},
				{Operation: machine.OperationShutdown, Supported: true, Authorized: true},
				{Operation: machine.OperationUpdate, Supported: true, Authorized: true},
			}
		},
	})
	remoteHTTP := &http.Server{Handler: remoteServer.Handler()}
	go func() { _ = remoteHTTP.Serve(localListener) }()
	defer remoteHTTP.Close()

	directRoute, err := newDaemonDirectRoute(identity, localListener.Addr().String(), "cli-e2e", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = directRoute.server.Serve(directRoute.listener) }()
	directClosed := false
	defer func() {
		if !directClosed {
			directRoute.server.Stop()
			_ = directRoute.listener.Close()
		}
	}()
	tunnel := &dieterdaemon.GatewayClient{ControlWebRTC: withRTC, Identity: identity, LocalTarget: localListener.Addr().String(), Version: "test", APIVersion: server.APIVersion, Routes: []*gatewayv1.DirectCandidate{directRoute.candidate}, Log: logger}
	go func() { _ = tunnel.Run(ctx) }()
	deadline := time.Now().Add(5 * time.Second)
	for !gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("isolated daemon did not connect to isolated gateway")
	}

	cliStore := store.New(identityRoot)
	if err := cliStore.Ensure(); err != nil {
		t.Fatal(err)
	}
	first := New(cliStore)
	first.Machine, first.GatewayURL = identity.ID, publicURL.String()
	first.Timeout = 10 * time.Second
	var firstOutput bytes.Buffer
	first.Out, first.Err = &firstOutput, &firstOutput
	if err := first.Run([]string{"status"}); err != nil {
		t.Fatal(err)
	}
	if first.transport == nil || first.transport.route != "direct" {
		t.Fatalf("route=%#v want direct", first.transport)
	}
	if withRTC {
		first.Close()
		directRoute.server.Stop()
		_ = directRoute.listener.Close()
		directClosed = true
		peer := New(cliStore)
		defer peer.Close()
		peer.Machine, peer.GatewayURL = identity.ID, publicURL.String()
		peer.Timeout = 20 * time.Second
		var output bytes.Buffer
		peer.Out, peer.Err = &output, &output
		if err := peer.Run([]string{"status"}); err != nil {
			t.Fatal(err)
		}
		if peer.transport.route != "webrtc-direct" {
			t.Fatalf("want WebRTC, got %s", peer.transport.route)
		}
		assertSyncCursorCLI(t, peer, &output)
		assertMachineHomeTerminalCLI(t, peer, &output)
		output.Reset()
		if err := peer.Run([]string{"project", "update", "--hostname", "rtc.example", remoteProject.ID}); err != nil {
			t.Fatal(err)
		}
		output.Reset()
		if err := peer.Run([]string{"project", "show", remoteProject.ID}); err != nil || !strings.Contains(output.String(), "rtc.example") {
			t.Fatalf("RTC mutation/read: %q %v", output.String(), err)
		}
		output.Reset()
		if err := peer.Run([]string{"remote", "exec", "--project", remoteProject.ID, "--", "/usr/bin/printf", "rtc-exec"}); err != nil || output.String() != "rtc-exec" {
			t.Fatalf("RTC execution: %q %v", output.String(), err)
		}
		configuration, err := peer.gateway.client.GetRTCConfiguration(ctx, &gatewayv1.DaemonRef{DaemonId: identity.ID})
		if err != nil {
			t.Fatal(err)
		}
		// Exercise the explicit CLI signaling operations over the active RTC
		// API route, without starting screen capture or another agent.
		stream, session, err := controlrtc.Dial(ctx, configuration, func(ctx context.Context, request *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
			raw, err := protojson.Marshal(request)
			if err != nil {
				return nil, err
			}
			path := filepath.Join(t.TempDir(), "offer.json")
			if err = os.WriteFile(path, raw, 0600); err != nil {
				return nil, err
			}
			output.Reset()
			if err = peer.Run([]string{"machine", "connection", "start", "--request", path}); err != nil {
				return nil, err
			}
			result := &dieterv1.ControlConnection{}
			err = protojson.Unmarshal(output.Bytes(), result)
			return result, err
		})
		if err != nil {
			t.Fatal(err)
		}
		defer stream.Close()
		output.Reset()
		if err = peer.Run([]string{"machine", "connection", "show", session.SessionId}); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(output.String(), session.SessionId) {
			t.Fatal("missing control session")
		}
		if err = peer.Run([]string{"machine", "connection", "close", session.SessionId}); err != nil {
			t.Fatal(err)
		}
		peer.Close()
		control.Close()
		fallback := New(cliStore)
		defer fallback.Close()
		fallback.Machine, fallback.GatewayURL = identity.ID, publicURL.String()
		fallback.Out, fallback.Err = io.Discard, io.Discard
		if err := fallback.Run([]string{"status"}); err != nil {
			t.Fatal(err)
		}
		if fallback.transport.route != "relay" {
			t.Fatalf("closed RTC manager did not fall back: %s", fallback.transport.route)
		}
		return
	}
	firstOutput.Reset()
	if err := first.Run([]string{"machine", "info"}); err != nil || !strings.Contains(firstOutput.String(), `"daemonBuild"`) || !strings.Contains(firstOutput.String(), `"gpu"`) {
		t.Fatalf("direct machine info output=%q err=%v", firstOutput.String(), err)
	}
	firstOutput.Reset()
	if err := first.Run([]string{"machine", "gateway"}); err != nil || !strings.Contains(firstOutput.String(), `"releaseVersion"`) {
		t.Fatalf("gateway build output=%q err=%v", firstOutput.String(), err)
	}
	firstOutput.Reset()
	if err := first.Run([]string{"machine", "restart", "--confirm", "RESTART"}); err != nil {
		t.Fatalf("direct restart output=%q err=%v", firstOutput.String(), err)
	}
	assertMachineOperationAccepted(t, firstOutput.Bytes())
	select {
	case operation := <-powerActions:
		if operation != machine.OperationRestart {
			t.Fatalf("direct operation=%q", operation)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("direct restart did not reach the fake executor")
	}
	firstOutput.Reset()
	if err := first.Run([]string{"machine", "update", "--confirm", "UPDATE"}); err != nil {
		t.Fatalf("direct update output=%q err=%v", firstOutput.String(), err)
	}
	assertMachineOperationAccepted(t, firstOutput.Bytes())
	select {
	case operation := <-powerActions:
		if operation != machine.OperationUpdate {
			t.Fatalf("direct update operation=%q", operation)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("direct update did not reach the fake executor")
	}
	firstOutput.Reset()
	if err := first.Run([]string{"remote", "exec", "--project", remoteProject.ID, "--", "/usr/bin/printf", "direct-exec"}); err != nil || firstOutput.String() != "direct-exec" {
		t.Fatalf("direct remote exec output=%q err=%v", firstOutput.String(), err)
	}
	assertScreenSessionCLI(t, first, &firstOutput, nil)
	localConfig := &gatewayv1.RTCConfiguration{}
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, first, &firstOutput, "machine", "rtc")), localConfig); err != nil {
		t.Fatal(err)
	}
	localCLIStore := store.New(t.TempDir())
	if err := localCLIStore.Ensure(); err != nil {
		t.Fatal(err)
	}
	if _, err := dieterdaemon.NewStatusWriter(localCLIStore.Root, dieterdaemon.RuntimeStatus{PID: os.Getpid(), Version: "test", State: "running", ListenAddress: localListener.Addr().String(), GatewayState: dieterdaemon.GatewayNotEnrolled}); err != nil {
		t.Fatal(err)
	}
	localCLI := New(localCLIStore)

	var localCLIOutput bytes.Buffer
	localCLI.Out, localCLI.Err = &localCLIOutput, &localCLIOutput
	assertScreenSessionCLI(t, localCLI, &localCLIOutput, localConfig)
	localCLI.Close()
	assertSyncCursorCLI(t, first, &firstOutput)
	assertMachineHomeTerminalCLI(t, first, &firstOutput)
	assertQueueRemovalCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertCardMergeCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertProjectHostnameCLI(t, first, &firstOutput, remoteProject.ID)
	assertConversationSelectionCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertContentPresentationCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertConversationReadCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertBackgroundProcessCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	first.Close()

	directRoute.server.Stop()
	_ = directRoute.listener.Close()
	directClosed = true
	second := New(cliStore)
	second.Machine, second.GatewayURL = identity.ID, publicURL.String()
	second.Timeout = 10 * time.Second
	var secondOutput bytes.Buffer
	second.Out, second.Err = &secondOutput, &secondOutput
	defer second.Close()
	if err := second.Run([]string{"status"}); err != nil {
		t.Fatal(err)
	}
	expectedRoute := "relay"
	if second.transport == nil || second.transport.route != expectedRoute {
		t.Fatalf("route=%#v want %s", second.transport, expectedRoute)
	}
	assertSyncCursorCLI(t, second, &secondOutput)
	secondOutput.Reset()
	if err := second.Run([]string{"machine", "info"}); err != nil || !strings.Contains(secondOutput.String(), `"daemonBuild"`) || !strings.Contains(secondOutput.String(), `"gpu"`) {
		t.Fatalf("relay machine info output=%q err=%v", secondOutput.String(), err)
	}
	secondOutput.Reset()
	if err := second.Run([]string{"machine", "update", "--confirm", "UPDATE"}); err != nil {
		t.Fatalf("relay update output=%q err=%v", secondOutput.String(), err)
	}
	assertMachineOperationAccepted(t, secondOutput.Bytes())
	select {
	case operation := <-powerActions:
		if operation != machine.OperationUpdate {
			t.Fatalf("relay update operation=%q", operation)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("relay update did not reach the fake executor")
	}
	secondOutput.Reset()
	if err := second.Run([]string{"machine", "shutdown", "--confirm", "SHUT DOWN"}); err != nil {
		t.Fatalf("relay shutdown output=%q err=%v", secondOutput.String(), err)
	}
	assertMachineOperationAccepted(t, secondOutput.Bytes())
	select {
	case operation := <-powerActions:
		if operation != machine.OperationShutdown {
			t.Fatalf("relay operation=%q", operation)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("relay shutdown did not reach the fake executor")
	}
	secondOutput.Reset()
	if err := second.Run([]string{"remote", "exec", "--project", remoteProject.ID, "--", "/usr/bin/printf", "relay-exec"}); err != nil || secondOutput.String() != "relay-exec" {
		t.Fatalf("relay remote exec output=%q err=%v", secondOutput.String(), err)
	}
	assertScreenSessionCLI(t, second, &secondOutput, nil)
	assertMachineHomeTerminalCLI(t, second, &secondOutput)
	assertQueueRemovalCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertCardMergeCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertProjectHostnameCLI(t, second, &secondOutput, remoteProject.ID)
	assertConversationSelectionCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertContentPresentationCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertConversationReadCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertBackgroundProcessCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)

}

func assertMachineHomeTerminalCLI(t *testing.T, client *CLI, output *bytes.Buffer) {
	t.Helper()
	output.Reset()
	if err := client.Run([]string{"terminal", "create", "--home", "--name", "Remote home", "--shell", "sh", "--format", "json"}); err != nil {
		t.Fatalf("create machine-home terminal output=%q err=%v", output.String(), err)
	}
	var terminal dieterv1.Terminal
	if err := protojson.Unmarshal(output.Bytes(), &terminal); err != nil || terminal.GetId() == "" || terminal.GetProjectId() != "" || terminal.GetStatus() != "running" {
		t.Fatalf("machine-home terminal output=%q parsed=%#v err=%v", output.String(), &terminal, err)
	}
	output.Reset()
	if err := client.Run([]string{"terminal", "close", terminal.GetId()}); err != nil {
		t.Fatalf("close machine-home terminal output=%q err=%v", output.String(), err)
	}
}

func assertMachineOperationAccepted(t *testing.T, raw []byte) {
	t.Helper()
	var response dieterv1.MachineOperationResponse
	if err := protojson.Unmarshal(raw, &response); err != nil || !response.GetAccepted() {
		t.Fatalf("machine operation response=%q accepted=%v err=%v", raw, response.GetAccepted(), err)
	}
}

func TestDaemonCLICardTokenUsage(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "usage"), Name: "Usage"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Usage", Prompt: "Count"})
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{`{"type":"start","messageId":"answer"}`, `{"type":"finish","messageMetadata":{"totalUsage":{"inputTokens":100,"outputTokens":25,"totalTokens":125}}}`} {
		if _, _, err := data.AppendUIChunk(card.ID, "turn", json.RawMessage(raw)); err != nil {
			t.Fatal(err)
		}
	}
	raw := runDaemonCLI(t, client, output, "card", "show", card.ID)
	var detail dieterv1.CardDetail
	if err := protojson.Unmarshal([]byte(raw), &detail); err != nil {
		t.Fatal(err)
	}
	if detail.GetCard().GetTokenUsage().GetTotalTokens() != 125 {
		t.Fatalf("show: %s", raw)
	}
	raw = runDaemonCLI(t, client, output, "card", "context", card.ID)
	var context struct {
		Usage struct {
			Total int64 `json:"totalTokens"`
		} `json:"tokenUsage"`
	}
	if err := json.Unmarshal([]byte(raw), &context); err != nil || context.Usage.Total != 125 {
		t.Fatalf("context: %s %v", raw, err)
	}
}

func TestDaemonCLIHostnamePortsEndToEnd(t *testing.T) {
	client, output, _ := daemonCLIForTest(t)
	projectID := strings.TrimSpace(runDaemonCLI(t, client, output, "project", "open", "--format", "id", initTestRepository(t, "hostname-ports")))
	assertProjectHostnameCLI(t, client, output, projectID)
}

func assertProjectHostnameCLI(t *testing.T, client *CLI, output *bytes.Buffer, projectID string) {
	t.Helper()
	boardID := strings.Fields(runDaemonCLI(t, client, output, "board", "list", "--project", projectID, "--format", "ids"))[0]
	runDaemonCLI(t, client, output, "board", "hostnames", "--hostname", "one.example", "--hostname", "localhost:4018", boardID)
	boardJSON := runDaemonCLI(t, client, output, "board", "hostnames", "--append", "--hostname", "two.example:65535", "--hostname", "LOCALHOST:04018", "--hostname", "[0:0:0:0:0:0:0:1]:4018", boardID)
	var board dieterv1.Board
	if err := protojson.Unmarshal([]byte(boardJSON), &board); err != nil {
		t.Fatal(err)
	}
	const boardMappings = "[::1]:4018,localhost:4018,one.example,two.example:65535"
	if strings.Join(board.Hostnames, ",") != boardMappings {
		t.Fatalf("board hostnames=%v", board.Hostnames)
	}
	for _, operation := range [][]string{
		{"board", "hostnames", "--hostname", "valid.example:80", "--hostname", "localhost:0", boardID},
		{"board", "hostnames", "--append", "--hostname", "valid.example:80", "--hostname", "[::1]:65536", boardID},
	} {
		output.Reset()
		if err := client.Run(operation); err == nil {
			t.Fatalf("accepted invalid mapping: %v", operation)
		}
		board.Reset()
		boardJSON = runDaemonCLI(t, client, output, "board", "show", boardID)
		if err := protojson.Unmarshal([]byte(boardJSON), &board); err != nil || strings.Join(board.Hostnames, ",") != boardMappings {
			t.Fatalf("invalid board mutation leaked: %s err=%v", boardJSON, err)
		}
	}
	runDaemonCLI(t, client, output, "board", "hostnames", "--clear", boardID)

	result := runDaemonCLI(t, client, output, "project", "update", "--hostname", "APP.Example.com.", "--hostname", "APP.Example.com.:443", "--hostname", "localhost:04018", "--hostname", "127.0.0.1:4018", "--hostname", "::1", "--hostname", "[::1]:4018", projectID)
	var project dieterv1.Project
	if err := protojson.Unmarshal([]byte(result), &project); err != nil {
		t.Fatal(err)
	}
	const projectMappings = "127.0.0.1:4018,::1,[::1]:4018,app.example.com,app.example.com:443,localhost:4018"
	if strings.Join(project.Hostnames, ",") != projectMappings {
		t.Fatalf("hostnames=%v", project.Hostnames)
	}
	name := project.Name
	output.Reset()
	if err := client.Run([]string{"project", "update", "--name", "Invalid partial update", "--hostname", "valid.example:80", "--hostname", "localhost:https", projectID}); err == nil {
		t.Fatal("accepted invalid project port")
	}
	result = runDaemonCLI(t, client, output, "project", "show", projectID)
	project.Reset()
	if err := protojson.Unmarshal([]byte(result), &project); err != nil || project.Name != name || strings.Join(project.Hostnames, ",") != projectMappings {
		t.Fatalf("invalid project mutation leaked: %s err=%v", result, err)
	}
	result = runDaemonCLI(t, client, output, "project", "update", "--clear-hostnames", projectID)
	project.Reset()
	if err := protojson.Unmarshal([]byte(result), &project); err != nil || len(project.Hostnames) != 0 {
		t.Fatalf("clear=%s err=%v", result, err)
	}
}

func assertSyncCursorCLI(t *testing.T, client *CLI, output *bytes.Buffer) {
	t.Helper()
	raw := runDaemonCLI(t, client, output, "watch", "sync", "--count", "1")
	var frame dieterv1.SyncFrame
	if err := protojson.Unmarshal([]byte(raw), &frame); err != nil {
		t.Fatal(err)
	}
	if frame.Snapshot == nil || frame.Cursor.GetProjectionId() == "" || frame.Heartbeat || frame.ProjectionPending {
		t.Fatalf("CLI did not negotiate complete resumable metadata: %+v", &frame)
	}
}
