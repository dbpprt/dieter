package cli

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
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
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
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

	runDaemonCLI(t, client, output, "board", "label", "add", "--board", created.Board.ID, "--name", "CLI", "--instructions", "Keep the CLI current")
	cardJSON := runDaemonCLI(t, client, output, "card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--lane", "todo", "--title", "Daemon parity", "--prompt", "Exercise the API", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var card struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(cardJSON), &card); err != nil || card.ID == "" {
		t.Fatalf("created card JSON=%q err=%v", cardJSON, err)
	}
	runDaemonCLI(t, client, output, "card", "comment", "--message", "CLI annotation", card.ID)
	runDaemonCLI(t, client, output, "workspace", "show", card.ID)

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

	runDaemonCLI(t, client, output, "settings", "show")
	runDaemonCLI(t, client, output, "prompt", "show")
	runDaemonCLI(t, client, output, "prompt", "preview", "--card", card.ID)
	runDaemonCLI(t, client, output, "screen", "capabilities")

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
	localListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	remoteHTTP := &http.Server{Handler: server.New(remoteStore, logger).Handler()}
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
	first.Out, first.Err = io.Discard, io.Discard
	if err := first.Run([]string{"status"}); err != nil {
		t.Fatal(err)
	}
	if first.transport == nil || first.transport.route != "direct" {
		t.Fatalf("route=%#v want direct", first.transport)
	}
	first.Close()

	directRoute.server.Stop()
	_ = directRoute.listener.Close()
	directClosed = true
	second := New(cliStore)
	second.DaemonMode, second.Machine, second.GatewayURL = true, identity.ID, publicURL.String()
	second.Timeout = 10 * time.Second
	second.Out, second.Err = io.Discard, io.Discard
	defer second.Close()
	if err := second.Run([]string{"status"}); err != nil {
		t.Fatal(err)
	}
	if second.transport == nil || second.transport.route != "relay" {
		t.Fatalf("route=%#v want relay", second.transport)
	}
}
