package reviewer

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestMain(m *testing.M) {
	// The reviewer's own Git commands inherit the environment: keep the
	// operator's global configuration (signing, hooks) out of the tests.
	os.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	os.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Exit(m.Run())
}

func write(t *testing.T, root, name, content string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestSnapshotCapturesWorkspaceWithoutTouchingIt(t *testing.T) {
	t.Parallel()
	repo := testkit.GitRepo(t)
	write(t, repo, ".gitignore", "build/\n")
	write(t, repo, "staged.go", "package staged\n")
	testkit.RunGit(t, repo, "add", ".gitignore")
	testkit.RunGit(t, repo, "commit", "-m", "ignore build")
	testkit.RunGit(t, repo, "add", "-N", ".gitignore")
	write(t, repo, "README.md", "base\nedited\n")
	testkit.RunGit(t, repo, "add", "staged.go")
	write(t, repo, "notes/untracked.txt", "new file\n")
	write(t, repo, "build/output.bin", "ignored\n")
	headBefore := testkit.RunGit(t, repo, "rev-parse", "HEAD")
	statusBefore := testkit.RunGit(t, repo, "status", "--porcelain")
	indexBefore, err := os.ReadFile(filepath.Join(repo, ".git", "index"))
	if err != nil {
		t.Fatal(err)
	}

	root := filepath.Join(t.TempDir(), "review")
	snapshot, err := TakeSnapshot(context.Background(), repo, root)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Head != headBefore || snapshot.Commit == "" || snapshot.Commit == headBefore {
		t.Fatalf("snapshot head=%s commit=%s, workspace head %s", snapshot.Head, snapshot.Commit, headBefore)
	}
	for name, want := range map[string]string{"README.md": "base\nedited\n", "staged.go": "package staged\n", "notes/untracked.txt": "new file\n"} {
		data, err := os.ReadFile(filepath.Join(snapshot.Dir, filepath.FromSlash(name)))
		if err != nil || string(data) != want {
			t.Fatalf("snapshot %s = %q, %v", name, data, err)
		}
	}
	if _, err := os.Stat(filepath.Join(snapshot.Dir, "build", "output.bin")); !os.IsNotExist(err) {
		t.Fatalf("ignored file reached the snapshot: %v", err)
	}
	if got := testkit.RunGit(t, snapshot.Dir, "rev-parse", "HEAD"); got != snapshot.Commit {
		t.Fatalf("snapshot worktree HEAD=%s, want %s", got, snapshot.Commit)
	}
	if got := testkit.RunGit(t, repo, "rev-parse", "HEAD"); got != headBefore {
		t.Fatalf("workspace HEAD moved to %s", got)
	}
	if got := testkit.RunGit(t, repo, "status", "--porcelain"); got != statusBefore {
		t.Fatalf("workspace status changed:\n%s\nwas\n%s", got, statusBefore)
	}
	if indexAfter, _ := os.ReadFile(filepath.Join(repo, ".git", "index")); string(indexAfter) != string(indexBefore) {
		t.Fatal("the workspace index was rewritten")
	}
	if refs := testkit.RunGit(t, repo, "for-each-ref", "--format=%(refname)"); strings.Contains(refs, snapshot.Commit) || strings.Count(refs, "\n") != 0 {
		t.Fatalf("the snapshot left refs behind: %q", refs)
	}

	snapshot.Close()
	snapshot.Close()
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatalf("snapshot directory remains: %v", err)
	}
	if list := testkit.RunGit(t, repo, "worktree", "list", "--porcelain"); strings.Contains(list, root) {
		t.Fatalf("snapshot worktree is still registered:\n%s", list)
	}
}

