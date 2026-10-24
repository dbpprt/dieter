package claudedrv

import (
	"context"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
)

// TestLiveClaudeTurns runs two real Claude Code turns (one resumed session)
// against a scratch git repository. Opt in with CLAUDEDRV_LIVE=1.
func TestLiveClaudeTurns(t *testing.T) {
	if os.Getenv("CLAUDEDRV_LIVE") != "1" {
		t.Skip("set CLAUDEDRV_LIVE=1 to run real Claude turns")
	}
	scratch := envOr("CLAUDEDRV_SCRATCH", "/Volumes/External/dieter-spike/claudedrv-dev")
	nodeDir := envOr("CLAUDEDRV_NODE_DIR", "/Volumes/External/dieter-spike/node")
	stamp := time.Now().Format("20060102-150405")
	repo := filepath.Join(scratch, "repo")
	configDir := filepath.Join(scratch, "config-"+stamp)
	logPath := filepath.Join(scratch, "live-"+stamp+".jsonl")

	if err := os.RemoveAll(repo); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"README.md":     "# scratch\n",
		"notes.txt":     "alpha\nbeta\n",
		"other.txt":     "a line\n",
		"remove-me.txt": "bye\n",
	}
	for p, c := range files {
		if err := os.WriteFile(filepath.Join(repo, p), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	git(t, repo, "init", "-q", "-b", "main")
	git(t, repo, "config", "user.name", "claudedrv spike")
	git(t, repo, "config", "user.email", "spike@example.invalid")
	git(t, repo, "add", "-A")
	git(t, repo, "commit", "-q", "-m", "init")

	keychainBefore := keychainCount(t)

	d, err := New(context.Background(), Config{
		NodeDir:     nodeDir,
		ConfigDir:   configDir,
		Model:       os.Getenv("CLAUDEDRV_MODEL"),
		Launcher:    core.Launcher{Dir: repo},
		TurnTimeout: 6 * time.Minute,
		MaxTurns:    20,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	turns := [][]core.Step{
		{
			{Tool: "edit", Path: "notes.txt", Old: "alpha", New: "omega"},
			{Tool: "shell", Command: "sed -i '' 's/a/b/' other.txt"},
			{Tool: "shell", Command: "printf 'x\\n' > new-from-shell.txt"},
		},
		{
			{Tool: "edit", Path: "created-by-tool.txt", Create: true, Content: "hello from the file tool"},
			{Tool: "shell", Command: "rm remove-me.txt"},
		},
	}
	for i, steps := range turns {
		res, err := d.Turn(context.Background(), core.TurnInput{Prompt: core.RenderPrompt(steps), Steps: steps, LogPath: logPath})
		t.Logf("turn %d: duration=%s err=%v", i+1, res.Duration.Round(time.Millisecond), err)
		t.Logf("turn %d: reported=%s", i+1, compactChanges(res.Reported))
		t.Logf("turn %d: git status=%s", i+1, strings.Join(strings.Fields(git(t, repo, "status", "--porcelain")), " "))
		for _, k := range []string{"sessionId", "model", "apiKeySource", "permissionMode", "claudeCodeVersion", "fileAndShellTools", "toolCalls", "bashCalls", "bashEditDiffPresent", "fileToolSources", "subagentEdits", "failedEdits", "outsidePaths", "netZero", "costUSD", "numTurns", "tokenMinutesLeft", "tokenRefreshedViaCLI"} {
			if v, ok := res.Detail[k]; ok {
				t.Logf("turn %d: %s=%s", i+1, k, mustJSON(v))
			}
		}
		if bash, ok := res.Detail["bashEditDiff"].([]map[string]any); ok {
			for _, b := range bash {
				t.Logf("turn %d: bashEditDiff %s", i+1, mustJSON(b))
			}
		}
		if err != nil {
			t.Fatalf("turn %d failed: %v", i+1, err)
		}
	}

	var listing []string
	filepath.WalkDir(configDir, func(p string, e fs.DirEntry, err error) error {
		if err != nil || p == configDir {
			return nil
		}
		rel, _ := filepath.Rel(configDir, p)
		if e.IsDir() {
			listing = append(listing, rel+"/")
			if strings.Count(rel, string(filepath.Separator)) >= 3 {
				return filepath.SkipDir
			}
			return nil
		}
		info, _ := e.Info()
		listing = append(listing, rel+" ("+mustJSON(info.Size())+"B)")
		return nil
	})
	t.Logf("CLAUDE_CONFIG_DIR %s:\n  %s", configDir, strings.Join(listing, "\n  "))
	if after := keychainCount(t); after != keychainBefore {
		t.Errorf("keychain 'Claude Code-credentials' lines: before=%d after=%d", keychainBefore, after)
	} else {
		t.Logf("keychain 'Claude Code-credentials' lines unchanged: %d", after)
	}
	t.Logf("log: %s", logPath)
}

func keychainCount(t *testing.T) int {
	if runtime.GOOS != "darwin" {
		return -1
	}
	out, _ := exec.Command("security", "dump-keychain").Output() // attributes only, no secrets
	return strings.Count(string(out), "Claude Code-credentials")
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func compactChanges(cs core.ChangeSet) string {
	var parts []string
	for _, p := range cs.Paths() {
		parts = append(parts, p+":"+string(cs[p].Kind))
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
