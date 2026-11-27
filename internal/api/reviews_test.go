package api

import (
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/emptypb"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestReviewServiceSettingsSwitchAndAgentScope(t *testing.T) {
	t.Parallel()
	data := testkit.PeerStore(t, "dm_api_review")
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Reviews", Path: testkit.GitRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	own := mailCard(t, data, project, board, "Agent card", false, false)
	other := mailCard(t, data, project, board, "Other card", false, false)
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()

	defaults, err := client.GetReviewerSettings(ctx, &emptypb.Empty{})
	if err != nil || defaults.GetConfigured() || defaults.GetDepth() != "quick" || defaults.GetMaxFindings() != 6 || defaults.GetMaxRounds() != 3 {
		t.Fatalf("defaults=%v err=%v", defaults, err)
	}
	saved, err := client.UpdateReviewerSettings(ctx, &dieterv1.UpdateReviewerSettingsRequest{Settings: &dieterv1.ReviewerSettings{Harness: "mock", Depth: "thorough", IgnoreGlobs: []string{" gen/** ", ""}}, ExpectedRevision: defaults.GetRevision()})
	if err != nil || !saved.GetConfigured() || saved.GetHarness() != "mock" || saved.GetModel() == "" || saved.GetDepth() != "thorough" || saved.GetMaxFindings() != 6 || len(saved.GetIgnoreGlobs()) != 1 || saved.GetIgnoreGlobs()[0] != "gen/**" {
		t.Fatalf("saved=%v err=%v", saved, err)
	}
	if _, err := client.UpdateReviewerSettings(ctx, &dieterv1.UpdateReviewerSettingsRequest{Settings: &dieterv1.ReviewerSettings{Harness: "mock", Depth: "thorough", MinConfidence: 2}, ExpectedRevision: saved.GetRevision()}); err != nil {
		t.Fatal(err)
	}
	_, err = client.UpdateReviewerSettings(ctx, &dieterv1.UpdateReviewerSettingsRequest{Settings: &dieterv1.ReviewerSettings{Harness: "mock", Depth: "quick"}, ExpectedRevision: saved.GetRevision()})
	wantCode(t, err, connect.CodeAborted, "stale revision")
	_, err = client.UpdateReviewerSettings(ctx, &dieterv1.UpdateReviewerSettingsRequest{Settings: &dieterv1.ReviewerSettings{Harness: "no-such-harness"}})
	wantCode(t, err, connect.CodeInvalidArgument, "unknown harness")
	_, err = client.UpdateReviewerSettings(ctx, &dieterv1.UpdateReviewerSettingsRequest{Settings: &dieterv1.ReviewerSettings{Harness: "mock", MaxFindings: 50}})
	wantCode(t, err, connect.CodeInvalidArgument, "bounds")
	_, err = client.UpdateReviewerSettings(ctx, &dieterv1.UpdateReviewerSettingsRequest{})
	wantCode(t, err, connect.CodeInvalidArgument, "missing settings")

	switched, err := client.SetCardCodeReview(ctx, &dieterv1.SetCardCodeReviewRequest{CardId: own.ID, Enabled: true})
	if err != nil || !switched.GetCodeReview() {
		t.Fatalf("switched=%v err=%v", switched, err)
	}

	request := startVaultTurn(t, client, runner, own.ID)
	agent := withHeaders(ctx, turnHeaders(request))
	_, err = client.UpdateReviewerSettings(agent, &dieterv1.UpdateReviewerSettingsRequest{Settings: &dieterv1.ReviewerSettings{Harness: "mock"}})
	wantCode(t, err, connect.CodePermissionDenied, "agent setting")
	_, err = client.SetCardCodeReview(agent, &dieterv1.SetCardCodeReviewRequest{CardId: own.ID, Enabled: false})
	wantCode(t, err, connect.CodePermissionDenied, "agent switch")
	_, err = client.StartCodeReview(agent, &dieterv1.StartCodeReviewRequest{CardId: other.ID})
	wantCode(t, err, connect.CodePermissionDenied, "agent reviews another card")
	started, err := client.StartCodeReview(agent, &dieterv1.StartCodeReviewRequest{})
	if err != nil || started.GetCardId() != own.ID || started.GetTrigger() != "agent" || started.GetStatus() != "running" || started.GetMessageId() != request.ResponseMessageID || started.GetDepth() != "thorough" {
		t.Fatalf("agent review=%v err=%v", started, err)
	}
	var review *dieterv1.CodeReview
	deadline := time.Now().Add(testkit.Budget(30 * time.Second))
	for time.Now().Before(deadline) {
		if review, err = client.GetCodeReview(agent, &dieterv1.GetCodeReviewRequest{ReviewId: started.GetId()}); err == nil && review.GetStatus() != "running" {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err != nil || review.GetStatus() != "completed" || review.GetFilesChanged() != 0 || review.GetSummary() != "There are no changes to review." {
		t.Fatalf("review=%v err=%v", review, err)
	}
	_, err = client.GetCodeReview(agent, &dieterv1.GetCodeReviewRequest{CardId: other.ID, ReviewId: started.GetId()})
	wantCode(t, err, connect.CodePermissionDenied, "agent reads another card")
	listed, err := client.ListCodeReviews(agent, &dieterv1.ListCodeReviewsRequest{})
	if err != nil || len(listed.GetReviews()) != 1 || listed.GetReviews()[0].GetId() != started.GetId() {
		t.Fatalf("agent list=%v err=%v", listed, err)
	}
	if _, err := client.ListCodeReviews(ctx, &dieterv1.ListCodeReviewsRequest{}); err == nil {
		t.Fatal("an operator list without a card was accepted")
	}
	operatorList, err := client.ListCodeReviews(ctx, &dieterv1.ListCodeReviewsRequest{CardId: own.ID})
	if err != nil || len(operatorList.GetReviews()) != 1 {
		t.Fatalf("operator list=%v err=%v", operatorList, err)
	}
	runner.release <- "done"
	waitForIdle(t, data, own.ID)
	// A write after the review's own serializes behind its commit.
	if card, err := client.SetCardCodeReview(ctx, &dieterv1.SetCardCodeReviewRequest{CardId: own.ID, Enabled: false}); err != nil || card.GetCodeReview() {
		t.Fatalf("switch off=%v err=%v", card, err)
	}
}

func TestReviewerSettingRefusesRawKVWrites(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, vaultTurnRunner{}, testkit.MockCatalog())
	page, err := client.ListKV(t.Context(), &dieterv1.KVListRequest{Namespace: "reviewer-settings"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.PutKV(t.Context(), &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: page.GetAccount(), Namespace: "reviewer-settings", Key: "default"}, ValueJson: []byte(`{"harness":"mock","depth":"quick","maxFindings":6,"maxRounds":3}`), OperationId: "op_kv_review", DaemonId: page.GetDaemonId()})
	wantCode(t, err, connect.CodePermissionDenied, "raw KV write")
}
