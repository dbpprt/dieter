package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/engine/reviewer"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/home"
)

// Code review bounds.
const (
	codeReviewQuickTimeout    = 10 * time.Minute
	codeReviewThoroughTimeout = 20 * time.Minute
	codeReviewSnapshotTimeout = 2 * time.Minute
	// codeReviewDiffBudget bounds the diff inlined into the reviewer prompt
	// (about 50k tokens); larger changes list the rest for the reviewer to read.
	codeReviewDiffBudget = 200 << 10
	// codeReviewReplyBytes bounds the reviewer's reply the daemon keeps.
	codeReviewReplyBytes = 256 << 10
	maxCodeReviewFocus   = 1 << 10
)

// CodeReviewRequest starts a review. Trigger is model.CodeReviewTriggerUser or
// model.CodeReviewTriggerAgent; an agent review joins the turn's assistant
// message (MessageID), a user review gets a message of its own.
type CodeReviewRequest struct {
	Focus, Depth, Trigger     string
	TurnID, MessageID, CallID string
}

type codeReviewRun struct {
	id     string
	cancel context.CancelFunc
	done   chan struct{}
	// finishing is set (under Service.mu) once the review's final form is
	// known: from then on a new review may start, even before this one's
	// final part is written.
	finishing bool
}

// codeReviewJob is a review that has been admitted and recorded as running.
type codeReviewJob struct {
	review   model.CodeReview
	detail   model.CardDetail
	settings schema.ReviewerSettingsRecord
	adapter  harness.Adapter
	model    harness.Model
	previous *model.CodeReview
	turnID   string
	timeout  time.Duration
	run      *codeReviewRun
}

// SetCodeReview switches a local conversation's code reviewer; the next turn
// gets (or loses) request_code_review.
func (s *Service) SetCodeReview(cardRef string, enabled bool) (model.Card, error) {
	return s.Store.Kanban.SetCodeReview(cardRef, enabled)
}

// StartCodeReview admits a review of a local conversation's changes and runs
// it in the background; poll CodeReview for the result.
func (s *Service) StartCodeReview(cardRef string, request CodeReviewRequest) (model.CodeReview, error) {
	job, err := s.admitCodeReview(cardRef, request)
	if err != nil {
		return model.CodeReview{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), job.timeout)
	s.setCodeReviewCancel(job.run, cancel)
	go func() {
		defer cancel()
		s.executeCodeReview(ctx, job)
	}()
	return job.review, nil
}

// codeReviewToolCall answers an agent's request_code_review: it runs the
// review to the end within the turn and returns the findings as the tool's
// text result.
func (s *Service) codeReviewToolCall(ctx context.Context, cardID, turnID, messageID string, call harness.ProcessCall) (json.RawMessage, error) {
	var arguments struct {
		Focus      string `json:"focus"`
		ToolCallID string `json:"toolCallId"`
	}
	if len(call.Arguments) > 0 {
		if err := json.Unmarshal(call.Arguments, &arguments); err != nil {
			return nil, fault.New(fault.Invalid, "invalid request_code_review arguments")
		}
	}
	// The harness's own tool call ID links the review to the transcript's
	// request_code_review call; the bridge's ID is the fallback.
	callID := strings.TrimSpace(arguments.ToolCallID)
	if callID == "" || len(callID) > 128 {
		callID = call.ID
	}
	job, err := s.admitCodeReview(cardID, CodeReviewRequest{
		Focus: arguments.Focus, Trigger: model.CodeReviewTriggerAgent, TurnID: turnID, MessageID: messageID, CallID: callID,
	})
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, job.timeout)
	defer cancel()
	s.setCodeReviewCancel(job.run, cancel)
	review := s.executeCodeReview(ctx, job)
	return json.Marshal(reviewer.ToolResult(review))
}