func TestSnapshotOfUnbornRepository(t *testing.T) {
	t.Parallel()
	repo := testkit.EmptyGitRepo(t)
	write(t, repo, "first.txt", "hello\n")
	snapshot, err := TakeSnapshot(context.Background(), repo, filepath.Join(t.TempDir(), "review"))
	if err != nil {
		t.Fatal(err)
	}
	defer snapshot.Close()
	if snapshot.Head != "" {
		t.Fatalf("unborn head = %q", snapshot.Head)
	}
	if MergeBase(context.Background(), snapshot.Dir, "main", snapshot.Head) != EmptyTree {
		t.Fatal("an unborn workspace must diff against the empty tree")
	}
	change, err := ReadChange(context.Background(), snapshot.Dir, EmptyTree, snapshot.Tree, nil, 1<<20)
	if err != nil || len(change.Files) != 1 || change.Files[0].Path != "first.txt" || change.Files[0].Status != "modified" && change.Files[0].Status != "added" {
		t.Fatalf("change=%#v err=%v", change.Files, err)
	}
}

func TestMergeBaseChoosesTheChangeStart(t *testing.T) {
	t.Parallel()
	repo := testkit.GitRepo(t)
	base := testkit.RunGit(t, repo, "rev-parse", "HEAD")
	testkit.RunGit(t, repo, "checkout", "-q", "-b", "feature")
	write(t, repo, "feature.txt", "feature\n")
	testkit.RunGit(t, repo, "add", "feature.txt")
	testkit.RunGit(t, repo, "commit", "-m", "feature")
	head := testkit.RunGit(t, repo, "rev-parse", "HEAD")
	testkit.RunGit(t, repo, "checkout", "-q", "main")
	write(t, repo, "main.txt", "main moved on\n")
	testkit.RunGit(t, repo, "add", "main.txt")
	testkit.RunGit(t, repo, "commit", "-m", "main")
	ctx := context.Background()
	if got := MergeBase(ctx, repo, "main", head); got != base {
		t.Fatalf("worktree merge base = %s, want %s", got, base)
	}
	if got := MergeBase(ctx, repo, "", head); got != head {
		t.Fatalf("project checkout base = %s, want HEAD %s", got, head)
	}
	if got := MergeBase(ctx, repo, "main", ""); got != EmptyTree {
		t.Fatalf("unborn base = %s", got)
	}
	orphan := testkit.EmptyGitRepo(t)
	write(t, orphan, "x.txt", "x\n")
	testkit.RunGit(t, orphan, "add", "x.txt")
	testkit.RunGit(t, orphan, "commit", "-m", "x")
	if got := MergeBase(ctx, orphan, "missing-branch", testkit.RunGit(t, orphan, "rev-parse", "HEAD")); got != EmptyTree {
		t.Fatalf("missing base = %s", got)
	}
}

