package engine

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

type reviewFixture struct {
	service    *Service
	data       *store.Store
	project    model.Project
	repository string
	base       string
}

// reviewSetup is an enrolled store with a Git project and the reviewer set to
// the mock harness. runner receives the Dieter home root.
func reviewSetup(t *testing.T, runner func(root string) (harness.Runner, *harness.Catalog)) reviewFixture {
	t.Helper()
	data := testkit.PeerStore(t, "dm_review")
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	repository := testkit.GitRepo(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Reviewed", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	run, catalog := runner(data.Root)
	noReserve := uint64(0)
	service := NewWithOptions(data, Options{Runner: run, Catalog: catalog, MinimumFreeBytes: &noReserve})
	if _, err := data.KV.PutReviewerSettings(schema.ReviewerSettingsRecord{Harness: "mock", Depth: "quick", MaxFindings: 6, MaxRounds: 3}, ""); err != nil {
		t.Fatal(err)
	}
	return reviewFixture{service: service, data: data, project: project, repository: repository, base: testkit.RunGit(t, repository, "rev-parse", "HEAD")}
}

func mockHarness(t *testing.T) func(string) (harness.Runner, *harness.Catalog) {
	return func(root string) (harness.Runner, *harness.Catalog) {
		runner, catalog := testkit.MockHarness(t, root)
		return runner, catalog
	}
}

func fakeHarness(runner *testkit.FakeRunner) func(string) (harness.Runner, *harness.Catalog) {
	return func(string) (harness.Runner, *harness.Catalog) { return runner, testkit.MockCatalog() }
}

// worktreeChat is a deferred worktree chat whose workspace exists and holds
// an untracked change to feature.go.
func (f reviewFixture) worktreeChat(t *testing.T, prompt string, codeReview bool) (model.Card, model.Workspace) {
	t.Helper()
	card, err := f.service.CreateChat(context.Background(), CardInput{
		Project: f.project.ID, Title: "Reviewed chat", Prompt: prompt, Provider: "mock", Model: "mock",
		WorkspaceMode: model.WorkspaceModeWorktree, DeferStart: true, CodeReview: codeReview,
	})
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := f.service.Workspaces.Ensure(context.Background(), card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace.Path, "feature.go"), []byte("package feature\n\nfunc New() int { return 1 }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return card, workspace
}

func (f reviewFixture) waitForReview(t *testing.T, cardID, reviewID string) model.CodeReview {
	t.Helper()
	var review model.CodeReview
	testkit.Eventually(t, 60*time.Second, func() bool {
		var err error
		review, err = f.service.CodeReview(cardID, reviewID)
		if err != nil || !review.Final() {
			return false
		}
		// The final part is visible before its write has committed; the run
		// leaves the registry only after.
		f.service.mu.Lock()
		defer f.service.mu.Unlock()
		run := f.service.codeReviews[cardID]
		return run == nil || run.id != reviewID
	}, "the code review to finish")
	return review
}

func mockFindingJSON(file string) string {
	return "```json\n" + `{"summary":"Adds a constructor.","findings":[{"file":"` + file + `","start_line":3,"severity":"high","confidence":8,"title":"Wrong value","body":"New returns 1.","suggestion":"Return 0."}],"security_concerns":"No"}` + "\n```"
}

func TestUserCodeReviewEndToEndWithTheMockHarness(t *testing.T) {
	t.Parallel()
	fixture := reviewSetup(t, mockHarness(t))
	card, workspace := fixture.worktreeChat(t, "work", false)
	statusBefore := testkit.RunGit(t, workspace.Path, "status", "--porcelain")

	started, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser})
	if err != nil {
		t.Fatal(err)
	}
	if started.Status != model.CodeReviewRunning || started.Round != 1 || started.Harness != "mock" || started.Depth != "quick" || started.MessageID != "msg_review_"+started.ID {
		t.Fatalf("started=%#v", started)
	}
	review := fixture.waitForReview(t, card.ID, started.ID)
	if review.Status != model.CodeReviewCompleted || review.Error != "" {
		t.Fatalf("review=%#v", review)
	}
	if review.FilesChanged != 1 || review.Additions != 3 || review.BaseSHA != fixture.base || review.SnapshotSHA == "" || review.InputTokens != 1200 || review.OutputTokens != 80 || review.DurationMS <= 0 {
		t.Fatalf("review facts=%#v", review)
	}
	if len(review.Findings) != 1 || review.Findings[0].File != "feature.go" || review.Findings[0].StartLine != 1 || review.Findings[0].Title != "Mock finding" || review.Findings[0].Status != model.FindingStatusNew {
		t.Fatalf("findings=%#v", review.Findings)
	}
	if got := testkit.RunGit(t, workspace.Path, "status", "--porcelain"); got != statusBefore {
		t.Fatalf("the review changed the workspace:\n%s\nwas\n%s", got, statusBefore)
	}
	if list := testkit.RunGit(t, fixture.repository, "worktree", "list"); strings.Contains(list, filepath.Join("runtime", "reviews")) {
		t.Fatalf("the snapshot worktree remains:\n%s", list)
	}

	second, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser, Depth: model.CodeReviewDepthThorough})
	if err != nil {
		t.Fatal(err)
	}
	second = fixture.waitForReview(t, card.ID, second.ID)
	if second.Round != 2 || second.PreviousReviewID != review.ID || second.Depth != "thorough" || len(second.Findings) != 1 || second.Findings[0].Status != model.FindingStatusOpen {
		t.Fatalf("second review=%#v", second)
	}
	reviews, err := fixture.service.CodeReviews(card.ID)
	if err != nil || len(reviews) != 2 || reviews[0].ID != second.ID {
		t.Fatalf("reviews newest first=%#v err=%v", reviews, err)
	}

	// The next message carries both user reviews to the agent, once.
	updates, err := fixture.service.StartCard(card.ID, "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	fixture.waitIdle(t, card.ID)
	if text := lastAssistantText(t, fixture.data, card.ID); !strings.Contains(text, "<code_review>") || !strings.Contains(text, review.ID) || !strings.Contains(text, second.ID) {
		t.Fatalf("the next prompt lacks the reviews: %q", text)
	}
	if err := fixture.service.SendCard(context.Background(), card.ID, "thanks", "", "", ""); err != nil {
		t.Fatal(err)
	}
	fixture.waitIdle(t, card.ID)
	if text := lastAssistantText(t, fixture.data, card.ID); strings.Contains(text, "<code_review>") {
		t.Fatalf("the reviews reached a later prompt again: %q", text)
	}
}

