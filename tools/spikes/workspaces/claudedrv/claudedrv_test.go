package claudedrv

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
)

func TestAccumulatorReportsFileToolsAndBashEditDiff(t *testing.T) {
	dir := t.TempDir()
	roots := rootsOf(dir)
	abs := func(p string) string { return filepath.Join(dir, p) }
	lines := []any{
		map[string]any{"type": "system", "subtype": "init", "session_id": "s1", "model": "m", "permissionMode": "bypassPermissions", "apiKeySource": "none", "tools": []string{"Bash", "Edit", "Write", "Read"}},
		// a replayed frame must not count
		map[string]any{"type": "user", "isReplay": true, "session_id": "s1", "message": map[string]any{"content": []any{map[string]any{"type": "tool_result", "tool_use_id": "old"}}}},
		assistantToolUse("w1", "Write", map[string]any{"file_path": abs("new.txt"), "content": "x"}, nil),
		hookLine("PostToolUse", "Write", "w1", "", map[string]any{"type": "create", "filePath": abs("new.txt")}),
		toolResult("w1", false, map[string]any{"type": "create", "filePath": abs("new.txt")}),
		assistantToolUse("e1", "Edit", map[string]any{"file_path": abs("a.txt")}, nil),
		toolResult("e1", false, map[string]any{"filePath": abs("a.txt"), "oldString": "a", "originalFile": "a\n"}),
		assistantToolUse("e2", "Edit", map[string]any{"file_path": abs("missing.txt")}, nil),
		hookLine("PostToolUseFailure", "Edit", "e2", "", nil),
		toolResult("e2", true, "File does not exist."),
		assistantToolUse("b1", "Bash", map[string]any{"command": "sed -i '' s/a/b/ other.txt; rm gone.txt"}, nil),
		hookLine("PostToolUse", "Bash", "b1", "", map[string]any{"stdout": "", "bashEditDiff": map[string]any{
			"files": []any{
				map[string]any{"filePath": abs("other.txt"), "hunks": []any{map[string]any{}}},
				map[string]any{"filePath": abs("gone.txt"), "hunks": []any{}, "deleted": true},
			},
			"moreFiles":    1,
			"changedFiles": []string{abs("other.txt"), abs("gone.txt"), abs("bin.dat"), "/elsewhere/x"},
		}}),
		toolResult("b1", false, map[string]any{"stdout": ""}),
		assistantToolUse("b2", "Bash", map[string]any{"command": "true"}, nil),
		hookLine("PostToolUse", "Bash", "b2", "", map[string]any{"stdout": ""}),
		// subagent creates then the parent deletes the same file: net zero
		assistantToolUse("w2", "Write", map[string]any{"file_path": abs("tmp.txt")}, strPtr("task1")),
		hookLine("PostToolUse", "Write", "w2", "agent-1", map[string]any{"type": "create", "filePath": abs("tmp.txt")}),
		assistantToolUse("b3", "Bash", map[string]any{"command": "rm tmp.txt"}, nil),
		hookLine("PostToolUse", "Bash", "b3", "", map[string]any{"bashEditDiff": map[string]any{
			"files": []any{map[string]any{"filePath": abs("tmp.txt"), "hunks": []any{}, "deleted": true}}, "moreFiles": 0,
		}}),
		map[string]any{"type": "result", "subtype": "success", "session_id": "s2", "is_error": false, "result": "DONE", "num_turns": 3, "total_cost_usd": 0.01, "usage": map[string]any{"input_tokens": 1}},
		map[string]any{"type": "dieter_end", "code": 0},
	}
	acc := newAccumulator(roots)
	for _, l := range lines {
		b, _ := json.Marshal(l)
		acc.handle(b)
	}
	res := core.TurnResult{Reported: core.ChangeSet{}, Detail: map[string]any{}}
	acc.finish(&res)

	want := map[string]core.ChangeKind{
		"new.txt":   core.Added,
		"a.txt":     core.Modified,
		"other.txt": core.Modified,
		"gone.txt":  core.Deleted,
		"bin.dat":   core.Changed,
	}
	if len(res.Reported) != len(want) {
		t.Fatalf("reported %v, want %v", res.Reported, want)
	}
	for p, k := range want {
		if res.Reported[p].Kind != k {
			t.Errorf("%s: kind %q, want %q", p, res.Reported[p].Kind, k)
		}
	}
	if acc.sessionID != "s2" || !acc.sawResult || acc.resultIsError {
		t.Fatalf("session/result: %q %v %v", acc.sessionID, acc.sawResult, acc.resultIsError)
	}
	if tc := res.Detail["toolCalls"].(map[string]int); tc["Write"] != 2 || tc["Edit"] != 2 || tc["Bash"] != 3 {
		t.Errorf("toolCalls %v", tc)
	}
	if res.Detail["bashEditDiffPresent"] != 2 {
		t.Errorf("bashEditDiffPresent %v", res.Detail["bashEditDiffPresent"])
	}
	if se := res.Detail["subagentEdits"].([]map[string]any); len(se) != 1 || se[0]["path"] != "tmp.txt" {
		t.Errorf("subagentEdits %v", se)
	}
	if fe, _ := res.Detail["failedEdits"].([]map[string]any); len(fe) != 1 {
		t.Errorf("failedEdits %v", fe)
	}
	if nz, _ := res.Detail["netZero"].([]string); len(nz) != 1 || nz[0] != "tmp.txt" {
		t.Errorf("netZero %v", nz)
	}
	if out, _ := res.Detail["outsidePaths"].([]string); len(out) != 1 || out[0] != "/elsewhere/x" {
		t.Errorf("outsidePaths %v", out)
	}
	if res.Detail["replayedMessages"] != 1 {
		t.Errorf("replayed %v", res.Detail["replayedMessages"])
	}
}

