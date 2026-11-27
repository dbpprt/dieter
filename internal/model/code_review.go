package model

// CodeReviewPartType is the message part that carries a code review: its
// data is the JSON form of CodeReview, updated in place (same ID) from
// running to its final status.
const CodeReviewPartType = "data-code-review"

// Code review statuses, triggers and depths.
const (
	CodeReviewRunning   = "running"
	CodeReviewCompleted = "completed"
	CodeReviewFailed    = "failed"
	CodeReviewCancelled = "cancelled"

	CodeReviewTriggerAgent = "agent"
	CodeReviewTriggerUser  = "user"

	CodeReviewDepthQuick    = "quick"
	CodeReviewDepthThorough = "thorough"
)

// Finding severities and statuses relative to the previous review.
const (
	FindingSeverityHigh   = "high"
	FindingSeverityMedium = "medium"
	FindingSeverityLow    = "low"

	FindingStatusNew      = "new"
	FindingStatusOpen     = "open"
	FindingStatusResolved = "resolved"
)

// CodeReview is one review of a conversation's changes (dieter.v1.CodeReview).
type CodeReview struct {
	ID               string              `json:"id"`
	CardID           string              `json:"cardId"`
	Status           string              `json:"status"`
	Trigger          string              `json:"trigger"`
	Harness          string              `json:"harness,omitempty"`
	Model            string              `json:"model,omitempty"`
	Effort           string              `json:"effort,omitempty"`
	Depth            string              `json:"depth,omitempty"`
	BaseSHA          string              `json:"baseSha,omitempty"`
	SnapshotSHA      string              `json:"snapshotSha,omitempty"`
	StartedAt        string              `json:"startedAt"`
	FinishedAt       string              `json:"finishedAt,omitempty"`
	DurationMS       int64               `json:"durationMs,omitempty"`
	Summary          string              `json:"summary,omitempty"`
	Security         string              `json:"security,omitempty"`
	Findings         []CodeReviewFinding `json:"findings,omitempty"`
	Resolved         []CodeReviewFinding `json:"resolved,omitempty"`
	Round            int                 `json:"round,omitempty"`
	PreviousReviewID string              `json:"previousReviewId,omitempty"`
	Error            string              `json:"error,omitempty"`
	InputTokens      int64               `json:"inputTokens,omitempty"`
	OutputTokens     int64               `json:"outputTokens,omitempty"`
	FilesChanged     int                 `json:"filesChanged,omitempty"`
	Additions        int                 `json:"additions,omitempty"`
	Deletions        int                 `json:"deletions,omitempty"`
	Focus            string              `json:"focus,omitempty"`
	ToolCallID       string              `json:"toolCallId,omitempty"`
	MessageID        string              `json:"messageId,omitempty"`
}

// CodeReviewFinding is one problem a review reports.
type CodeReviewFinding struct {
	ID         string `json:"id"`
	File       string `json:"file"`
	StartLine  int    `json:"startLine,omitempty"`
	EndLine    int    `json:"endLine,omitempty"`
	Severity   string `json:"severity"`
	Confidence int    `json:"confidence,omitempty"`
	Title      string `json:"title"`
	Body       string `json:"body"`
	Suggestion string `json:"suggestion,omitempty"`
	Status     string `json:"status,omitempty"`
}

// Final reports whether the review has finished, one way or another.
func (r CodeReview) Final() bool { return r.Status != CodeReviewRunning }