func TestAgentCodeReviewToolEndToEndWithTheMockHarness(t *testing.T) {
	t.Parallel()
	fixture := reviewSetup(t, mockHarness(t))
	card, _ := fixture.worktreeChat(t, "mock-code-review", true)
	updates, err := fixture.service.StartCard(card.ID, "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	fixture.waitIdle(t, card.ID)
	conversation, err := fixture.data.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	var toolOutput string
	var review model.CodeReview
	var reviewMessage string
	for _, message := range conversation.Messages {
		for _, part := range message.Parts {
			if part.ToolName == "request_code_review" {
				toolOutput = string(part.Output)
			}
			if part.Type == model.CodeReviewPartType {
				_ = json.Unmarshal(part.Data, &review)
				reviewMessage = message.ID
			}
		}
	}
	if !strings.Contains(toolOutput, "Code review rev_") || !strings.Contains(toolOutput, "Mock finding") || !strings.Contains(toolOutput, "feature.go:1") {
		t.Fatalf("tool output=%q", toolOutput)
	}
	if review.Status != model.CodeReviewCompleted || review.Trigger != model.CodeReviewTriggerAgent || review.ToolCallID != "tool-review" || len(review.Findings) != 1 {
		t.Fatalf("review part=%#v", review)
	}
	if last := conversation.Messages[len(conversation.Messages)-1]; last.ID != reviewMessage || last.Role != "assistant" {
		t.Fatalf("the review is not part of the turn's assistant message: review in %s, last %#v", reviewMessage, last.ID)
	}
	if text := lastAssistantText(t, fixture.data, card.ID); !strings.Contains(text, "Mock agent read the code review.") {
		t.Fatalf("agent reply=%q", text)
	}
}

func TestCodeReviewAdmissionAndFailures(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{Release: make(chan struct{}), Reply: func(harness.Request) string { return mockFindingJSON("feature.go") }}
	fixture := reviewSetup(t, fakeHarness(runner))
	card, _ := fixture.worktreeChat(t, "work", false)

	first, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser, Focus: "the constructor"})
	if err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == 1 }, "the reviewer to start")
	if _, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser}); err == nil || !strings.Contains(err.Error(), "still running") {
		t.Fatalf("a second review started: %v", err)
	} else if kind, _ := fault.KindOf(err); kind != fault.FailedPrecondition {
		t.Fatalf("second review kind=%v", kind)
	}
	close(runner.Release)
	review := fixture.waitForReview(t, card.ID, first.ID)
	if review.Status != model.CodeReviewCompleted || len(review.Findings) != 1 || review.Findings[0].Severity != "high" || review.Findings[0].StartLine != 3 || review.Summary != "Adds a constructor." {
		t.Fatalf("review=%#v", review)
	}
	request := runner.Request(0)
	if !strings.HasPrefix(request.Instructions, "You are Dieter's code reviewer.") || !strings.Contains(request.Prompt, "## File: feature.go") ||
		!strings.Contains(request.Prompt, "the constructor") || request.ContentPresentationEnabled || request.BackgroundProcessesEnabled || request.CodeReviewEnabled ||
		!strings.Contains(request.ProjectPath, filepath.Join("runtime", "reviews", first.ID)) || request.SessionID == card.ID {
		t.Fatalf("reviewer request=%#v", request)
	}

	if _, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser, Depth: "deep"}); err == nil {
		t.Fatal("an unknown depth was accepted")
	}
	if _, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser, Focus: strings.Repeat("x", maxCodeReviewFocus+1)}); err == nil {
		t.Fatal("an oversized focus was accepted")
	}
}

