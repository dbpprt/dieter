//go:build unix

package accounts

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness/agentexec"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

// The test binary doubles as fake provider tools: `accounts.test fake-claude
// …` and `accounts.test fake-codex …` (see fakes_test.go).
func TestMain(m *testing.M) {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "fake-claude":
			os.Exit(fakeClaude(os.Args[2:]))
		case "fake-codex":
			os.Exit(fakeCodex(os.Args[2:]))
		}
	}
	os.Exit(m.Run())
}

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func newClock() *clock { return &clock{now: time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)} }

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

type harness struct {
	svc     *Service
	store   *store.Store
	clock   *clock
	fixture *FixtureBackend
	daemon  string
	home    string
}

type option func(*Options)

func withEnvironment(env map[string]string) option {
	return func(o *Options) { o.Environment = env }
}

func withBackend(backend Backend) option { return func(o *Options) { o.Backend = backend } }

func withRuntime(dir string) option {
	return func(o *Options) {
		o.RuntimeDir = func(context.Context) (string, error) { return dir, nil }
	}
}

// newHarness is a Service on an enrolled temporary store with a temporary
// host home and the fixture backend.
func newHarness(t *testing.T, daemon string, options ...option) *harness {
	t.Helper()
	st := testkit.PeerStore(t, daemon)
	return harnessOn(t, st, daemon, options...)
}

func harnessOn(t *testing.T, st *store.Store, daemon string, options ...option) *harness {
	t.Helper()
	c := newClock()
	fixture := NewFixtureBackend()
	fixture.Clock = c.Now
	fixture.DeviceApproval = 20 * time.Millisecond
	home := t.TempDir()
	opts := Options{
		Store: st, DaemonID: func() string { return daemon }, HostHome: home, Backend: fixture,
		Clock: c.Now, MachineName: func() string { return daemon }, Environment: map[string]string{},
		HostID: func() string { return "urn:uuid:00000000-0000-4000-8000-000000000000" },
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	for _, apply := range options {
		apply(&opts)
	}
	svc, err := New(opts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(svc.Shutdown)
	return &harness{svc: svc, store: st, clock: c, fixture: fixture, daemon: daemon, home: home}
}

func (h *harness) create(t *testing.T, provider, label, method string) Account {
	t.Helper()
	account, err := h.svc.Create(context.Background(), CreateInput{Provider: provider, Label: label, Method: method})
	if err != nil {
		t.Fatal(err)
	}
	return account
}

func (h *harness) account(t *testing.T, id string) Account {
	t.Helper()
	account, err := h.svc.get(id)
	if err != nil {
		t.Fatal(err)
	}
	return account
}

func (h *harness) login(t *testing.T, id string) (schema.ProviderLoginRecord, bool) {
	t.Helper()
	r, err := h.svc.load()
	if err != nil {
		t.Fatal(err)
	}
	return r.ownLogin(id, h.daemon)
}

// signIn records a signed-in login of this machine directly.
func (h *harness) signIn(t *testing.T, id, method string, identity Identity) {
	t.Helper()
	if err := h.svc.updateLogin(id, func(record *schema.ProviderLoginRecord, _ bool) bool {
		*record = schema.ProviderLoginRecord{State: StateSignedIn, Method: method, Identity: identityPointer(identity), VerifiedAt: h.svc.timestamp()}
		return true
	}); err != nil {
		t.Fatal(err)
	}
}

// waitLogin watches a sign-in until it ends.
func waitLogin(t *testing.T, svc *Service, id string) Login {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var last Login
	if err := svc.WatchLogin(ctx, id, func(login Login) error {
		last = login
		return nil
	}); err != nil {
		t.Fatalf("watch %s: %v (last %+v)", id, err, last)
	}
	return last
}

// fakeRuntime lays out a harness runtime whose Claude Code and Codex
// executables are this test binary.
func fakeRuntime(t *testing.T, scenario string) string {
	t.Helper()
	dir := t.TempDir()
	host := agentexec.CurrentHost()
	triple, err := agentexec.CodexTriple(host)
	if err != nil {
		t.Skip(err)
	}
	modules := filepath.Join(dir, "node_modules")
	packages := map[string]string{
		"@anthropic-ai/claude-agent-sdk": "",
		agentexec.ClaudePackage(host):    "claude",
		"@openai/codex":                  "",
		agentexec.CodexPackage(host):     filepath.Join("vendor", triple, "bin", "codex"),
	}
	for name, executable := range packages {
		pkg := filepath.Join(modules, filepath.FromSlash(name))
		if err := os.MkdirAll(pkg, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(pkg, "package.json"), []byte(`{"version":"0.0.0"}`), 0o644); err != nil {
			t.Fatal(err)
		}
		if executable == "" {
			continue
		}
		mode := "fake-claude"
		if name == agentexec.CodexPackage(host) {
			mode = "fake-codex"
		}
		path := filepath.Join(pkg, executable)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		script := "#!/bin/sh\nFAKE_SCENARIO=" + shellQuote(scenario) + " exec " + shellQuote(os.Args[0]) + " " + mode + " \"$@\"\n"
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