// admitCodeReview checks the request, resolves the reviewer, records the
// review as running and registers it as the conversation's one running review.
func (s *Service) admitCodeReview(cardRef string, request CodeReviewRequest) (*codeReviewJob, error) {
	detail, err := s.Store.Kanban.CardDetail(cardRef)
	if err != nil {
		return nil, err
	}
	if err := s.Store.Kanban.RequireLocalCard(detail.Card); err != nil {
		return nil, err
	}
	if detail.Project.ID == "" {
		return nil, fault.New(fault.FailedPrecondition, "this conversation has no project to review")
	}
	if len(request.Focus) > maxCodeReviewFocus {
		return nil, fault.New(fault.Invalid, "the review focus is limited to 1 KiB")
	}
	entry, err := s.Store.KV.ReviewerSettings()
	if err != nil {
		return nil, err
	}
	settings := entry.Record
	depth := strings.TrimSpace(request.Depth)
	if depth == "" {
		depth = settings.Depth
	}
	if depth != model.CodeReviewDepthQuick && depth != model.CodeReviewDepthThorough {
		return nil, fault.New(fault.Invalid, `review depth must be "quick" or "thorough"`)
	}
	adapter, configured, err := s.Catalog.ResolveSelection(settings.Harness, settings.Model)
	if err != nil {
		return nil, fault.Errorf(fault.FailedPrecondition, "the reviewer harness is not available on this machine: %v", err)
	}
	if adapter.Runtime == strixAdapter {
		return nil, fault.New(fault.FailedPrecondition, "Strix cannot be the code reviewer; choose another harness in the reviewer setting")
	}
	effort := settings.Effort
	if effort == "" {
		effort = configured.DefaultEffort
	}
	if effort, err = harness.ResolveEffort(adapter, configured, effort); err != nil {
		return nil, err
	}
	conversation, err := s.Store.Conversations.Get(detail.Card.ID)
	if err != nil {
		return nil, err
	}
	var previous *model.CodeReview
	round := 1
	reviews := conversations.CodeReviews(conversation)
	for index := len(reviews) - 1; index >= 0; index-- {
		if reviews[index].Status == model.CodeReviewCompleted {
			previous = &reviews[index]
			round = reviews[index].Round + 1
			break
		}
	}
	timeout := codeReviewQuickTimeout
	if depth == model.CodeReviewDepthThorough {
		timeout = codeReviewThoroughTimeout
	}
	review := model.CodeReview{
		ID: newRuntimeID("rev_"), CardID: detail.Card.ID, Status: model.CodeReviewRunning, Trigger: request.Trigger,
		Harness: adapter.ID, Model: configured.ID, Effort: effort, Depth: depth, StartedAt: home.Timestamp(),
		Focus: strings.TrimSpace(request.Focus), ToolCallID: request.CallID, Round: round,
	}
	if previous != nil {
		review.PreviousReviewID = previous.ID
	}
	run := &codeReviewRun{id: review.ID, done: make(chan struct{})}
	s.mu.Lock()
	if s.shuttingDown {
		s.mu.Unlock()
		return nil, fault.New(fault.Unavailable, "the daemon is shutting down")
	}
	if current := s.codeReviews[detail.Card.ID]; current != nil && !current.finishing {
		s.mu.Unlock()
		return nil, fault.Errorf(fault.FailedPrecondition, "code review %s is still running for this conversation; wait for its result", current.id)
	}
	if s.codeReviews == nil {
		s.codeReviews = map[string]*codeReviewRun{}
	}
	s.codeReviews[detail.Card.ID] = run
	s.mu.Unlock()
	if _, err := s.Store.Conversations.AppendCodeReview(detail.Card.ID, request.TurnID, request.MessageID, review); err != nil {
		s.finishCodeReviewRun(detail.Card.ID, run)
		return nil, err
	}
	reviewForMessage, _ := s.codeReviewByID(detail.Card.ID, review.ID)
	review.MessageID = reviewForMessage.MessageID
	return &codeReviewJob{
		review: review, detail: detail, settings: settings, adapter: adapter, model: configured,
		previous: previous, turnID: request.TurnID, timeout: timeout, run: run,
	}, nil
}

// executeCodeReview runs an admitted review and records its final form.
func (s *Service) executeCodeReview(ctx context.Context, job *codeReviewJob) model.CodeReview {
	defer s.finishCodeReviewRun(job.detail.Card.ID, job.run)
	started := time.Now()
	review, err := s.reviewChanges(ctx, job)
	review.FinishedAt = home.Timestamp()
	review.DurationMS = time.Since(started).Milliseconds()
	switch {
	case err == nil:
		review.Status = model.CodeReviewCompleted
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		review.Status, review.Error = model.CodeReviewFailed, fmt.Sprintf("the review did not finish within %s", job.timeout)
	case ctx.Err() != nil:
		review.Status, review.Error = model.CodeReviewCancelled, "the review was cancelled"
	default:
		review.Status, review.Error = model.CodeReviewFailed, reviewError(err)
	}
	// A client that sees the final part may start the next review at once.
	s.mu.Lock()
	job.run.finishing = true
	s.mu.Unlock()
	if _, appendErr := s.Store.Conversations.AppendCodeReview(job.detail.Card.ID, job.turnID, review.MessageID, review); appendErr != nil {
		review.Status, review.Error = model.CodeReviewFailed, appendErr.Error()
	}
	return review
}