func TestCodeReviewWithoutChangesAndWithAnUnreadableReply(t *testing.T) {
	t.Parallel()
	replies := make(chan string, 1)
	runner := &testkit.FakeRunner{Reply: func(harness.Request) string { return <-replies }}
	fixture := reviewSetup(t, fakeHarness(runner))
	card, err := fixture.service.CreateChat(context.Background(), CardInput{Project: fixture.project.ID, Title: "Clean", Prompt: "work", Provider: "mock", WorkspaceMode: model.WorkspaceModeWorktree, DeferStart: true})
	if err != nil {
		t.Fatal(err)
	}
	clean, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser})
	if err != nil {
		t.Fatal(err)
	}
	clean = fixture.waitForReview(t, card.ID, clean.ID)
	if clean.Status != model.CodeReviewCompleted || clean.FilesChanged != 0 || clean.Summary != "There are no changes to review." || runner.Count() != 0 {
		t.Fatalf("clean review=%#v runs=%d", clean, runner.Count())
	}

	changed, _ := fixture.worktreeChat(t, "work", false)
	replies <- "I looked at it and it seems fine, no JSON here."
	failed, err := fixture.service.StartCodeReview(changed.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser})
	if err != nil {
		t.Fatal(err)
	}
	failed = fixture.waitForReview(t, changed.ID, failed.ID)
	if failed.Status != model.CodeReviewFailed || !strings.Contains(failed.Error, "did not return a readable review") {
		t.Fatalf("failed review=%#v", failed)
	}
}

