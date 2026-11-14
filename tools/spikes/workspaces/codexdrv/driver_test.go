package codexdrv

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
)

func TestMain(m *testing.M) {
	if os.Getenv("CODEXDRV_FAKE_SERVER") == "1" {
		fakeServer()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fakeServer imitates the parts of `codex app-server` the driver uses.
// Turn 1 reports changes, turn 2 fails, turn 3 hangs until interrupted.
func fakeServer() {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 1<<24)
	out := json.NewEncoder(os.Stdout)
	send := func(v any) { _ = out.Encode(v) }
	notify := func(method string, params any) { send(map[string]any{"method": method, "params": params}) }
	read := func() map[string]any {
		if !in.Scan() {
			os.Exit(0)
		}
		var m map[string]any
		_ = json.Unmarshal(in.Bytes(), &m)
		return m
	}
	fmt.Fprintln(os.Stderr, "fake app-server starting; codex_home="+os.Getenv("CODEX_HOME")+" dieter="+os.Getenv("DIETER_HOME")+" codexvar="+os.Getenv("CODEX_LEAK"))
	var cwd string
	turns := 0
	for {
		m := read()
		id, method := m["id"], m["method"]
		params, _ := m["params"].(map[string]any)
		switch method {
		case "initialize":
			send(map[string]any{"id": id, "result": map[string]any{"userAgent": "fake"}})
		case "thread/start":
			cwd, _ = params["cwd"].(string)
			if r, err := filepath.EvalSymlinks(cwd); err == nil {
				cwd = r // like Codex: canonical cwd
			}
			send(map[string]any{"id": id, "result": map[string]any{
				"thread": map[string]any{"id": "th1"}, "cwd": cwd,
				"approvalPolicy": "never", "sandbox": map[string]any{"type": "dangerFullAccess"},
			}})
		case "turn/interrupt":
			send(map[string]any{"id": id, "result": map[string]any{}})
			notify("turn/completed", map[string]any{"threadId": "th1", "turn": map[string]any{"id": "tu3", "status": "interrupted", "error": nil}})
		case "turn/start":
			turns++
			tid := fmt.Sprintf("tu%d", turns)
			notify("turn/started", map[string]any{"threadId": "th1", "turn": map[string]any{"id": tid}})
			send(map[string]any{"id": id, "result": map[string]any{"turn": map[string]any{"id": tid}}})
			switch turns {
			case 1:
				send(map[string]any{"id": "srv-1", "method": "item/fileChange/requestApproval", "params": map[string]any{"threadId": "th1", "turnId": tid}})
				reply := read()
				res, _ := reply["result"].(map[string]any)
				if reply["id"] != "srv-1" || res["decision"] != "accept" {
					notify("error", map[string]any{"threadId": "th1", "turnId": tid, "willRetry": false, "error": map[string]any{"message": "approval not accepted"}})
				}
				item := func(it map[string]any) {
					notify("item/completed", map[string]any{"threadId": "th1", "turnId": tid, "item": it})
				}
				ch := func(path, kind string, move any) map[string]any {
					k := map[string]any{"type": kind}
					if kind == "update" {
						k["move_path"] = move
					}
					return map[string]any{"path": path, "kind": k, "diff": ""}
				}
				item(map[string]any{"type": "fileChange", "id": "fc1", "status": "completed", "changes": []any{
					ch(cwd+"/greeting.txt", "update", nil),
					ch("new.txt", "add", nil),
					ch(cwd+"/old.txt", "update", cwd+"/moved.txt"),
					ch(cwd+"/gone.txt", "delete", nil),
					ch(cwd+"/new.txt", "update", nil), // added then edited: still added
				}})
				item(map[string]any{"type": "fileChange", "id": "fc2", "status": "failed", "changes": []any{ch(cwd+"/fail.txt", "add", nil)}})
				item(map[string]any{"type": "commandExecution", "id": "c1", "status": "completed", "exitCode": 0, "command": "/bin/zsh -lc \"sed -i '' 's/a/b/' other.txt\""})
				item(map[string]any{"type": "commandExecution", "id": "c2", "status": "failed", "exitCode": 1, "command": "false"})
				notify("item/completed", map[string]any{"threadId": "other", "turnId": "x", "item": map[string]any{"type": "fileChange", "id": "fz", "status": "completed", "changes": []any{ch("/elsewhere", "add", nil)}}})
				notify("turn/diff/updated", map[string]any{"threadId": "th1", "turnId": tid, "diff": "diff --git a/greeting.txt b/greeting.txt\n"})
				notify("turn/diff/updated", map[string]any{"threadId": "th1", "turnId": tid, "diff": "diff --git a/greeting.txt b/greeting.txt\n--- a/greeting.txt\n+++ b/greeting.txt\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+x\n"})
				notify("thread/tokenUsage/updated", map[string]any{"threadId": "th1", "turnId": tid, "tokenUsage": map[string]any{"total": map[string]any{"totalTokens": 42}}})
				notify("account/updated", map[string]any{"leak": fakeJWT(time.Now().Add(time.Hour))})
				notify("rawResponseItem/completed", map[string]any{"threadId": "th1", "turnId": tid, "item": map[string]any{"type": "custom_tool_call", "name": "exec", "input": "tools.apply_patch(...)"}})
				notify("rawResponseItem/completed", map[string]any{"threadId": "th1", "turnId": tid, "item": map[string]any{"type": "custom_tool_call_output", "output": []any{
					map[string]any{"type": "input_text", "text": "Script failed\nWall time 0.0 seconds"},
					map[string]any{"type": "input_text", "text": "apply_patch verification failed: Failed to find expected lines"},
				}}})
				item(map[string]any{"type": "agentMessage", "id": "m1", "text": "DONE"})
				notify("turn/completed", map[string]any{"threadId": "th1", "turn": map[string]any{"id": tid, "status": "completed", "error": nil}})
			case 2:
				notify("turn/completed", map[string]any{"threadId": "th1", "turn": map[string]any{"id": tid, "status": "failed", "error": map[string]any{"message": "boom"}}})
			case 3:
				// hang until turn/interrupt
			}
		}
	}
}

func TestDriverAgainstFakeServer(t *testing.T) {
	dir := t.TempDir()
	home := t.TempDir()
	logDir := t.TempDir()
	t.Setenv("DIETER_HOME", "/must/not/leak")
	t.Setenv("CODEX_LEAK", "leaked")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	drv, err := New(context.Background(), Config{
		CodexBin:    exe,
		CodexHome:   home,
		Model:       "fake-model",
		Launcher:    core.Launcher{Dir: dir, Env: []string{"CODEXDRV_FAKE_SERVER=1"}},
		TurnTimeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	d := drv.(*driver)
	pgid := d.pgid

	log1 := filepath.Join(logDir, "t1.jsonl")
	res, err := drv.Turn(context.Background(), core.TurnInput{Steps: []core.Step{{Tool: "shell", Command: "true"}}, LogPath: log1})
	if err != nil || res.Error != "" {
		t.Fatalf("turn 1: %v %q", err, res.Error)
	}
	want := core.ChangeSet{
		"greeting.txt": {Path: "greeting.txt", Kind: core.Modified},
		"new.txt":      {Path: "new.txt", Kind: core.Added},
		"old.txt":      {Path: "old.txt", Kind: core.Deleted},
		"moved.txt":    {Path: "moved.txt", Kind: core.Added},
		"gone.txt":     {Path: "gone.txt", Kind: core.Deleted},
	}
	if !reflect.DeepEqual(res.Reported, want) {
		t.Fatalf("reported %v", res.Reported)
	}
	if got := res.Detail["turnDiffPaths"]; !reflect.DeepEqual(got, []string{"greeting.txt", "new.txt"}) {
		t.Errorf("turnDiffPaths %v", got)
	}
	if res.Detail["turnDiffUpdates"] != 2 || res.Detail["fileChangeItems"] != 2 || res.Detail["commandExecutions"] != 2 {
		t.Errorf("counters %v", res.Detail)
	}
	if fi := res.Detail["failedItems"].([]string); len(fi) != 2 {
		t.Errorf("failedItems %v", fi)
	}
	if res.Detail["otherThreadEvents"] != 1 || res.Detail["turnId"] != "tu1" || res.Detail["threadId"] != "th1" {
		t.Errorf("detail %v", res.Detail)
	}
	if res.Detail["tokenUsage"] == nil || res.Detail["agentMessage"] != "DONE" {
		t.Errorf("detail %v", res.Detail)
	}
	if rc := res.Detail["rawToolCalls"]; !reflect.DeepEqual(rc, []string{"exec"}) {
		t.Errorf("rawToolCalls %v", rc)
	}
	if rf, _ := res.Detail["rawToolFailures"].([]string); len(rf) != 1 || !strings.HasPrefix(rf[0], "Script failed Wall time") {
		t.Errorf("rawToolFailures %q", rf)
	}
	if sr := res.Detail["serverRequests"]; !reflect.DeepEqual(sr, []string{"item/fileChange/requestApproval"}) {
		t.Errorf("serverRequests %v", sr)
	}

	res, err = drv.Turn(context.Background(), core.TurnInput{Prompt: "fail please", LogPath: filepath.Join(logDir, "t2.jsonl")})
	if err != nil || !strings.Contains(res.Error, "failed: boom") {
		t.Fatalf("turn 2: %v %q", err, res.Error)
	}

	res, err = drv.Turn(context.Background(), core.TurnInput{Prompt: "hang", LogPath: filepath.Join(logDir, "t3.jsonl")})
	if err != nil || !strings.Contains(res.Error, "timed out") || res.Detail["turnStatus"] != "interrupted" {
		t.Fatalf("turn 3: %v %q %v", err, res.Error, res.Detail)
	}

	if err := drv.Close(); err != nil {
		t.Fatal(err)
	}
	if syscall.Kill(-pgid, 0) == nil {
		t.Fatal("process group still alive after Close")
	}

	raw, err := os.ReadFile(log1)
	if err != nil {
		t.Fatal(err)
	}
	var sawInit, sawRecv, sawStderr bool
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		var e logEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("bad log line %q", line)
		}
		if e.TS == "" {
			t.Fatal("log entry without timestamp")
		}
		sawInit = sawInit || (e.Dir == "send" && strings.Contains(string(e.Msg), `"initialize"`))
		sawRecv = sawRecv || e.Dir == "recv"
		if e.Dir == "stderr" {
			sawStderr = true
			if !strings.Contains(e.Text, "dieter= ") || !strings.HasSuffix(e.Text, "codexvar=") || !strings.Contains(e.Text, "codex_home="+home) {
				t.Errorf("child env not scrubbed: %s", e.Text)
			}
		}
	}
	if !sawInit || !sawRecv || !sawStderr {
		t.Errorf("log missing entries: init=%v recv=%v stderr=%v", sawInit, sawRecv, sawStderr)
	}
	if strings.Contains(string(raw), "eyJ") || !strings.Contains(string(raw), "[REDACTED-JWT]") {
		t.Error("JWT not redacted in log")
	}
	if st, _ := os.Stat(log1); st.Mode().Perm() != 0o600 {
		t.Errorf("log mode %v", st.Mode().Perm())
	}
}

func TestRespondTo(t *testing.T) {
	for method, want := range map[string]string{
		"item/commandExecution/requestApproval": `{"decision":"accept"}`,
		"item/fileChange/requestApproval":       `{"decision":"accept"}`,
		"applyPatchApproval":                    `{"decision":"approved"}`,
		"execCommandApproval":                   `{"decision":"approved"}`,
	} {
		res, rerr := respondTo(method, nil)
		b, _ := json.Marshal(res)
		if rerr != nil || string(b) != want {
			t.Errorf("%s: %s %v", method, b, rerr)
		}
	}
	res, _ := respondTo("item/permissions/requestApproval", json.RawMessage(`{"permissions":{"network":{"enabled":true},"fileSystem":null}}`))
	if b, _ := json.Marshal(res); string(b) != `{"permissions":{"network":{"enabled":true}},"scope":"session"}` {
		t.Errorf("permissions: %s", b)
	}
	if _, rerr := respondTo("account/chatgptAuthTokens/refresh", nil); rerr == nil {
		t.Error("token refresh request was answered")
	}
}

func TestChildEnv(t *testing.T) {
	env := childEnv([]string{"PATH=/bin", "DIETER_TURN_TOKEN=x", "DIETER_HOME=y", "DIETER_CARD_ID=z", "CODEX_HOME=/real", "CODEX_SANDBOX=1", "OPENAI_API_KEY=k", "HOME=/h"},
		Config{CodexHome: "/spike", Launcher: core.Launcher{Env: []string{"EXTRA=1"}}})
	want := []string{"PATH=/bin", "HOME=/h", "CODEX_HOME=/spike", "EXTRA=1"}
	if !reflect.DeepEqual(env, want) {
		t.Fatalf("got %q", env)
	}
}
