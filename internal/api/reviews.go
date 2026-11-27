package api

import (
	"context"
	"strings"

	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/dbpprt/dieter/internal/engine"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// reviewsAPI is ReviewService: the account's reviewer setting, a
// conversation's reviewer switch and its code reviews.
//
// Agent turns may start and read reviews of their own conversation only; the
// setting and the switch belong to people.
type reviewsAPI struct{ server *Server }

func (api *reviewsAPI) GetReviewerSettings(ctx context.Context, _ *emptypb.Empty) (*dieterv1.ReviewerSettings, error) {
	if err := api.server.validateTurnCaller(ctx); err != nil {
		return nil, err
	}
	entry, err := api.server.store.KV.ReviewerSettings()
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoReviewerSettings(entry), nil
}

func (api *reviewsAPI) UpdateReviewerSettings(ctx context.Context, request *dieterv1.UpdateReviewerSettingsRequest) (*dieterv1.ReviewerSettings, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot change the reviewer setting"); err != nil {
		return nil, err
	}
	value := request.GetSettings()
	if value == nil {
		return nil, fault.New(fault.Invalid, "reviewer settings are required")
	}
	record := schema.ReviewerSettingsRecord{
		Harness: strings.TrimSpace(value.GetHarness()), Model: strings.TrimSpace(value.GetModel()),
		Effort: strings.TrimSpace(value.GetEffort()), AccountID: strings.TrimSpace(value.GetAccountId()),
		Depth: strings.TrimSpace(value.GetDepth()), MaxFindings: int(value.GetMaxFindings()),
		MinConfidence: int(value.GetMinConfidence()), Instructions: strings.TrimSpace(value.GetInstructions()),
		MaxRounds: int(value.GetMaxRounds()),
	}
	for _, glob := range value.GetIgnoreGlobs() {
		if glob = strings.TrimSpace(glob); glob != "" {
			record.IgnoreGlobs = append(record.IgnoreGlobs, glob)
		}
	}
	defaults := schema.DefaultReviewerSettings()
	if record.Harness == "" {
		record.Harness, record.Model = defaults.Harness, defaults.Model
	}
	if record.Depth == "" {
		record.Depth = defaults.Depth
	}
	if record.MaxFindings == 0 {
		record.MaxFindings = defaults.MaxFindings
	}
	if record.MaxRounds == 0 {
		record.MaxRounds = defaults.MaxRounds
	}
	// The harness and model must exist here; other machines check their own
	// catalog when they run a review.
	adapter, configured, err := api.server.app.Catalog.ResolveSelection(record.Harness, record.Model)
	if err != nil {
		return nil, err
	}
	if adapter.Runtime == "strix" {
		return nil, fault.New(fault.Invalid, "Strix cannot be the code reviewer")
	}
	record.Harness, record.Model = adapter.ID, configured.ID
	if record.AccountID != "" && !schema.ValidProviderAccountID(record.AccountID) {
		return nil, fault.New(fault.Invalid, "invalid provider account ID")
	}
	entry, err := api.server.store.KV.PutReviewerSettings(record, request.GetExpectedRevision())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoReviewerSettings(entry), nil
}

func (api *reviewsAPI) SetCardCodeReview(ctx context.Context, request *dieterv1.SetCardCodeReviewRequest) (*dieterv1.Card, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot switch the code reviewer"); err != nil {
		return nil, err
	}
	card, err := api.server.app.SetCodeReview(request.GetCardId(), request.GetEnabled())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoCard(card), nil
}

func (api *reviewsAPI) StartCodeReview(ctx context.Context, request *dieterv1.StartCodeReviewRequest) (*dieterv1.CodeReview, error) {
	card, turnID, agent, err := api.server.turnCaller(ctx)
	if err != nil {
		return nil, err
	}
	start := engine.CodeReviewRequest{Focus: request.GetFocus(), Depth: request.GetDepth(), Trigger: model.CodeReviewTriggerUser}
	cardID := request.GetCardId()
	if agent {
		if cardID != "" && cardID != card.ID {
			resolved, resolveErr := api.server.store.Kanban.ResolveCard(cardID)
			if resolveErr != nil || resolved.ID != card.ID {
				return nil, fault.New(fault.PermissionDenied, "an agent turn can review only its own conversation")
			}
		}
		cardID = card.ID
		start.Trigger, start.TurnID = model.CodeReviewTriggerAgent, turnID
		if conversation, getErr := api.server.store.Conversations.Get(card.ID); getErr == nil && conversation.ActiveTurn != nil && conversation.ActiveTurn.ID == turnID {
			start.MessageID = conversation.ActiveTurn.ResponseMessageID
		}
	}
	if strings.TrimSpace(cardID) == "" {
		return nil, fault.New(fault.Invalid, "card_id is required")
	}
	review, err := api.server.app.StartCodeReview(cardID, start)
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoCodeReview(review), nil
}

