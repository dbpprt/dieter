package cli

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
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
	"sync"
	"testing"
	"time"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/machine"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

type synchronizedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (value *synchronizedBuffer) Write(raw []byte) (int, error) {
	value.mu.Lock()
	defer value.mu.Unlock()
	return value.b.Write(raw)
}

func (value *synchronizedBuffer) String() string {
	value.mu.Lock()
	defer value.mu.Unlock()
	return value.b.String()
}

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
	client.DaemonMode = true
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
	client, output, _ := daemonCLIForTest(t)
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
		WorkspaceBaseRemote string `json:"workspaceBaseRemote"`
		RemotePublishMode   string `json:"remotePublishMode"`
	}
	if err := json.Unmarshal([]byte(cardJSON), &card); err != nil || card.ID == "" || card.WorkspaceBaseRemote != "private" || card.RemotePublishMode != "pull_request" {
		t.Fatalf("created card JSON=%q err=%v", cardJSON, err)
	}
	quickJSON := runDaemonCLI(t, client, output, "card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--lane", "todo", "--auto-title", "--prompt", "Add keyboard navigation", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var quick struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(quickJSON), &quick); err != nil || quick.ID == "" || quick.Title != "Add Keyboard Board Navigation" {
		t.Fatalf("quick task JSON=%q parsed=%#v err=%v", quickJSON, quick, err)
	}
	runDaemonCLI(t, client, output, "card", "comment", "--message", "CLI annotation", card.ID)
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

func TestDaemonModeNeverFallsBackToDirectStorage(t *testing.T) {
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
	client.DaemonMode = true
	client.Out, client.Err = &output, &output
	err := client.Run([]string{"project", "list", "--format", "json"})
	if err == nil || !strings.Contains(err.Error(), "local Dieter daemon is not running") {
		t.Fatalf("project list error=%v output=%q", err, output.String())
	}
	if strings.Contains(output.String(), "Must remain hidden") {
		t.Fatalf("daemon-mode CLI read the store directly: %q", output.String())
	}
}

