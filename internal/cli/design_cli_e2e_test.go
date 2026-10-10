package cli

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/claudedesign"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/encoding/protojson"
)

// cliDesignFixture stands in for Claude Code on the isolated daemon host. No
// test reaches claude.ai or the operator's Claude credentials.
type cliDesignFixture struct {
	mu       sync.Mutex
	signedIn bool
	granted  bool
	revokes  int
}

func (f *cliDesignFixture) Status(context.Context) (claudedesign.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return claudedesign.Status{RuntimeReady: true, Version: "2.1.285", Available: true, SignedIn: f.signedIn, CanSignIn: true}, nil
}

func (f *cliDesignFixture) SignIn(ctx context.Context, codes <-chan string, event func(claudedesign.Event) error) error {
	if err := event(claudedesign.Event{Kind: "pages", URL: "https://claude.com/cai/oauth/authorize?flow=loopback", ManualURL: "https://claude.com/cai/oauth/authorize?flow=manual"}); err != nil {
		return err
	}
	for {
		select {
		case code := <-codes:
			if code == "good-code" {
				f.mu.Lock()
				f.signedIn = true
				f.mu.Unlock()
				return event(claudedesign.Event{Kind: "done", OK: true, Message: "Signed in to Claude Design."})
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (f *cliDesignFixture) SetGrant(_ context.Context, granted bool) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.granted = granted
	if !granted {
		f.revokes++
	}
	return "ok", nil
}

func designStatusCLI(t *testing.T, client *CLI, output *bytes.Buffer, args ...string) *dieterv1.ClaudeDesignStatus {
	t.Helper()
	raw := runDaemonCLI(t, client, output, args...)
	value := &dieterv1.ClaudeDesignStatus{}
	if err := protojson.Unmarshal([]byte(raw), value); err != nil {
		t.Fatalf("dieter %s: %s: %v", strings.Join(args, " "), raw, err)
	}
	return value
}

// assertDesignCLI signs in through the interactive code prompt and toggles
// access on whichever route client already selected.
func assertDesignCLI(t *testing.T, client *CLI, output *bytes.Buffer) {
	t.Helper()
	if status := designStatusCLI(t, client, output, "design", "status"); !status.GetAvailable() || status.GetClaudeCodeVersion() != "2.1.285" {
		t.Fatalf("design status = %v", status)
	}
	previousIn := client.In
	client.In = strings.NewReader("good-code\n")
	login := runDaemonCLI(t, client, output, "design", "login")
	client.In = previousIn
	if !strings.Contains(login, "flow=manual") || !strings.Contains(login, "Signed in to Claude Design.") {
		t.Fatalf("design login output = %q", login)
	}
	if status := designStatusCLI(t, client, output, "design", "status"); !status.GetSignedIn() || status.GetSignInActive() {
		t.Fatalf("status after sign-in = %v", status)
	}
	if status := designStatusCLI(t, client, output, "design", "access", "on"); !status.GetAccessEnabled() || status.GetAccessUpdatedAt() == "" {
		t.Fatalf("access on = %v", status)
	}
	output.Reset()
	if err := client.Run([]string{"design", "access", "on", "--revoke"}); err == nil {
		t.Fatal("design access on --revoke was accepted")
	}
	if status := designStatusCLI(t, client, output, "design", "access", "off", "--revoke"); status.GetAccessEnabled() {
		t.Fatalf("access off = %v", status)
	}
}

func TestDesignCLIControlsOnlyTheIsolatedDaemon(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	assertDesignCLI(t, client, output)
	if access, err := data.ClaudeDesignAccess(); err != nil || access.Enabled {
		t.Fatalf("stored access = %+v, %v", access, err)
	}

	// JSON Lines mode never prompts; a second invocation submits the code.
	reader, writer := io.Pipe()
	watcher := New(data)
	watcher.Timeout = 10 * time.Second
	watcher.Out, watcher.Err = writer, io.Discard
	t.Cleanup(watcher.Close)
	result := make(chan error, 1)
	go func() {
		result <- watcher.Run([]string{"design", "login", "--json"})
		_ = writer.Close()
	}()
	lines := bufio.NewScanner(reader)
	var signInID string
	for lines.Scan() {
		event := &dieterv1.ClaudeDesignSignInEvent{}
		if err := protojson.Unmarshal(lines.Bytes(), event); err != nil {
			t.Fatalf("event %q: %v", lines.Text(), err)
		}
		if event.GetSignInId() != "" && signInID == "" {
			signInID = event.GetSignInId()
		}
		if event.GetManualUrl() != "" {
			runDaemonCLI(t, client, output, "design", "code", signInID, "good-code")
		}
		if event.GetDone() {
			if !event.GetOk() || !event.GetStatus().GetSignedIn() {
				t.Fatalf("done event = %v", event)
			}
			break
		}
	}
	go func() { _, _ = io.Copy(io.Discard, reader) }()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := client.Run([]string{"design", "code", signInID, "good-code"}); err == nil || !strings.Contains(err.Error(), "no longer running") {
		t.Fatalf("code after sign-in = %v", err)
	}
}