func (api *reviewsAPI) GetCodeReview(ctx context.Context, request *dieterv1.GetCodeReviewRequest) (*dieterv1.CodeReview, error) {
	cardID, err := api.server.reviewCard(ctx, request.GetCardId())
	if err != nil {
		return nil, err
	}
	review, err := api.server.app.CodeReview(cardID, request.GetReviewId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoCodeReview(review), nil
}

func (api *reviewsAPI) ListCodeReviews(ctx context.Context, request *dieterv1.ListCodeReviewsRequest) (*dieterv1.CodeReviewsResponse, error) {
	cardID, err := api.server.reviewCard(ctx, request.GetCardId())
	if err != nil {
		return nil, err
	}
	reviews, err := api.server.app.CodeReviews(cardID)
	if err != nil {
		return nil, domainFailure(err)
	}
	response := &dieterv1.CodeReviewsResponse{}
	for _, review := range reviews {
		response.Reviews = append(response.Reviews, protoCodeReview(review))
	}
	return response, nil
}

// reviewCard is the conversation a review read is about: any for people, only
// its own for an agent turn.
func (s *Server) reviewCard(ctx context.Context, cardID string) (string, error) {
	card, _, agent, err := s.turnCaller(ctx)
	if err != nil {
		return "", err
	}
	if !agent {
		if strings.TrimSpace(cardID) == "" {
			return "", fault.New(fault.Invalid, "card_id is required")
		}
		return cardID, nil
	}
	if cardID != "" && cardID != card.ID {
		resolved, resolveErr := s.store.Kanban.ResolveCard(cardID)
		if resolveErr != nil || resolved.ID != card.ID {
			return "", fault.New(fault.PermissionDenied, "an agent turn can read only its own conversation's reviews")
		}
	}
	return card.ID, nil
}

// refuseAgentTurn refuses calls that carry an agent turn token.
func (s *Server) refuseAgentTurn(ctx context.Context, message string) error {
	_, _, agent, err := s.turnCaller(ctx)
	if err != nil {
		return err
	}
	if agent {
		return fault.New(fault.PermissionDenied, message)
	}
	return nil
}

func protoReviewerSettings(entry kv.ReviewerSettingsEntry) *dieterv1.ReviewerSettings {
	record := entry.Record
	return &dieterv1.ReviewerSettings{
		Harness: record.Harness, Model: record.Model, Effort: record.Effort, AccountId: record.AccountID,
		Depth: record.Depth, MaxFindings: int32(record.MaxFindings), MinConfidence: int32(record.MinConfidence),
		Instructions: record.Instructions, IgnoreGlobs: append([]string(nil), record.IgnoreGlobs...),
		MaxRounds: int32(record.MaxRounds), Configured: entry.Configured, Revision: entry.Revision, UpdatedAt: record.UpdatedAt,
	}
}

func protoCodeReview(value model.CodeReview) *dieterv1.CodeReview {
	return &dieterv1.CodeReview{
		Id: value.ID, CardId: value.CardID, Status: value.Status, Trigger: value.Trigger,
		Harness: value.Harness, Model: value.Model, Effort: value.Effort, Depth: value.Depth,
		BaseSha: value.BaseSHA, SnapshotSha: value.SnapshotSHA, StartedAt: value.StartedAt,
		FinishedAt: value.FinishedAt, DurationMs: value.DurationMS, Summary: value.Summary,
		Security: value.Security, Findings: protoFindings(value.Findings), Resolved: protoFindings(value.Resolved),
		Round: int32(value.Round), PreviousReviewId: value.PreviousReviewID, Error: value.Error,
		InputTokens: value.InputTokens, OutputTokens: value.OutputTokens, FilesChanged: int32(value.FilesChanged),
		Additions: int32(value.Additions), Deletions: int32(value.Deletions), Focus: value.Focus,
		ToolCallId: value.ToolCallID, MessageId: value.MessageID,
	}
}

func protoFindings(values []model.CodeReviewFinding) []*dieterv1.CodeReviewFinding {
	findings := make([]*dieterv1.CodeReviewFinding, 0, len(values))
	for _, value := range values {
		findings = append(findings, &dieterv1.CodeReviewFinding{
			Id: value.ID, File: value.File, StartLine: int32(value.StartLine), EndLine: int32(value.EndLine),
			Severity: value.Severity, Confidence: int32(value.Confidence), Title: value.Title, Body: value.Body,
			Suggestion: value.Suggestion, Status: value.Status,
		})
	}
	return findings
}