func gatewaySessionDigest(secret []byte, token string) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(token))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func TestDaemonCLIAuthenticatesWithLoopbackPKCEEndToEnd(t *testing.T) {
	github := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/login/oauth/authorize":
			callback, err := url.Parse(request.URL.Query().Get("redirect_uri"))
			if err != nil {
				t.Error(err)
				http.Error(writer, "bad callback", http.StatusBadRequest)
				return
			}
			query := callback.Query()
			query.Set("code", "github-code")
			query.Set("state", request.URL.Query().Get("state"))
			callback.RawQuery = query.Encode()
			http.Redirect(writer, request, callback.String(), http.StatusFound)
		case "/login/oauth/access_token":
			writer.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(writer, `{"access_token":"github-token","token_type":"bearer"}`)
		case "/user":
			if request.Header.Get("Authorization") != "Bearer github-token" {
				http.Error(writer, "unauthorized", http.StatusUnauthorized)
				return
			}
			writer.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(writer, `{"id":42,"login":"owner"}`)
		default:
			http.NotFound(writer, request)
		}
	}))
	defer github.Close()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	publicURL, _ := url.Parse("http://" + listener.Addr().String())
	configuration := gateway.Config{Root: t.TempDir(), Address: listener.Addr().String(), PublicURL: publicURL, GitHubClientID: "client", GitHubSecret: "secret", AllowedUserID: 42, AllowedLogin: "owner", AuthSecret: []byte("0123456789abcdef0123456789abcdef"), SessionTTL: time.Hour, NativeRedirects: map[string]struct{}{}, GitHubBaseURL: github.URL, GitHubAPIURL: github.URL, DevInsecure: true}
	gatewayStore, err := gateway.OpenStore(configuration.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayStore.Close()
	serverValue, err := gateway.NewServer(configuration, gatewayStore, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = serverValue.Serve(listener) }()

	cliStore := store.New(t.TempDir())
	output := &synchronizedBuffer{}
	client := New(cliStore)
	client.DaemonMode, client.GatewayURL, client.Timeout = true, publicURL.String(), 10*time.Second
	client.Out, client.Err = output, output
	defer client.Close()
	result := make(chan error, 1)
	go func() { result <- client.Run([]string{"auth", "login", "--no-open"}) }()

	var authorizationURL string
	deadline := time.Now().Add(5 * time.Second)
	for authorizationURL == "" && time.Now().Before(deadline) {
		for _, line := range strings.Split(output.String(), "\n") {
			if strings.Contains(line, "/auth/github/start?") {
				authorizationURL = strings.TrimSpace(line)
				break
			}
		}
		if authorizationURL == "" {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if authorizationURL == "" {
		t.Fatalf("CLI did not print an authorization URL: %s", output.String())
	}

	noRedirect := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	start, err := noRedirect.Get(authorizationURL)
	if err != nil {
		t.Fatal(err)
	}
	if start.StatusCode != http.StatusFound || len(start.Cookies()) == 0 {
		t.Fatalf("gateway auth start status=%s cookies=%v", start.Status, start.Cookies())
	}
	cookie := start.Cookies()[0]
	githubAuthorization := start.Header.Get("Location")
	_ = start.Body.Close()
	authorized, err := noRedirect.Get(githubAuthorization)
	if err != nil {
		t.Fatal(err)
	}
	callbackURL := authorized.Header.Get("Location")
	_ = authorized.Body.Close()
	callbackRequest, _ := http.NewRequest(http.MethodGet, callbackURL, nil)
	callbackRequest.AddCookie(cookie)
	callback, err := noRedirect.Do(callbackRequest)
	if err != nil {
		t.Fatal(err)
	}
	loopbackCallback := callback.Header.Get("Location")
	_ = callback.Body.Close()
	completed, err := noRedirect.Get(loopbackCallback)
	if err != nil {
		t.Fatal(err)
	}
	_ = completed.Body.Close()
	if completed.StatusCode != http.StatusOK {
		t.Fatalf("CLI loopback callback status=%s", completed.Status)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("CLI login did not finish after its loopback callback")
	}
	loaded, err := loadClientConfig(cliStore.Root)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.Sessions[publicURL.String()].valid(time.Now()) {
		t.Fatalf("CLI session was not persisted: %#v", loaded)
	}
}

func TestDaemonCLIUsesDirectRouteThenRelayFallback(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	gatewayListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayListener.Close()
	publicURL, _ := url.Parse("http://" + gatewayListener.Addr().String())
	secret := []byte("0123456789abcdef0123456789abcdef")
	configuration := gateway.Config{Root: t.TempDir(), Address: gatewayListener.Addr().String(), PublicURL: publicURL, GitHubClientID: "test", GitHubSecret: "test", AllowedUserID: 42, AllowedLogin: "owner", AuthSecret: secret, SessionTTL: time.Hour, NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid", DevInsecure: true}
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
	if err := gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), configuration.AllowedUserID, configuration.AllowedLogin); err != nil {
		t.Fatal(err)
	}
	credential, err := dieterdaemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
	if err != nil {
		t.Fatal(err)
	}
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
	remoteServer := server.NewWithOptions(remoteStore, logger, server.Options{
		MachineAction: func(_ context.Context, operation machine.Operation) error {
			powerActions <- operation
			return nil
		},
		MachineCapabilities: func(context.Context) []machine.OperationCapability {
			return []machine.OperationCapability{
				{Operation: machine.OperationRestart, Supported: true, Authorized: true},
				{Operation: machine.OperationShutdown, Supported: true, Authorized: true},
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
	tunnel := &dieterdaemon.GatewayClient{Identity: identity, LocalTarget: localListener.Addr().String(), Version: "test", Routes: []*gatewayv1.DirectCandidate{directRoute.candidate}, Log: logger}
	go func() { _ = tunnel.Run(ctx) }()
	deadline := time.Now().Add(5 * time.Second)
	for !gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("isolated daemon did not connect to isolated gateway")
	}

	token := "cli-e2e-session"
	if err := gatewayStore.UpdateAuthState(func(state *gateway.AuthState) error {
		state.Sessions = append(state.Sessions, gateway.Session{TokenHash: gatewaySessionDigest(secret, token), GitHubID: configuration.AllowedUserID, Login: configuration.AllowedLogin, CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour)})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	cliStore := store.New(t.TempDir())
	if err := cliStore.Ensure(); err != nil {
		t.Fatal(err)
	}
	if err := saveClientConfig(cliStore.Root, clientConfig{DefaultGateway: publicURL.String(), Sessions: map[string]clientSession{publicURL.String(): {AccessToken: token, ExpiresAt: time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano), Login: "owner"}}}); err != nil {
		t.Fatal(err)
	}
	first := New(cliStore)
	first.DaemonMode, first.Machine, first.GatewayURL = true, identity.ID, publicURL.String()
	first.Timeout = 10 * time.Second
	var firstOutput bytes.Buffer
	first.Out, first.Err = &firstOutput, &firstOutput
	if err := first.Run([]string{"status"}); err != nil {
		t.Fatal(err)
	}
	if first.transport == nil || first.transport.route != "direct" {
		t.Fatalf("route=%#v want direct", first.transport)
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
	if err := first.Run([]string{"remote", "exec", "--project", remoteProject.ID, "--", "/usr/bin/printf", "direct-exec"}); err != nil || firstOutput.String() != "direct-exec" {
		t.Fatalf("direct remote exec output=%q err=%v", firstOutput.String(), err)
	}
	assertQueueRemovalCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertCardMergeCLI(t, first, &firstOutput, remoteStore, remoteProject.ID)
	assertProjectHostnameCLI(t, first, &firstOutput, remoteProject.ID)
	first.Close()

	directRoute.server.Stop()
	_ = directRoute.listener.Close()
	directClosed = true
	second := New(cliStore)
	second.DaemonMode, second.Machine, second.GatewayURL = true, identity.ID, publicURL.String()
	second.Timeout = 10 * time.Second
	var secondOutput bytes.Buffer
	second.Out, second.Err = &secondOutput, &secondOutput
	defer second.Close()
	if err := second.Run([]string{"status"}); err != nil {
		t.Fatal(err)
	}
	if second.transport == nil || second.transport.route != "relay" {
		t.Fatalf("route=%#v want relay", second.transport)
	}
	secondOutput.Reset()
	if err := second.Run([]string{"machine", "info"}); err != nil || !strings.Contains(secondOutput.String(), `"daemonBuild"`) || !strings.Contains(secondOutput.String(), `"gpu"`) {
		t.Fatalf("relay machine info output=%q err=%v", secondOutput.String(), err)
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
	assertQueueRemovalCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertCardMergeCLI(t, second, &secondOutput, remoteStore, remoteProject.ID)
	assertProjectHostnameCLI(t, second, &secondOutput, remoteProject.ID)
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

func assertProjectHostnameCLI(t *testing.T, client *CLI, output *bytes.Buffer, projectID string) {
	t.Helper()
	boardID := strings.Fields(runDaemonCLI(t, client, output, "board", "list", "--project", projectID, "--format", "ids"))[0]
	runDaemonCLI(t, client, output, "board", "hostnames", "--hostname", "one.example", boardID)
	boardJSON := runDaemonCLI(t, client, output, "board", "hostnames", "--append", "--hostname", "two.example", boardID)
	var board dieterv1.Board
	if err := protojson.Unmarshal([]byte(boardJSON), &board); err != nil {
		t.Fatal(err)
	}
	if strings.Join(board.Hostnames, ",") != "one.example,two.example" {
		t.Fatalf("board hostnames=%v", board.Hostnames)
	}
	runDaemonCLI(t, client, output, "board", "hostnames", "--clear", boardID)

	result := runDaemonCLI(t, client, output, "project", "update", "--hostname", "APP.Example.com.", "--hostname", "localhost", projectID)
	var project dieterv1.Project
	if err := protojson.Unmarshal([]byte(result), &project); err != nil {
		t.Fatal(err)
	}
	if strings.Join(project.Hostnames, ",") != "app.example.com,localhost" {
		t.Fatalf("hostnames=%v", project.Hostnames)
	}
	result = runDaemonCLI(t, client, output, "project", "show", projectID)
	if !strings.Contains(result, "app.example.com") {
		t.Fatalf("mapping not discoverable: %s", result)
	}
	result = runDaemonCLI(t, client, output, "project", "update", "--clear-hostnames", projectID)
	project.Reset()
	if err := protojson.Unmarshal([]byte(result), &project); err != nil || len(project.Hostnames) != 0 {
		t.Fatalf("clear=%s err=%v", result, err)
	}
}