func TestCodeReviewIsCancelledOnShutdownAndRefusedForStrix(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{Release: make(chan struct{})}
	fixture := reviewSetup(t, fakeHarness(runner))
	card, _ := fixture.worktreeChat(t, "work", false)
	started, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser})
	if err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == 1 }, "the reviewer to start")
	fixture.service.cancelCodeReviews()
	if review := fixture.waitForReview(t, card.ID, started.ID); review.Status != model.CodeReviewCancelled {
		t.Fatalf("review after cancel=%#v", review)
	}

	if _, err := fixture.data.KV.PutReviewerSettings(schema.ReviewerSettingsRecord{Harness: "strix", Depth: "quick", MaxFindings: 6, MaxRounds: 3}, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.service.StartCodeReview(card.ID, CodeReviewRequest{Trigger: model.CodeReviewTriggerUser}); err == nil {
		t.Fatal("Strix ran as the reviewer")
	}
}

func TestAgentCodeReviewToolCallRunsWithinTheCall(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{Reply: func(harness.Request) string { return mockFindingJSON("feature.go") }}
	fixture := reviewSetup(t, fakeHarness(runner))
	card, _ := fixture.worktreeChat(t, "work", true)
	raw, err := fixture.service.codeReviewToolCall(context.Background(), card.ID, "turn_1", "msg_turn", harness.ProcessCall{ID: "bridge-1", Operation: "review", Arguments: json.RawMessage(`{"focus":"errors","toolCallId":"call_42"}`)})
	if err != nil {
		t.Fatal(err)
	}
	var text string
	if err := json.Unmarshal(raw, &text); err != nil || !strings.Contains(text, "[f1] Wrong value (high, confidence 8) feature.go:3") {
		t.Fatalf("tool result=%s err=%v", raw, err)
	}
	reviews, err := fixture.service.CodeReviews(card.ID)
	if err != nil || len(reviews) != 1 || reviews[0].ToolCallID != "call_42" || reviews[0].Focus != "errors" || reviews[0].MessageID != "msg_turn" || reviews[0].Trigger != model.CodeReviewTriggerAgent {
		t.Fatalf("reviews=%#v err=%v", reviews, err)
	}
	if _, err := fixture.service.codeReviewToolCall(context.Background(), card.ID, "turn_1", "msg_turn", harness.ProcessCall{ID: "bridge-2", Arguments: json.RawMessage(`not json`)}); err == nil {
		t.Fatal("invalid arguments were accepted")
	}
}

func TestReviewedCardTurnsGetTheTool(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{}
	fixture := reviewSetup(t, fakeHarness(runner))
	for _, reviewed := range []bool{true, false} {
		card, err := fixture.service.CreateChat(context.Background(), CardInput{Project: fixture.project.ID, Title: "Turn", Prompt: "work", Provider: "mock", WorkspaceMode: model.WorkspaceModeProject, CodeReview: reviewed})
		if err != nil {
			t.Fatal(err)
		}
		fixture.waitIdle(t, card.ID)
		var request harness.Request
		for _, candidate := range runner.Requests() {
			if candidate.SessionID == card.ID {
				request = candidate
			}
		}
		if request.CodeReviewEnabled != reviewed || (request.CodeReview != nil) != reviewed {
			t.Fatalf("reviewed=%v request enabled=%v handler=%v", reviewed, request.CodeReviewEnabled, request.CodeReview != nil)
		}
		if reviewed && (request.CodeReviewMaxRounds != 3 || !strings.HasSuffix(request.ReviewCommand, " chat review "+card.ID+" --wait")) {
			t.Fatalf("reviewed request command=%q rounds=%d", request.ReviewCommand, request.CodeReviewMaxRounds)
		}
		if !reviewed && request.ReviewCommand != "" {
			t.Fatalf("unreviewed request has a review command %q", request.ReviewCommand)
		}
	}
}

