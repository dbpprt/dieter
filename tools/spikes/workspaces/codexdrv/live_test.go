package codexdrv

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
)

// TestLiveCodex runs two real Codex turns against a scratch git repo.
// Gated: CODEXDRV_LIVE=1. Scratch root: CODEXDRV_SCRATCH (default
// /Volumes/External/dieter-spike/codexdrv-dev).
func TestLiveCodex(t *testing.T) {
	if os.Getenv("CODEXDRV_LIVE") != "1" {
		t.Skip("set CODEXDRV_LIVE=1 to run real Codex turns")
	}
	scratch := os.Getenv("CODEXDRV_SCRATCH")
	if scratch == "" {
		scratch = "/Volumes/External/dieter-spike/codexdrv-dev"
	}
	repo := filepath.Join(scratch, "repo")
	home := filepath.Join(scratch, "codex-home")
	logs := filepath.Join(scratch, "logs")
	for _, p := range []string{repo, home, logs} {
		if err := os.RemoveAll(p); err != nil {
			t.Fatal(err)
		}
	}
	setupRepo(t, repo)

	opHome, err := OperatorCodexHome()
	if err != nil {
		t.Fatal(err)
	}
	authBefore := fileDigest(t, filepath.Join(opHome, "auth.json"))
	if err := PrepareHome(home); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	drv, err := New(ctx, Config{
		CodexBin:    os.Getenv("CODEXDRV_CODEX_BIN"),
		CodexHome:   home,
		Launcher:    core.Launcher{Dir: repo},
		TurnTimeout: 5 * time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := drv.Close(); err != nil {
			t.Error(err)
		}
		if after := fileDigest(t, filepath.Join(opHome, "auth.json")); after != authBefore {
			t.Error("operator ~/.codex/auth.json changed during the run")
		} else {
			t.Log("operator ~/.codex/auth.json unchanged (sha256 + mtime)")
		}
	}()

	turns := [][]core.Step{
		{
			// apply_patch matches whole lines; a partial-line Old made the
			// model's patch fail verification in the first live run.
			{Tool: "edit", Path: "greeting.txt", Old: "Hello, old friend.", New: "Hello, new friend."},
			{Tool: "shell", Command: "sed -i '' 's/a/b/' other.txt"},
			{Tool: "shell", Command: "printf 'x\\n' > new-from-shell.txt"},
		},
		{
			{Tool: "edit", Path: "created-by-edit.txt", Create: true, Content: "created by the edit tool"},
			{Tool: "shell", Command: "rm notes.txt"},
		},
	}
	for i, steps := range turns {
		res, err := drv.Turn(ctx, core.TurnInput{
			Prompt:  core.RenderPrompt(steps),
			Steps:   steps,
			LogPath: filepath.Join(logs, fmt.Sprintf("turn%d.jsonl", i+1)),
		})
		t.Logf("turn %d: duration=%s status=%v error=%q", i+1, res.Duration.Round(time.Millisecond), res.Detail["turnStatus"], res.Error)
		for _, p := range res.Reported.Paths() {
			t.Logf("  reported   %-8s %s", res.Reported[p].Kind, p)
		}
		for _, k := range []string{"fileChanges", "turnDiffPaths", "turnDiffUpdates", "commands", "commandExecutions", "failedItems", "rawToolCalls", "rawToolFailures", "errors", "warnings", "serverRequests", "outsidePaths", "agentMessage"} {
			if v, ok := res.Detail[k]; ok {
				t.Logf("  %-17s %v", k, v)
			}
		}
		if tu, ok := res.Detail["tokenUsage"].(map[string]any); ok {
			t.Logf("  tokenUsage.last  %v", tu["last"])
		}
		t.Logf("  git status:\n%s", gitOut(t, repo, "status", "--porcelain", "--untracked-files=all"))
		if err != nil {
			t.Fatalf("turn %d: %v", i+1, err)
		}
		if res.Error != "" {
			t.Errorf("turn %d error: %s", i+1, res.Error)
		}
	}
}

func setupRepo(t *testing.T, repo string) {
	t.Helper()
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"README.md":    "# scratch repo for the codex driver spike\n",
		"greeting.txt": "Hello, old friend.\nSecond line.\n",
		"other.txt":    "banana\napple\n",
		"notes.txt":    "delete me\n",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(repo, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	gitOut(t, repo, "init", "-q", "-b", "main")
	gitOut(t, repo, "config", "user.name", "Codex Driver Spike")
	gitOut(t, repo, "config", "user.email", "spike@example.invalid")
	gitOut(t, repo, "add", "-A")
	gitOut(t, repo, "commit", "-q", "-m", "init")
}

func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out.String())
	}
	return out.String()
}

func fileDigest(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%x/%d", sha256.Sum256(raw), st.ModTime().UnixNano())
}