func TestReadChangeRendersNumberedHunksAndDropsIgnoredFiles(t *testing.T) {
	t.Parallel()
	repo := testkit.GitRepo(t)
	write(t, repo, "old/name.go", "package old\n\nfunc A() {}\n")
	write(t, repo, "lib/code.go", "package lib\n\nfunc One() int {\n\treturn 1\n}\n")
	write(t, repo, "image.png", "\x89PNG\x00\x00binary")
	testkit.RunGit(t, repo, "add", ".")
	testkit.RunGit(t, repo, "commit", "-m", "files")
	base := testkit.RunGit(t, repo, "rev-parse", "HEAD")
	if err := os.MkdirAll(filepath.Join(repo, "new"), 0o755); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, repo, "mv", "old/name.go", "new/name.go")
	write(t, repo, "lib/code.go", "package lib\n\nfunc One() int {\n\treturn 2\n}\n")
	write(t, repo, "image.png", "\x89PNG\x00\x00binary changed")
	write(t, repo, "package-lock.json", "{}\n")
	write(t, repo, "gen/deep/x/generated.go", "package x\n")
	write(t, repo, "docs/guide.md", "# Guide\n")
	snapshot, err := TakeSnapshot(context.Background(), repo, filepath.Join(t.TempDir(), "review"))
	if err != nil {
		t.Fatal(err)
	}
	defer snapshot.Close()

	change, err := ReadChange(context.Background(), snapshot.Dir, base, snapshot.Tree, []string{"gen/**", "*.md"}, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]File{}
	for _, file := range change.Files {
		byPath[file.Path] = file
	}
	if len(change.Files) != 3 {
		t.Fatalf("files=%#v ignored=%v", change.Files, change.Ignored)
	}
	if renamed := byPath["new/name.go"]; renamed.Status != "renamed" || renamed.OldPath != "old/name.go" {
		t.Fatalf("rename=%#v", renamed)
	}
	if binary := byPath["image.png"]; !binary.Binary || binary.Inlined {
		t.Fatalf("binary=%#v", binary)
	}
	if code := byPath["lib/code.go"]; code.Additions != 1 || code.Removed != 1 || !code.Inlined {
		t.Fatalf("code=%#v", code)
	}
	for _, ignored := range []string{"package-lock.json", "gen/deep/x/generated.go", "docs/guide.md"} {
		if change.HasFile(ignored) || !strings.Contains(strings.Join(change.Ignored, ","), ignored) {
			t.Fatalf("%s not ignored: %v", ignored, change.Ignored)
		}
	}
	if !strings.Contains(change.Rendered, "## File: lib/code.go") ||
		!strings.Contains(change.Rendered, "    4 +\treturn 2") ||
		!strings.Contains(change.Rendered, "      -\treturn 1") ||
		!strings.Contains(change.Rendered, "    3  func One() int {") {
		t.Fatalf("rendered diff:\n%s", change.Rendered)
	}
	if !strings.Contains(change.Rendered, "## File: new/name.go (renamed from old/name.go)") {
		t.Fatalf("rename header missing:\n%s", change.Rendered)
	}

	small, err := ReadChange(context.Background(), snapshot.Dir, base, snapshot.Tree, []string{"gen/**", "*.md"}, 10)
	if err != nil || !small.Truncated || small.Rendered != "" {
		t.Fatalf("budgeted change truncated=%v rendered=%q err=%v", small.Truncated, small.Rendered, err)
	}
	prompt := Prompt(small, Options{Depth: model.CodeReviewDepthQuick, MaxFindings: 6}, nil)
	if !strings.Contains(prompt, "lib/code.go (modified, +1 -1) diff not inlined") || !strings.Contains(prompt, "git diff "+base+" HEAD -- PATH") {
		t.Fatalf("prompt for a truncated change:\n%s", prompt)
	}
}

func TestParseNumstat(t *testing.T) {
	t.Parallel()
	files := parseNumstat([]byte("3\t1\tsrc/a.go\x00-\t-\timg.png\x002\t0\t\x00old.go\x00new.go\x00"))
	if len(files) != 3 || files[0].Path != "src/a.go" || files[0].Additions != 3 || files[0].Removed != 1 ||
		!files[1].Binary || files[2].Status != "renamed" || files[2].OldPath != "old.go" || files[2].Path != "new.go" {
		t.Fatalf("files=%#v", files)
	}
}

func TestMatchGlob(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		glob, file string
		want       bool
	}{
		{"*.lock", "deep/dir/Cargo.lock", true},
		{"go.sum", "tools/go.sum", true},
		{"**/vendor/**", "vendor/x/y.go", true},
		{"**/vendor/**", "a/vendor/x.go", true},
		{"gen/**", "gen/a/b.go", true},
		{"gen/**", "src/gen/a.go", false},
		{"src/*.go", "src/a.go", true},
		{"src/*.go", "src/x/a.go", false},
		{"*.md", "README.md", true},
	} {
		if got := matchGlob(test.glob, test.file); got != test.want {
			t.Errorf("matchGlob(%q, %q) = %v", test.glob, test.file, got)
		}
	}
}

func parseChange(paths ...string) Change {
	change := Change{paths: map[string]bool{}}
	for _, path := range paths {
		change.paths[path] = true
		change.Files = append(change.Files, File{Path: path})
	}
	return change
}