// reviewChanges snapshots the workspace, reads the change and asks the
// reviewer harness. The returned review carries what is known even on error.
func (s *Service) reviewChanges(ctx context.Context, job *codeReviewJob) (model.CodeReview, error) {
	review := job.review
	directory, base, err := s.codeReviewWorkspace(ctx, job.detail)
	if err != nil {
		return review, err
	}
	snapshotCtx, cancelSnapshot := context.WithTimeout(ctx, codeReviewSnapshotTimeout)
	snapshot, err := reviewer.TakeSnapshot(snapshotCtx, directory, filepath.Join(s.Store.RuntimeDir(), "reviews", review.ID))
	cancelSnapshot()
	if err != nil {
		return review, err
	}
	defer snapshot.Close()
	from := reviewer.MergeBase(ctx, snapshot.Dir, base, snapshot.Head)
	change, err := reviewer.ReadChange(ctx, snapshot.Dir, from, snapshot.Tree, job.settings.IgnoreGlobs, codeReviewDiffBudget)
	if err != nil {
		return review, err
	}
	if from != reviewer.EmptyTree {
		review.BaseSHA = from
	}
	review.SnapshotSHA = snapshot.Commit
	review.FilesChanged, review.Additions, review.Deletions = len(change.Files), change.Additions, change.Deletions
	if len(change.Files) == 0 {
		review.Summary = "There are no changes to review."
		review.Security = "No"
		if job.previous != nil {
			_, review.Resolved = reviewer.CompareRounds(job.previous.Findings, nil)
		}
		return review, nil
	}
	options := reviewer.Options{
		Depth: review.Depth, MaxFindings: job.settings.MaxFindings, MinConfidence: job.settings.MinConfidence,
		Instructions: job.settings.Instructions, Focus: review.Focus,
	}
	reply, usage, err := s.runReviewer(ctx, job, snapshot.Dir, reviewer.Instructions(options), reviewer.Prompt(change, options, job.previous))
	review.InputTokens, review.OutputTokens = usage.input, usage.output
	if err != nil {
		return review, err
	}
	answer, err := reviewer.Parse(reply, change, snapshot.Dir, options)
	if err != nil {
		return review, err
	}
	review.Summary, review.Security, review.Findings = answer.Summary, answer.Security, answer.Findings
	if job.previous != nil {
		review.Findings, review.Resolved = reviewer.CompareRounds(job.previous.Findings, review.Findings)
	}
	return review, nil
}

// codeReviewWorkspace is the directory a review reads and the base its
// change is measured from: a worktree's base commit (or branch), or nothing
// for a project checkout, whose change is its uncommitted work.
func (s *Service) codeReviewWorkspace(ctx context.Context, detail model.CardDetail) (string, string, error) {
	value, err := s.Store.Workspaces.Get(detail.Card.ID)
	if err != nil || value.Path == "" || value.State == model.WorkspaceStateProvisioning {
		if s.Workspaces == nil {
			return "", "", fault.New(fault.FailedPrecondition, "this conversation has no workspace yet")
		}
		value, err = s.Workspaces.Ensure(ctx, detail.Card.ID)
		if err != nil {
			return "", "", err
		}
	}
	if value.Mode == model.WorkspaceModeWorktree {
		for _, base := range []string{value.CurrentBaseSHA, value.BaseSHA, value.BaseBranch} {
			if base != "" {
				return value.Path, base, nil
			}
		}
		return value.Path, "", nil
	}
	project, err := s.Store.Kanban.ProjectForCheckout(detail.Project.ID, detail.Card.CheckoutID)
	if err != nil {
		return "", "", err
	}
	return project.Path, "", nil
}

type reviewUsage struct{ input, output int64 }

