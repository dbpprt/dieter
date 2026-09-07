package gitexec

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBackgroundReadsDoNotRewriteIndexButStagingStillWorks(t *testing.T) {
	t.Setenv("GIT_OPTIONAL_LOCKS", "1")
	directory := t.TempDir()
	runner := ExecRunner{}
	run := func(args ...string) {
		t.Helper()
		if _, err := runner.Run(context.Background(), directory, args...); err != nil {
			t.Fatal(err)
		}
	}
	run("init")
	run("config", "user.name", "Test")
	run("config", "user.email", "test@example.invalid")
	file := filepath.Join(directory, "file.txt")
	if err := os.WriteFile(file, []byte("initial\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	run("add", "file.txt")
	run("commit", "-m", "initial")
	index := filepath.Join(directory, ".git", "index")
	before, err := os.ReadFile(index)
	if err != nil {
		t.Fatal(err)
	}
	// Same contents, different stat data: ordinary git status refreshes and
	// rewrites the index, potentially holding index.lock during a user action.
	stamp := time.Now().Add(-time.Hour)
	if err := os.Chtimes(file, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	run("status", "--porcelain=v1")
	afterStatus, err := os.ReadFile(index)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, afterStatus) {
		t.Fatal("background status rewrote the index")
	}
	run("diff", "--numstat")
	after, err := os.ReadFile(index)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("a background read rewrote the index")
	}
	if err := os.WriteFile(file, []byte("edited\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	run("add", "file.txt")
	result, err := runner.Run(context.Background(), directory, "show", ":file.txt")
	if err != nil || string(result.Output) != "edited\n" {
		t.Fatalf("required index mutation failed: %q, %v", result.Output, err)
	}
}
