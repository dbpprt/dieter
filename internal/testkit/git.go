package testkit

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// GitRepo returns a Git repository on branch main with a test identity and
// one commit adding README.md ("base\n").
func GitRepo(tb testing.TB) string {
	tb.Helper()
	root := EmptyGitRepo(tb)
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("base\n"), 0o644); err != nil {
		tb.Fatal(err)
	}
	RunGit(tb, root, "add", "README.md")
	RunGit(tb, root, "commit", "-m", "base")
	return root
}

// EmptyGitRepo returns an initialized Git repository on branch main with a
// test identity and no commits.
func EmptyGitRepo(tb testing.TB) string {
	tb.Helper()
	root := filepath.Join(tb.TempDir(), "repository")
	InitGitRepo(tb, root)
	return root
}

// InitGitRepo initializes path as a Git repository on branch main with a
// test identity and no commits.
func InitGitRepo(tb testing.TB, path string) {
	tb.Helper()
	RunGit(tb, "", "init", "-q", "-b", "main", path)
	RunGit(tb, path, "config", "user.name", "Dieter Test")
	RunGit(tb, path, "config", "user.email", "dieter@example.test")
}

// CheckoutDir returns a directory that registers as a project checkout (it
// has a .git directory and a README.md) for tests that never run Git.
func CheckoutDir(tb testing.TB) string {
	tb.Helper()
	root := filepath.Join(tb.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("# Fixture\n"), 0o644); err != nil {
		tb.Fatal(err)
	}
	return root
}

// RunGit runs git in directory and returns its trimmed combined output. The
// operator's global and system Git configuration (signing, hooks, templates)
// never applies, and Git never prompts.
func RunGit(tb testing.TB, directory string, args ...string) string {
	tb.Helper()
	command := exec.Command("git", args...)
	command.Dir = directory
	command.Env = GitEnvironment(os.Environ())
	output, err := command.CombinedOutput()
	if err != nil {
		tb.Fatalf("git %s: %s: %v", strings.Join(args, " "), output, err)
	}
	return strings.TrimSpace(string(output))
}

// GitEnvironment isolates Git invocations from the operator's configuration
// and supplies a test identity for repositories without one (fresh clones).
func GitEnvironment(environment []string) []string {
	return append(environment,
		"GIT_CONFIG_GLOBAL="+os.DevNull,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_AUTHOR_NAME=Dieter Test",
		"GIT_AUTHOR_EMAIL=dieter@example.test",
		"GIT_COMMITTER_NAME=Dieter Test",
		"GIT_COMMITTER_EMAIL=dieter@example.test",
	)
}
