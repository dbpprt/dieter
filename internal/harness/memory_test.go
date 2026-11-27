package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMemoryHostCallRepliesAndValidation(t *testing.T) {
	t.Parallel()
	call := ProcessCall{ID: "call-1", Operation: "recall", Arguments: json.RawMessage(`{"query":"x"}`)}
	reply := func(handler MemoryHandler) map[string]any {
		t.Helper()
		var out bytes.Buffer
		replyMemory(context.Background(), &out, handler, call)
		var decoded map[string]any
		if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
			t.Fatalf("reply %q: %v", out.String(), err)
		}
		if decoded["type"] != "memory-result" || decoded["id"] != "call-1" {
			t.Fatalf("reply frame=%q", out.String())
		}
		return decoded
	}
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) {
		return json.RawMessage(`{"conversations":[]}`), nil
	}); got["error"] != nil || got["result"] == nil {
		t.Fatalf("result reply=%#v", got)
	}
	if got := reply(nil); !strings.Contains(got["error"].(string), "not available") {
		t.Fatalf("nil handler reply=%#v", got)
	}
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) { return nil, errors.New("memory is off") }); got["error"] != "memory is off" {
		t.Fatalf("error reply=%#v", got)
	}
	huge := json.RawMessage(`"` + strings.Repeat("x", maxMemoryResultBytes) + `"`)
	if got := reply(func(context.Context, ProcessCall) (json.RawMessage, error) { return huge, nil }); got["error"] != "invalid memory result" {
		t.Fatalf("oversized result reply=%#v", got)
	}

	for name, invalid := range map[string]*ProcessCall{
		"nil":       nil,
		"no id":     {Operation: "recall"},
		"long id":   {ID: strings.Repeat("x", 129), Operation: "recall"},
		"operation": {ID: "x", Operation: "delete"},
		"too long":  {ID: "x", Operation: "save", Arguments: json.RawMessage(`"` + strings.Repeat("a", maxMemoryInputBytes) + `"`)},
	} {
		if validMemoryCall(invalid) == nil {
			t.Errorf("%s: invalid call accepted", name)
		}
	}
	for _, operation := range []string{"recall", "save", "apply"} {
		if err := validMemoryCall(&ProcessCall{ID: "ok", Operation: operation}); err != nil {
			t.Fatal(err)
		}
	}
}

// The mock runtime calls memory_recall through the private stdio bridge and
// streams the daemon's answer as the tool output.
func TestSubprocessRunnerMockMemoryRecall(t *testing.T) {
	cwd, _ := os.Getwd()
	runtimeDir := filepath.Join(cwd, "runtime")
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}
	stagedRuntime := t.TempDir()
	if err := stageRuntimeAssets(stagedRuntime); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(runtimeDir, "node_modules"), filepath.Join(stagedRuntime, "node_modules")); err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	runner := NewSubprocessRunner(t.TempDir(), Environment{RuntimeDir: stagedRuntime})
	var calls []ProcessCall
	var chunks []string
	err := runner.Run(context.Background(), Request{
		Harness: "mock", Prompt: "mock-memory-recall flaky scheduler", SessionID: "card", ResponseMessageID: "assistant_1",
		ProjectPath: repo, RuntimeRoot: filepath.Join(t.TempDir(), "runtime"), MemoryEnabled: true,
		MemoryCommand: "dieter memory search --project p_1",
		Memory: func(_ context.Context, call ProcessCall) (json.RawMessage, error) {
			calls = append(calls, call)
			return json.RawMessage(`{"note":"earlier work","memories":[],"conversations":[{"card":"c_1","machine":"alpha","title":"Flaky scheduler"}]}`), nil
		},
	}, func(output Output) error {
		if output.Type == "chunk" {
			chunks = append(chunks, string(output.Chunk))
		}
		return nil
	})
	stream := strings.Join(chunks, "")
	if err != nil || len(calls) != 1 || calls[0].Operation != "recall" || !strings.Contains(string(calls[0].Arguments), `"query":"flaky scheduler"`) {
		t.Fatalf("calls=%+v err=%v", calls, err)
	}
	if !strings.Contains(stream, `"toolName":"memory_recall"`) || !strings.Contains(stream, `"tool-output-available"`) || !strings.Contains(stream, "Flaky scheduler") {
		t.Fatalf("stream=%s", stream)
	}
}