// runReviewer runs the reviewer harness turn in the snapshot: a bare request
// like quick titles, with no host tools, no steering and its own session.
func (s *Service) runReviewer(ctx context.Context, job *codeReviewJob, directory, instructions, prompt string) (string, reviewUsage, error) {
	// Oh My Pi gets its provider tokens through the running turn's token
	// (ADR 0007); a bare review turn has none.
	if job.adapter.Runtime == ompAdapter {
		return "", reviewUsage{}, fault.New(fault.FailedPrecondition, "Oh My Pi cannot review yet; choose Claude Code or Codex as the reviewer")
	}
	selection := model.HarnessSelection{Provider: job.adapter.ID, Model: job.model.ID, AccountID: job.settings.AccountID}
	auth, err := s.resolveTurnAuth(job.adapter.Runtime, &selection)
	if err != nil {
		return "", reviewUsage{}, err
	}
	options, err := harness.ResolveOptionsForModel(job.adapter, job.model.ID, nil)
	if err != nil {
		return "", reviewUsage{}, err
	}
	request := harness.Request{
		Harness: job.adapter.ID, Adapter: job.adapter.Runtime, Model: job.model.RuntimeID(), ConfiguredModel: job.model.ID,
		ContextWindow: job.model.ContextWindow, Effort: job.review.Effort, Options: options,
		Prompt: prompt, Instructions: instructions,
		SessionID: newRuntimeID("review_"), ResponseMessageID: newRuntimeID("msg_"),
		ProjectPath: directory, RuntimeRoot: filepath.Join(s.Store.RuntimeDir(), "review-sessions"),
	}
	applyTurnAuth(auth, &request)
	var reply strings.Builder
	var usage reviewUsage
	var failure string
	runErr := s.Runner.Run(ctx, request, func(output harness.Output) error {
		switch output.Type {
		case "chunk":
			var chunk struct {
				Type            string `json:"type"`
				Delta           string `json:"delta"`
				MessageMetadata struct {
					Usage      *tokenUsage `json:"usage"`
					TotalUsage *tokenUsage `json:"totalUsage"`
				} `json:"messageMetadata"`
			}
			if json.Unmarshal(output.Chunk, &chunk) != nil {
				return nil
			}
			if chunk.Type == "text-delta" && reply.Len() < codeReviewReplyBytes {
				reply.WriteString(chunk.Delta)
			}
			if total := chunk.MessageMetadata.TotalUsage; total != nil {
				usage = reviewUsage{input: total.InputTokens, output: total.OutputTokens}
			} else if current := chunk.MessageMetadata.Usage; current != nil && usage.input == 0 {
				usage = reviewUsage{input: current.InputTokens, output: current.OutputTokens}
			}
		case "provider-usage":
			if s.Accounts != nil && request.ProviderAccountID != "" && len(output.Data) > 0 {
				s.Accounts.ObserveUsage(request.ProviderAccountID, output.Data)
			}
		case "auth-failure":
			if s.Accounts != nil && request.ProviderAccountID != "" {
				s.Accounts.MarkExpired(request.ProviderAccountID, output.Reason)
			}
		case "error":
			failure = strings.TrimSpace(output.Message)
		}
		return nil
	})
	if cleaner, ok := s.Runner.(harness.Cleaner); ok {
		_ = cleaner.Cleanup(request.SessionID, request.RuntimeRoot)
	}
	if s.Accounts != nil && request.ProviderAccountID != "" && usage.input+usage.output > 0 {
		s.Accounts.RecordTurnTokens(request.ProviderAccountID, time.Now(), usage.input, usage.output, usage.input+usage.output)
	}
	if runErr == nil && failure != "" {
		runErr = errors.New(failure)
	}
	if runErr != nil {
		return reply.String(), usage, fmt.Errorf("the reviewer (%s) failed: %w", job.adapter.Name, runErr)
	}
	return reply.String(), usage, nil
}

type tokenUsage struct {
	InputTokens  int64 `json:"inputTokens"`
	OutputTokens int64 `json:"outputTokens"`
}

func (s *Service) finishCodeReviewRun(cardID string, run *codeReviewRun) {
	s.mu.Lock()
	if s.codeReviews[cardID] == run {
		delete(s.codeReviews, cardID)
	}
	s.mu.Unlock()
	select {
	case <-run.done:
	default:
		close(run.done)
	}
}

