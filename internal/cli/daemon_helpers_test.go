package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

// initTestRepository returns a Git repository named name (the default
// project name) with an uncommitted README.md.
func initTestRepository(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	testkit.InitGitRepo(t, path)
	if err := os.WriteFile(filepath.Join(path, "README.md"), []byte("initial\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func daemonCLIForTest(t *testing.T) (*CLI, *bytes.Buffer, *store.Store) {
	t.Helper()
	return daemonCLIWithRunner(t, newFakeRunner())
}

// daemonCLIWithRunner is daemonCLIForTest with the daemon's harness runner.
func daemonCLIWithRunner(t *testing.T, runner harness.Runner) (*CLI, *bytes.Buffer, *store.Store) {
	t.Helper()
	root := t.TempDir()
	data := store.New(root)
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	// The static release catalog plus the mock harness: no provider discovery.
	application := api.NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), api.Options{Runner: runner, Catalog: testkit.MockCatalog(), PrivacyDriver: &cliPrivacyFixture{}, PrivacyBootID: func(context.Context) (string, error) { return "cli-boot", nil }})
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := link.NewStatusWriter(root, link.RuntimeStatus{
		PID: os.Getpid(), Version: "test", State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"), GatewayState: link.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}
	output := &bytes.Buffer{}
	client := New(data.Root)

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

type cliPrivacyFixture struct{ enabled bool }

func (f *cliPrivacyFixture) Setup(ctx context.Context) (*dieterv1.MachinePrivacy, error) {
	return f.Snapshot(ctx)
}

func (f *cliPrivacyFixture) Snapshot(context.Context) (*dieterv1.MachinePrivacy, error) {
	state := dieterv1.MachinePrivacy_STATE_OFF
	if f.enabled {
		state = dieterv1.MachinePrivacy_STATE_ON
	}
	return &dieterv1.MachinePrivacy{Supported: true, Requested: f.enabled, State: state, DisplayCount: 1}, nil
}
func (f *cliPrivacyFixture) Set(ctx context.Context, enabled bool) (*dieterv1.MachinePrivacy, error) {
	f.enabled = enabled
	return f.Snapshot(ctx)
}

const cliBatchPrompt = "stream-batching-regression-128-tokens"

func emitCLIBatch(request harness.Request, emit func(harness.Output) error) error {
	chunks := []string{`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`, `{"type":"text-start","id":"text"}`}
	for i := range 128 {
		chunks = append(chunks, fmt.Sprintf(`{"type":"text-delta","id":"text","delta":"%03d "}`, i))
	}
	chunks = append(chunks, `{"type":"text-end","id":"text"}`, `{"type":"finish","finishReason":"stop"}`)
	for _, chunk := range chunks {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"batched-cli"}}`)})
}