func TestParseValidatesFindings(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	write(t, dir, "a.go", strings.Repeat("line\n", 10))
	write(t, dir, "b.go", "one\ntwo\n")
	change := parseChange("a.go", "b.go", "gone.go")
	reply := "Here is my review.\n```json\n" + `{
  "summary": "Adds things.",
  "findings": [
    {"file": "a/a.go", "start_line": 3, "end_line": 50, "severity": "medium", "confidence": 8, "title": "Medium one", "body": "Body A"},
    {"file": "b.go", "start_line": "1", "severity": "CRITICAL", "confidence": 9, "title": "High one", "body": "Body B", "suggestion": "Fix B"},
    {"file": "unknown.go", "start_line": 1, "severity": "high", "confidence": 9, "title": "Unknown", "body": "dropped"},
    {"file": "./a.go", "start_line": 1, "severity": "low", "confidence": 2, "title": "Unsure", "body": "below the floor"},
    {"file": "gone.go", "start_line": 7, "severity": "low", "confidence": 6, "title": "Deleted file", "body": "no lines"},
    {"file": "a.go", "start_line": 9, "severity": "low", "confidence": 5, "title": "", "body": "no title"}
  ],
  "security_concerns": "No."
}` + "\n```\n"
	answer, err := Parse(reply, change, dir, Options{MaxFindings: 3, MinConfidence: 5})
	if err != nil {
		t.Fatal(err)
	}
	if answer.Summary != "Adds things." || answer.Security != "No" || answer.Dropped != 3 {
		t.Fatalf("answer=%#v", answer)
	}
	if len(answer.Findings) != 3 {
		t.Fatalf("findings=%#v", answer.Findings)
	}
	high, medium, low := answer.Findings[0], answer.Findings[1], answer.Findings[2]
	if high.ID != "f1" || high.Severity != model.FindingSeverityHigh || high.File != "b.go" || high.StartLine != 1 || high.EndLine != 1 || high.Suggestion != "Fix B" || high.Status != model.FindingStatusNew {
		t.Fatalf("high=%#v", high)
	}
	if medium.ID != "f2" || medium.File != "a.go" || medium.StartLine != 3 || medium.EndLine != 10 {
		t.Fatalf("medium=%#v", medium)
	}
	if low.ID != "f3" || low.File != "gone.go" || low.StartLine != 0 || low.EndLine != 0 {
		t.Fatalf("low=%#v", low)
	}

	limited, err := Parse(reply, change, dir, Options{MaxFindings: 1})
	if err != nil || len(limited.Findings) != 1 || limited.Findings[0].Title != "High one" {
		t.Fatalf("limited=%#v err=%v", limited, err)
	}
}

func TestParseReadsBareJSONAndRejectsGarbage(t *testing.T) {
	t.Parallel()
	change := parseChange("x.go")
	answer, err := Parse(`Review: {"summary":"ok","findings":[],"security_concerns":"SQL injection: user input reaches the query"}`, change, "", Options{MaxFindings: 6})
	if err != nil || answer.Summary != "ok" || len(answer.Findings) != 0 || !strings.HasPrefix(answer.Security, "SQL injection") {
		t.Fatalf("answer=%#v err=%v", answer, err)
	}
	for _, garbage := range []string{"no json at all", "```json\n{not json}\n```"} {
		if _, err := Parse(garbage, change, "", Options{MaxFindings: 6}); !errors.Is(err, ErrNoAnswer) {
			t.Fatalf("Parse(%q) err=%v", garbage, err)
		}
	}
}

func TestCompareRounds(t *testing.T) {
	t.Parallel()
	previous := []model.CodeReviewFinding{
		{ID: "f1", File: "a.go", StartLine: 10, Title: "Lock leak"},
		{ID: "f2", File: "b.go", StartLine: 5, EndLine: 7, Title: "Off by one"},
		{ID: "f3", File: "c.go", StartLine: 1, Title: "Gone"},
	}
	current := []model.CodeReviewFinding{
		{ID: "f1", File: "a.go", StartLine: 40, Title: "lock leak"},
		{ID: "f2", File: "b.go", StartLine: 8, Title: "Index past the end"},
		{ID: "f3", File: "d.go", StartLine: 1, Title: "Brand new"},
	}
	marked, resolved := CompareRounds(previous, current)
	if marked[0].Status != model.FindingStatusOpen || marked[1].Status != model.FindingStatusOpen || marked[2].Status != model.FindingStatusNew {
		t.Fatalf("marked=%#v", marked)
	}
	if len(resolved) != 1 || resolved[0].ID != "f3" || resolved[0].Status != model.FindingStatusResolved {
		t.Fatalf("resolved=%#v", resolved)
	}
	if _, all := CompareRounds(previous, nil); len(all) != 3 {
		t.Fatalf("no current findings resolves all: %#v", all)
	}
}