func TestRelPathResolvesSymlinkedRoot(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	if err := os.MkdirAll(filepath.Join(real, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	roots := rootsOf(link)
	realReal, _ := filepath.EvalSymlinks(real)
	cases := map[string]string{
		filepath.Join(link, "sub", "f.txt"):            "sub/f.txt",
		filepath.Join(realReal, "sub", "f.txt"):        "sub/f.txt",
		filepath.Join(realReal, "gone", "deep", "f.x"): "gone/deep/f.x", // parent no longer exists
		"rel/x.txt": "rel/x.txt",
	}
	for in, want := range cases {
		got, ok := relPath(roots, in)
		if !ok || got != want {
			t.Errorf("relPath(%q) = %q,%v want %q", in, got, ok, want)
		}
	}
	if _, ok := relPath(roots, filepath.Join(base, "other", "x")); ok {
		t.Error("path outside the root reported inside")
	}
}

func TestAccessTokenFromFile(t *testing.T) {
	f := filepath.Join(t.TempDir(), "c.json")
	exp := time.Now().Add(time.Hour).Truncate(time.Millisecond)
	os.WriteFile(f, []byte(`{"claudeAiOauth":{"accessToken":"tok-1","expiresAt":`+itoa64(exp.UnixMilli())+`}}`), 0o600)
	tok, got, err := AccessToken(f)
	if err != nil || tok != "tok-1" || !got.Equal(exp) {
		t.Fatalf("AccessToken = %q %v %v", tok, got, err)
	}
	os.WriteFile(f, []byte(`{"claudeAiOauth":{"accessToken":"tok-1","expiresAt":`+itoa64(time.Now().Add(time.Minute).UnixMilli())+`}}`), 0o600)
	if _, _, _, err := freshToken(context.Background(), f); err == nil {
		t.Fatal("expiring file token accepted")
	}
	os.WriteFile(f, []byte(`{"other":{}}`), 0o600)
	if _, _, err := AccessToken(f); err == nil {
		t.Fatal("missing token accepted")
	}
}

// TestTurnWithFakeNode runs Turn end to end against a shell script standing
// in for node: request shape, resume, child environment, log redaction.
func TestTurnWithFakeNode(t *testing.T) {
	tmp := t.TempDir()
	work := filepath.Join(tmp, "work")
	os.MkdirAll(work, 0o755)
	cred := filepath.Join(tmp, "cred.json")
	os.WriteFile(cred, []byte(`{"claudeAiOauth":{"accessToken":"sekrit-token-value","expiresAt":`+itoa64(time.Now().Add(time.Hour).UnixMilli())+`}}`), 0o600)
	fake := filepath.Join(tmp, "fake-node")
	os.WriteFile(fake, []byte(`#!/bin/sh
n=$(ls "$FAKE_OUT" | wc -l | tr -d ' ')
cat > "$FAKE_OUT/req-$n.json"
env > "$FAKE_OUT/env-$n.txt"
printf '{"type":"system","subtype":"init","session_id":"sess-%s"}\n' "$n"
printf '{"type":"assistant","session_id":"sess-%s","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"t%s","name":"Write","input":{"file_path":"%s/f%s.txt"}}]}}\n' "$n" "$n" "$PWD" "$n"
printf '{"type":"user","session_id":"sess-%s","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t%s"}]},"tool_use_result":{"type":"create","filePath":"%s/f%s.txt"}}\n' "$n" "$n" "$PWD" "$n"
printf '{"type":"leak","v":"%s"}\n' "$CLAUDE_CODE_OAUTH_TOKEN"
printf '{"type":"result","subtype":"success","is_error":false,"result":"DONE","session_id":"sess-%s"}\n' "$n"
`), 0o755)
	out := filepath.Join(tmp, "out")
	os.MkdirAll(out, 0o755)
	t.Setenv("DIETER_HOME", "/must/not/leak")
	t.Setenv("ANTHROPIC_API_KEY", "must-not-leak")
	d, err := New(context.Background(), Config{
		Node: fake, NodeDir: filepath.Join(tmp, "node"), ConfigDir: filepath.Join(tmp, "cfg"),
		CredentialsFile: cred,
		Launcher:        core.Launcher{Dir: work, Env: []string{"FAKE_OUT=" + out}},
	})
	if err == nil {
		t.Fatal("New accepted a missing NodeDir")
	}
	os.MkdirAll(filepath.Join(tmp, "node"), 0o755)
	d, err = New(context.Background(), Config{
		Node: fake, NodeDir: filepath.Join(tmp, "node"), ConfigDir: filepath.Join(tmp, "cfg"),
		CredentialsFile: cred,
		Launcher:        core.Launcher{Dir: work, Env: []string{"FAKE_OUT=" + out}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	logPath := filepath.Join(tmp, "turns.jsonl")
	for i := 0; i < 2; i++ {
		res, err := d.Turn(context.Background(), core.TurnInput{Steps: []core.Step{{Tool: "shell", Command: "true"}}, LogPath: logPath})
		if err != nil {
			t.Fatalf("turn %d: %v", i, err)
		}
		want := "f" + itoa64(int64(i*2)) + ".txt" // FAKE_OUT gains two files per turn
		if res.Reported[want].Kind != core.Added || len(res.Reported) != 1 {
			t.Fatalf("turn %d reported %v, want %s added", i, res.Reported, want)
		}
	}
	var req0, req1 map[string]any
	readJSON(t, filepath.Join(out, "req-0.json"), &req0)
	readJSON(t, filepath.Join(out, "req-2.json"), &req1)
	if req0["resume"] != nil || req1["resume"] != "sess-0" || req0["cwd"] != work || req0["model"] != "claude-sonnet-5-5" || !strings.Contains(req0["prompt"].(string), "automated filesystem test") {
		t.Fatalf("requests: %v / %v", req0, req1)
	}
	env, _ := os.ReadFile(filepath.Join(out, "env-0.txt"))
	for _, bad := range []string{"DIETER_HOME=", "ANTHROPIC_API_KEY="} {
		if strings.Contains(string(env), bad) {
			t.Errorf("child env contains %s", bad)
		}
	}
	for _, good := range []string{"CLAUDE_CONFIG_DIR=" + filepath.Join(tmp, "cfg"), "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1", "CLAUDE_CODE_OAUTH_TOKEN="} {
		if !strings.Contains(string(env), good) {
			t.Errorf("child env lacks %s", good)
		}
	}
	logData, _ := os.ReadFile(logPath)
	if strings.Contains(string(logData), "sekrit-token-value") || !strings.Contains(string(logData), "[REDACTED]") {
		t.Fatal("token not redacted from the log")
	}
	if _, err := os.Stat(filepath.Join(tmp, "node", ScriptName)); err != nil {
		t.Fatal(err)
	}
}

func TestDriverScriptParses(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not installed")
	}
	f := filepath.Join(t.TempDir(), "d.mjs")
	os.WriteFile(f, driverScript, 0o644)
	if out, err := exec.Command(node, "--check", f).CombinedOutput(); err != nil {
		t.Fatalf("node --check: %v\n%s", err, out)
	}
}

func assistantToolUse(id, name string, input map[string]any, parent *string) map[string]any {
	return map[string]any{"type": "assistant", "session_id": "s1", "parent_tool_use_id": parent,
		"message": map[string]any{"content": []any{map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}}}}
}

func toolResult(id string, isErr bool, structured any) map[string]any {
	return map[string]any{"type": "user", "session_id": "s1", "parent_tool_use_id": nil,
		"message":         map[string]any{"content": []any{map[string]any{"type": "tool_result", "tool_use_id": id, "is_error": isErr}}},
		"tool_use_result": structured}
}

func hookLine(hook, tool, id, agent string, resp any) map[string]any {
	in := map[string]any{"hook_event_name": hook, "tool_name": tool, "tool_use_id": id, "tool_response": resp}
	if agent != "" {
		in["agent_id"] = agent
	}
	return map[string]any{"type": "dieter_hook", "hook": hook, "input": in}
}

func readJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatal(err)
	}
}

func strPtr(s string) *string { return &s }

func itoa64(n int64) string { b, _ := json.Marshal(n); return string(b) }