// cancelCodeReviews stops every running review (daemon shutdown).
func (s *Service) cancelCodeReviews() {
	s.mu.Lock()
	cancels := make([]context.CancelFunc, 0, len(s.codeReviews))
	for _, run := range s.codeReviews {
		if run.cancel != nil {
			cancels = append(cancels, run.cancel)
		}
	}
	s.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

// setCodeReviewCancel records how to stop a running review.
func (s *Service) setCodeReviewCancel(run *codeReviewRun, cancel context.CancelFunc) {
	s.mu.Lock()
	run.cancel = cancel
	s.mu.Unlock()
}

// CodeReview returns one review of a conversation.
func (s *Service) CodeReview(cardRef, reviewID string) (model.CodeReview, error) {
	card, err := s.Store.Kanban.ResolveCard(cardRef)
	if err != nil {
		return model.CodeReview{}, err
	}
	return s.codeReviewByID(card.ID, reviewID)
}

func (s *Service) codeReviewByID(cardID, reviewID string) (model.CodeReview, error) {
	reviews, err := s.CodeReviews(cardID)
	if err != nil {
		return model.CodeReview{}, err
	}
	for _, review := range reviews {
		if review.ID == reviewID {
			return review, nil
		}
	}
	return model.CodeReview{}, fault.New(fault.NotFound, "code review not found")
}

// CodeReviews lists a conversation's reviews, newest first.
func (s *Service) CodeReviews(cardRef string) ([]model.CodeReview, error) {
	card, err := s.Store.Kanban.ResolveCard(cardRef)
	if err != nil {
		return nil, err
	}
	conversation, err := s.Store.Conversations.Get(card.ID)
	if err != nil {
		return nil, err
	}
	reviews := conversations.CodeReviews(conversation)
	for left, right := 0, len(reviews)-1; left < right; left, right = left+1, right-1 {
		reviews[left], reviews[right] = reviews[right], reviews[left]
	}
	return reviews, nil
}

// codeReviewContext prefixes a prompt with the reviews the user ran since the
// previous message, so the agent sees their findings with the next message.
// The new user message is the conversation's last.
func codeReviewContext(conversation model.Conversation, prompt string) string {
	var reviews []model.CodeReview
	messages := conversation.Messages
	last := len(messages) - 1
	for last >= 0 && messages[last].Role != "user" {
		last--
	}
	for index := last - 1; index >= 0; index-- {
		if messages[index].Role == "user" {
			break
		}
		for _, part := range messages[index].Parts {
			if part.Type != model.CodeReviewPartType {
				continue
			}
			var review model.CodeReview
			if json.Unmarshal(part.Data, &review) == nil && review.Trigger == model.CodeReviewTriggerUser && review.Status == model.CodeReviewCompleted {
				reviews = append([]model.CodeReview{review}, reviews...)
			}
		}
	}
	if len(reviews) == 0 {
		return prompt
	}
	var out strings.Builder
	out.WriteString("<code_review>\nBefore this message the user ran Dieter's code reviewer on your changes. Treat its findings like a reviewer's comments: fix what you agree with and say why you reject the rest.\n")
	for _, review := range reviews {
		out.WriteString("\n" + reviewer.ToolResult(review))
	}
	out.WriteString("</code_review>\n\n")
	out.WriteString(prompt)
	return out.String()
}

func reviewError(err error) string {
	message := strings.TrimSpace(err.Error())
	if errors.Is(err, reviewer.ErrNoAnswer) {
		return "the reviewer did not return a readable review; try again or choose another model"
	}
	if line, _, found := strings.Cut(message, "\n"); found {
		message = line
	}
	if len(message) > 1024 {
		message = message[:1024]
	}
	return message
}

// enableCodeReview offers a turn the request_code_review tool. Its handler
// runs the review within the turn, as host work, so the liveness watchdog
// does not blame the waiting worker.
func (s *Service) enableCodeReview(detail model.CardDetail, turnID string, request *harness.Request) {
	maxRounds := schema.ReviewerDefaultMaxRounds
	if entry, err := s.Store.KV.ReviewerSettings(); err == nil {
		maxRounds = entry.Record.MaxRounds
	}
	cardID, messageID := detail.Card.ID, request.ResponseMessageID
	request.CodeReviewEnabled = true
	request.CodeReviewMaxRounds = maxRounds
	request.ReviewCommand = s.CLIWord() + " " + conversationGroup(detail.Card) + " review " + cardID + " --wait"
	request.CodeReview = func(ctx context.Context, call harness.ProcessCall) (json.RawMessage, error) {
		endHostWork, _ := s.beginTurnHostWork(cardID, turnID)
		defer endHostWork()
		return s.codeReviewToolCall(ctx, cardID, turnID, messageID, call)
	}
}