func TestToolResultAndInstructions(t *testing.T) {
	t.Parallel()
	review := model.CodeReview{
		ID: "rev_1", Status: model.CodeReviewCompleted, Round: 2, Depth: "quick", Harness: "claude-code", Model: "opus",
		FilesChanged: 2, Additions: 10, Deletions: 3, Summary: "Adds a cache.", Security: "No",
		Resolved: []model.CodeReviewFinding{{ID: "f9"}},
		Findings: []model.CodeReviewFinding{{ID: "f1", File: "a.go", StartLine: 3, EndLine: 5, Severity: "high", Confidence: 9, Title: "Leak", Body: "It leaks.", Suggestion: "Close it.", Status: model.FindingStatusOpen}},
	}
	text := ToolResult(review)
	for _, want := range []string{"Code review rev_1 (round 2, quick, claude-code opus) of 2 files, +10 -3.", "Summary: Adds a cache.", "Resolved since the previous review: 1.", "[f1] Leak (high, confidence 9, still open) a.go:3-5", "Suggestion: Close it.", "say in your reply why you reject"} {
		if !strings.Contains(text, want) {
			t.Fatalf("tool result lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "Security:") {
		t.Fatal("a 'No' security answer must not be repeated")
	}
	if got := ToolResult(model.CodeReview{Status: model.CodeReviewFailed, Error: "boom"}); got != "The code review failed: boom" {
		t.Fatal(got)
	}
	if got := ToolResult(model.CodeReview{ID: "rev_2", Status: model.CodeReviewCompleted, Depth: "quick"}); !strings.Contains(got, "no changes to review") {
		t.Fatal(got)
	}

	quick := Instructions(Options{Depth: model.CodeReviewDepthQuick, MaxFindings: 4, Instructions: "Watch lock ordering."})
	thorough := Instructions(Options{Depth: model.CodeReviewDepthThorough, MaxFindings: 4})
	if !strings.HasPrefix(quick, Marker) || !strings.Contains(quick, "Depth: quick.") || !strings.Contains(quick, "at most 4 findings") || !strings.Contains(quick, "Watch lock ordering.") {
		t.Fatalf("quick instructions:\n%s", quick)
	}
	if !strings.Contains(thorough, "Depth: thorough.") || strings.Contains(thorough, "Depth: quick.") {
		t.Fatalf("thorough instructions:\n%s", thorough)
	}
	previous := &model.CodeReview{Findings: []model.CodeReviewFinding{{Severity: "high", File: "a.go", StartLine: 3, Title: "Leak"}}}
	prompt := Prompt(Change{Base: EmptyTree, Files: []File{{Path: "a.go", Status: "added", Inlined: true}}, Sensitive: []string{"go.mod"}}, Options{Focus: "error paths"}, previous)
	for _, want := range []string{"(none: the change adds every file)", "error paths", "Sensitive paths changed", "- [high] a.go:3 Leak"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt lacks %q:\n%s", want, prompt)
		}
	}
}

func TestGitStderrNeverReachesOutput(t *testing.T) {
	t.Parallel()
	repo := testkit.GitRepo(t)
	// A config that makes git warn on stderr must not leak into parsed output.
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git missing")
	}
	out, err := gitOutput(context.Background(), repo, nil, "rev-parse", "HEAD")
	if err != nil || len(out) != 40 {
		t.Fatalf("rev-parse=%q err=%v", out, err)
	}
	if _, err := gitOutput(context.Background(), repo, nil, "rev-parse", "--verify", "no-such-ref"); err == nil || !strings.Contains(err.Error(), "git rev-parse") {
		t.Fatalf("missing ref error=%v", err)
	}
}