func TestCodeReviewContextIncludesOnlyUserReviewsSinceThePreviousMessage(t *testing.T) {
	t.Parallel()
	part := func(review model.CodeReview) model.UIMessagePart {
		data, _ := json.Marshal(review)
		return model.UIMessagePart{Type: model.CodeReviewPartType, Data: data}
	}
	old := model.CodeReview{ID: "rev_old", Status: model.CodeReviewCompleted, Trigger: model.CodeReviewTriggerUser, FilesChanged: 1}
	agent := model.CodeReview{ID: "rev_agent", Status: model.CodeReviewCompleted, Trigger: model.CodeReviewTriggerAgent, FilesChanged: 1}
	failed := model.CodeReview{ID: "rev_failed", Status: model.CodeReviewFailed, Trigger: model.CodeReviewTriggerUser}
	fresh := model.CodeReview{ID: "rev_fresh", Status: model.CodeReviewCompleted, Trigger: model.CodeReviewTriggerUser, FilesChanged: 2, Findings: []model.CodeReviewFinding{{ID: "f1", File: "a.go", Severity: "high", Title: "Leak", Body: "It leaks."}}}
	conversation := model.Conversation{Messages: []model.UIMessage{
		{ID: "u1", Role: "user"},
		{ID: "a1", Role: "assistant", Parts: []model.UIMessagePart{part(old)}},
		{ID: "u2", Role: "user"},
		{ID: "a2", Role: "assistant", Parts: []model.UIMessagePart{part(agent), part(failed)}},
		{ID: "msg_review_rev_fresh", Role: "assistant", Parts: []model.UIMessagePart{part(fresh)}},
		{ID: "u3", Role: "user"},
	}}
	prompt := codeReviewContext(conversation, "fix it")
	if !strings.HasPrefix(prompt, "<code_review>") || !strings.HasSuffix(prompt, "</code_review>\n\nfix it") || !strings.Contains(prompt, "rev_fresh") || !strings.Contains(prompt, "[f1] Leak") {
		t.Fatalf("prompt=%q", prompt)
	}
	for _, absent := range []string{"rev_old", "rev_agent", "rev_failed"} {
		if strings.Contains(prompt, absent) {
			t.Fatalf("prompt includes %s: %q", absent, prompt)
		}
	}
	conversation.Messages = []model.UIMessage{
		{ID: "u1", Role: "user"},
		{ID: "a1", Role: "assistant", Parts: []model.UIMessagePart{part(agent), part(failed)}},
		{ID: "u2", Role: "user"},
	}
	if got := codeReviewContext(conversation, "plain"); got != "plain" {
		t.Fatalf("prompt without user reviews=%q", got)
	}
}

func (f reviewFixture) waitIdle(t *testing.T, cardID string) {
	t.Helper()
	waitFor(t, func() bool {
		stored, err := f.data.Kanban.ResolveCard(cardID)
		if err != nil || stored.Runtime == "running" || stored.Runtime == "starting" {
			return false
		}
		f.service.mu.Lock()
		_, active := f.service.active[cardID]
		f.service.mu.Unlock()
		return !active
	})
}

func lastAssistantText(t *testing.T, data *store.Store, cardID string) string {
	t.Helper()
	conversation, err := data.Conversations.Get(cardID)
	if err != nil {
		t.Fatal(err)
	}
	for index := len(conversation.Messages) - 1; index >= 0; index-- {
		message := conversation.Messages[index]
		if message.Role != "assistant" {
			continue
		}
		var text strings.Builder
		for _, part := range message.Parts {
			if part.Type == "text" {
				text.WriteString(part.Text)
			}
		}
		if text.Len() > 0 {
			return text.String()
		}
	}
	return ""
}

var (
	_ = errors.New
	_ = conversations.CodeReviews
)
