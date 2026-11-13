package harness

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func strixArchive(t *testing.T, entry string, script string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	compressed := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(compressed)
	if err := archive.WriteHeader(&tar.Header{Name: entry, Mode: 0o755, Size: int64(len(script)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := archive.Write([]byte(script)); err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// serveStrix points the pinned release at a local server for this test.
func serveStrix(t *testing.T, body []byte, pinnedSHA string) *atomic.Int32 {
	t.Helper()
	platform := runtime.GOOS + "/" + runtime.GOARCH
	asset, ok := strixAssets[platform]
	if !ok {
		t.Skipf("Strix has no build for %s", platform)
	}
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/"+asset.Name+".tar.gz" {
			http.NotFound(writer, request)
			return
		}
		hits.Add(1)
		_, _ = writer.Write(body)
	}))
	t.Cleanup(server.Close)
	previousAssets, previousURL := strixAssets, strixReleaseBaseURL
	if pinnedSHA == "" {
		sum := sha256.Sum256(body)
		pinnedSHA = hex.EncodeToString(sum[:])
	}
	strixAssets = map[string]strixAsset{platform: {Name: asset.Name, SHA256: pinnedSHA}}
	strixReleaseBaseURL = server.URL
	t.Cleanup(func() { strixAssets, strixReleaseBaseURL = previousAssets, previousURL })
	return &hits
}

func strixEntry(t *testing.T) string {
	asset, ok := strixAssets[runtime.GOOS+"/"+runtime.GOARCH]
	if !ok {
		t.Skip("Strix has no build for this platform")
	}
	return asset.Name
}

const fakeStrixVersion = "#!/bin/sh\necho 'strix " + managedStrixVersion + "'\n"

func TestEnsureManagedStrixPublishesThePinnedExecutableOnce(t *testing.T) {
	hits := serveStrix(t, strixArchive(t, strixEntry(t), fakeStrixVersion), "")
	home := t.TempDir()
	executable, err := ensureManagedStrix(context.Background(), home, os.Environ())
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, "runtime", "tools", "strix", managedStrixVersion, "strix"); executable != want {
		t.Fatalf("executable=%q want %q", executable, want)
	}
	if output, err := exec.Command(executable, "--version").Output(); err != nil || strings.TrimSpace(string(output)) != "strix "+managedStrixVersion {
		t.Fatalf("installed executable output=%q err=%v", output, err)
	}
	if again, err := ensureManagedStrix(context.Background(), home, os.Environ()); err != nil || again != executable || hits.Load() != 1 {
		t.Fatalf("second ensure=%q err=%v downloads=%d", again, err, hits.Load())
	}
	entries, _ := os.ReadDir(filepath.Join(home, "runtime", "tools", "strix"))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".stage-") || strings.HasPrefix(entry.Name(), ".probe-") || strings.HasPrefix(entry.Name(), ".download-") {
			t.Errorf("installation left %s behind", entry.Name())
		}
	}
}

func TestEnsureManagedStrixRejectsUnpinnedOrWrongExecutables(t *testing.T) {
	for _, test := range []struct {
		name   string
		script string
		sha    string
		entry  string
		want   string
	}{
		{name: "digest mismatch", script: fakeStrixVersion, sha: strings.Repeat("0", 64), want: "SHA-256 of the"},
		{name: "other version", script: "#!/bin/sh\necho 'strix 0.0.1'\n", want: `Strix reports "strix 0.0.1"`},
		{name: "missing entry", script: fakeStrixVersion, entry: "something-else", want: "archive has no"},
	} {
		t.Run(test.name, func(t *testing.T) {
			entry := test.entry
			if entry == "" {
				entry = strixEntry(t)
			}
			serveStrix(t, strixArchive(t, entry, test.script), test.sha)
			home := t.TempDir()
			_, err := ensureManagedStrix(context.Background(), home, os.Environ())
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error=%v want %q", err, test.want)
			}
			if _, statErr := os.Lstat(filepath.Join(home, "runtime", "tools", "strix", managedStrixVersion)); !errors.Is(statErr, fs.ErrNotExist) {
				t.Fatalf("a rejected executable was published: %v", statErr)
			}
		})
	}
}

