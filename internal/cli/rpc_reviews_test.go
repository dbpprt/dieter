package cli

import (
	"bytes"
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// fakeReviewClient is the daemon API as the review commands see it.
type fakeReviewClient struct {
	dieterclient.Client
	mu       sync.Mutex
	settings *dieterv1.ReviewerSettings
	updated  *dieterv1.UpdateReviewerSettingsRequest
	started  *dieterv1.StartCodeReviewRequest
	polls    int
	switched *dieterv1.SetCardCodeReviewRequest
	accounts []*dieterv1.ProviderAccount
}

func (f *fakeReviewClient) GetReviewerSettings(context.Context, *emptypb.Empty, ...grpc.CallOption) (*dieterv1.ReviewerSettings, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.settings, nil
}

func (f *fakeReviewClient) UpdateReviewerSettings(_ context.Context, in *dieterv1.UpdateReviewerSettingsRequest, _ ...grpc.CallOption) (*dieterv1.ReviewerSettings, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.updated = in
	saved := *in.GetSettings()
	saved.Configured, saved.Revision = true, "rev-2"
	f.settings = &saved
	return &saved, nil
}

func (f *fakeReviewClient) ListProviderAccounts(context.Context, *dieterv1.ListProviderAccountsRequest, ...grpc.CallOption) (*dieterv1.ListProviderAccountsResponse, error) {
	return &dieterv1.ListProviderAccountsResponse{Accounts: f.accounts}, nil
}

func (f *fakeReviewClient) StartCodeReview(_ context.Context, in *dieterv1.StartCodeReviewRequest, _ ...grpc.CallOption) (*dieterv1.CodeReview, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.started = in
	if in.GetCardId() == "c_busy" {
		return nil, status.Error(codes.FailedPrecondition, "code review rev_0 is still running for this conversation; wait for its result")
	}
	return &dieterv1.CodeReview{Id: "rev_1", CardId: in.GetCardId(), Status: "running", Depth: "quick", Harness: "claude-code", Model: "opus"}, nil
}

func (f *fakeReviewClient) GetCodeReview(_ context.Context, in *dieterv1.GetCodeReviewRequest, _ ...grpc.CallOption) (*dieterv1.CodeReview, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.polls++
	if f.polls < 2 {
		return &dieterv1.CodeReview{Id: in.GetReviewId(), Status: "running"}, nil
	}
	return completedReview(in.GetReviewId()), nil
}

func (f *fakeReviewClient) ListCodeReviews(_ context.Context, in *dieterv1.ListCodeReviewsRequest, _ ...grpc.CallOption) (*dieterv1.CodeReviewsResponse, error) {
	return &dieterv1.CodeReviewsResponse{Reviews: []*dieterv1.CodeReview{
		completedReview("rev_2"),
		{Id: "rev_1", Status: "failed", Round: 1, Trigger: "user", StartedAt: "2026-11-27T10:00:00Z", Error: "boom"},
	}}, nil
}

func (f *fakeReviewClient) SetCardCodeReview(_ context.Context, in *dieterv1.SetCardCodeReviewRequest, _ ...grpc.CallOption) (*dieterv1.Card, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.switched = in
	return &dieterv1.Card{Id: in.GetCardId(), CodeReview: in.GetEnabled()}, nil
}

func completedReview(id string) *dieterv1.CodeReview {
	return &dieterv1.CodeReview{
		Id: id, Status: "completed", Round: 2, Trigger: "agent", Depth: "quick", Harness: "claude-code", Model: "opus",
		FilesChanged: 3, Additions: 40, Deletions: 2, DurationMs: 42_000, Summary: "Adds a cache.", Security: "No",
		StartedAt: "2026-11-27T11:00:00Z", Resolved: []*dieterv1.CodeReviewFinding{{Id: "f9"}},
		Findings: []*dieterv1.CodeReviewFinding{{Id: "f1", File: "cache.go", StartLine: 10, EndLine: 12, Severity: "high", Confidence: 9, Title: "Unbounded cache", Body: "Grows forever.", Suggestion: "Add an LRU bound.", Status: "open"}},
	}
}

func reviewCLI(t *testing.T, fake *fakeReviewClient) (*CLI, *bytes.Buffer) {
	t.Helper()
	c := New(t.TempDir())
	c.env = config.Client{}
	var out, errOut bytes.Buffer
	c.Out, c.Err, c.In = &out, &errOut, strings.NewReader("Prefer small diffs.\n")
	c.transport = &dieterTransport{client: fake, route: "local", daemonID: "d_here"}
	return c, &out
}

func TestReviewerShowAndUpdateKeepUnchangedFields(t *testing.T) {
	t.Parallel()
	fake := &fakeReviewClient{
		settings: &dieterv1.ReviewerSettings{Harness: "claude-code", Model: "opus", Effort: "high", Depth: "quick", MaxFindings: 6, MaxRounds: 3, IgnoreGlobs: []string{"gen/**"}, Revision: "rev-1"},
		accounts: []*dieterv1.ProviderAccount{{Id: "pa_abcdefghijklmnopqrstuvwxyz", Label: "Work", Provider: dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE}},
	}
	c, out := reviewCLI(t, fake)
	if err := c.Run([]string{"reviewer", "show"}); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Harness:\tclaude-code", "Model:\topus (high)", "Account:\tprovider default", "Depth:\tquick", "Ignore:\tgen/**", "(defaults: no reviewer setting saved yet)"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("show lacks %q:\n%s", want, out.String())
		}
	}
	out.Reset()
	if err := c.Run([]string{"reviewer", "update", "--harness", "codex", "--depth", "thorough", "--max-findings", "8", "--min-confidence", "0", "--account", "Work", "--ignore", "*.snap", "--instructions-file", "-"}); err != nil {
		t.Fatal(err)
	}
	next := fake.updated.GetSettings()
	if fake.updated.GetExpectedRevision() != "rev-1" || next.GetHarness() != "codex" || next.GetModel() != "" || next.GetEffort() != "" ||
		next.GetDepth() != "thorough" || next.GetMaxFindings() != 8 || next.GetMinConfidence() != 0 || next.GetMaxRounds() != 3 ||
		next.GetAccountId() != "pa_abcdefghijklmnopqrstuvwxyz" || strings.Join(next.GetIgnoreGlobs(), ",") != "gen/**,*.snap" || next.GetInstructions() != "Prefer small diffs." {
		t.Fatalf("update request=%v", fake.updated)
	}
	if !strings.Contains(out.String(), "Harness:\tcodex") || strings.Contains(out.String(), "defaults") {
		t.Fatalf("update output:\n%s", out.String())
	}
	if err := c.Run([]string{"reviewer", "update", "--clear-ignore", "--format", "json"}); err != nil {
		t.Fatal(err)
	}
	if len(fake.updated.GetSettings().GetIgnoreGlobs()) != 0 || fake.updated.GetSettings().GetHarness() != "codex" {
		t.Fatalf("clear-ignore request=%v", fake.updated)
	}
	if err := c.Run([]string{"reviewer", "update", "extra"}); err == nil {
		t.Fatal("arguments were accepted")
	}
}

func TestCardReviewWaitsAndPrintsFindings(t *testing.T) {
	codeReviewPollInterval = time.Millisecond
	fake := &fakeReviewClient{}
	c, out := reviewCLI(t, fake)
	if err := c.Run([]string{"card", "review", "--wait", "--focus", "the cache", "--depth", "quick", "c_one"}); err != nil {
		t.Fatal(err)
	}
	if fake.started.GetCardId() != "c_one" || fake.started.GetFocus() != "the cache" || fake.started.GetDepth() != "quick" || fake.polls != 2 {
		t.Fatalf("start=%v polls=%d", fake.started, fake.polls)
	}
	for _, want := range []string{"Code review rev_1 (round 2, quick, claude-code opus) of 3 files, +40 -2, in 42s.", "Summary: Adds a cache.", "Resolved since the previous review: 1.", "[f1] Unbounded cache (high, confidence 9, still open) cache.go:10-12", "Suggestion: Add an LRU bound."} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("review output lacks %q:\n%s", want, out.String())
		}
	}
	out.Reset()
	if err := c.Run([]string{"chat", "review", "c_two"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Code review rev_1 is running") || !strings.Contains(out.String(), "dieter card reviews --id rev_1 c_two") {
		t.Fatalf("no-wait output:\n%s", out.String())
	}
	if err := c.Run([]string{"card", "review", "c_busy"}); err == nil || !strings.Contains(err.Error(), "still running") {
		t.Fatalf("busy review error=%v", err)
	}
	if err := c.Run([]string{"card", "review"}); err == nil {
		t.Fatal("a review without a card was accepted")
	}
	var help bytes.Buffer
	c.Out = &help
	if err := c.Run([]string{"chat", "review", "--help"}); err != nil || !strings.Contains(help.String(), "Usage: dieter chat review [--wait]") || !strings.Contains(help.String(), "CHAT") {
		t.Fatalf("chat help=%q err=%v", help.String(), err)
	}
}

func TestCardReviewsAndReviewerSwitch(t *testing.T) {
	codeReviewPollInterval = time.Millisecond
	fake := &fakeReviewClient{polls: 5}
	c, out := reviewCLI(t, fake)
	if err := c.Run([]string{"card", "reviews", "c_one"}); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "rev_2\tcompleted\tround 2\t1 finding (1 high)\tagent") || !strings.HasPrefix(lines[1], "rev_1\tfailed\tround 1\tfailed\tuser") {
		t.Fatalf("list:\n%s", out.String())
	}
	out.Reset()
	if err := c.Run([]string{"card", "reviews", "--id", "rev_2", "--format", "json", "c_one"}); err != nil || !strings.Contains(out.String(), `"rev_2"`) {
		t.Fatalf("show json=%s err=%v", out.String(), err)
	}
	out.Reset()
	if err := c.Run([]string{"card", "reviewer", "c_one", "on"}); err != nil || !fake.switched.GetEnabled() || !strings.Contains(out.String(), "Code reviewer on for c_one") {
		t.Fatalf("switch on=%v out=%q err=%v", fake.switched, out.String(), err)
	}
	if err := c.Run([]string{"card", "reviewer", "c_one", "maybe"}); err == nil {
		t.Fatal("an invalid switch was accepted")
	}
}