// A Strix stand-in for the runner: it records its environment and writes a
// one-item run directory the way Strix does.
const fakeStrixTurn = `#!/usr/bin/env node
const { mkdirSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");
const { DatabaseSync } = require("node:sqlite");
writeFileSync(join(process.cwd(), "seen.json"), JSON.stringify({
  args: process.argv.slice(2), home: process.env.HOME, docker: process.env.DOCKER_HOST,
  key: process.env.LLM_API_KEY, token: process.env.DIETER_TURN_TOKEN, model: process.env.STRIX_LLM,
}));
const runDir = join(process.cwd(), "strix_runs", "repo_1a2b");
mkdirSync(join(runDir, ".state"), { recursive: true });
writeFileSync(join(runDir, ".state", "agents.json"), JSON.stringify({ statuses: { r: "completed", k: "completed" }, parent_of: { r: null, k: "r" }, names: { r: "Root Agent", k: "Recon" } }));
const db = new DatabaseSync(join(runDir, ".state", "agents.db"));
db.exec("CREATE TABLE agent_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, message_data TEXT)");
const insert = db.prepare("INSERT INTO agent_messages (session_id, message_data) VALUES (?, ?)");
insert.run("r", JSON.stringify({ type: "message", role: "assistant", content: [{ type: "output_text", text: "No findings in the fixture." }] }));
insert.run("k", JSON.stringify({ type: "message", role: "assistant", content: [{ type: "output_text", text: "Mapping routes." }] }));
insert.run("k", JSON.stringify({ type: "function_call", call_id: "c1", name: "exec_command", arguments: "{}" }));
db.close();
writeFileSync(join(runDir, "run.json"), JSON.stringify({ run_name: "repo_1a2b", status: "completed", llm_usage: { input_tokens: 40, output_tokens: 8, total_tokens: 48, cost: 0 }, scan_results: { executive_summary: "Clean." } }));
`

func TestSubprocessRunnerRunsStrixTurnsThroughThePinnedExecutable(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node is not installed")
	}
	strixEntry(t)
	home := t.TempDir()
	installed := filepath.Join(home, "runtime", "tools", "strix", managedStrixVersion, "strix")
	if err := os.MkdirAll(filepath.Dir(installed), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installed, []byte(fakeStrixTurn), 0o700); err != nil {
		t.Fatal(err)
	}
	// The Strix path loads only Node built-ins, so the staged sources run
	// without installed dependencies.
	stagedRuntime := t.TempDir()
	if err := stageRuntimeAssets(stagedRuntime); err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	env := Environment{
		RuntimeDir: stagedRuntime,
		Variables:  append(os.Environ(), "DOCKER_HOST=unix:///tmp/dieter-test-docker.sock"),
	}
	runtimeRoot := filepath.Join(t.TempDir(), "runtime")
	var chunks []string
	var capabilities []json.RawMessage
	var session json.RawMessage
	err := NewSubprocessRunner(home, env).Run(context.Background(), Request{
		Harness: "strix", Adapter: "strix", Prompt: "Scan the fixture", SessionID: "card_strix", ResponseMessageID: "assistant_1",
		ProjectPath: repo, RuntimeRoot: runtimeRoot, Options: map[string]string{"scan_mode": "quick", "max_budget_usd": "1"},
		Environment: map[string]string{"LLM_API_KEY": "sk-runner-test", "STRIX_LLM": "openai/test", "DIETER_TURN_TOKEN": "turn-secret"},
	}, func(output Output) error {
		switch output.Type {
		case "chunk":
			chunks = append(chunks, string(output.Chunk))
		case "capability":
			capabilities = append(capabilities, output.Capability)
		case "session":
			session = output.State
		case "error":
			t.Errorf("worker error: %s", output.Message)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	stream := strings.Join(chunks, "\n")
	if !strings.Contains(stream, "No findings in the fixture.") || !strings.Contains(stream, `"type":"finish"`) || !strings.Contains(stream, "Strix completed") {
		t.Fatalf("stream=%s", stream)
	}
	if !strings.Contains(string(session), `"strixRunName":"repo_1a2b"`) {
		t.Fatalf("session=%s", session)
	}
	// Every subagent update decodes into the daemon's model; one that does not
	// is dropped by the conversation reducer.
	var child model.Subagent
	for _, raw := range capabilities {
		var envelope struct {
			ID       string         `json:"id"`
			Subagent model.Subagent `json:"subagent"`
		}
		if err := json.Unmarshal(raw, &envelope); err != nil {
			t.Fatalf("capability %s does not decode: %v", raw, err)
		}
		if envelope.ID == "subagents" {
			child = envelope.Subagent
		}
	}
	if child.Name != "Recon" || child.Status != "completed" || child.ToolCount != 1 || len(child.RecentOutput) != 2 {
		t.Fatalf("last subagent update = %+v", child)
	}
	raw, err := os.ReadFile(filepath.Join(runtimeRoot, "strix", "card_strix", "seen.json"))
	if err != nil {
		t.Fatal(err)
	}
	var seen struct {
		Args                            []string
		Home, Docker, Key, Token, Model string
	}
	if err := json.Unmarshal(raw, &seen); err != nil {
		t.Fatal(err)
	}
	if seen.Home != filepath.Join(runtimeRoot, "strix", "card_strix", "home") || seen.Docker != "unix:///tmp/dieter-test-docker.sock" || seen.Key != "sk-runner-test" || seen.Model != "openai/test" || seen.Token != "" {
		t.Fatalf("Strix saw %+v", seen)
	}
	if !strings.Contains(strings.Join(seen.Args, " "), "--target "+repo) {
		t.Fatalf("Strix args %v do not target the checkout", seen.Args)
	}
}
