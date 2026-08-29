package model

import "encoding/json"

const (
	ConversationScopeBoard = "board"
	ConversationScopeChat  = "chat"

	WorkspaceModeMain     = "main"
	WorkspaceModeBranch   = "branch"
	WorkspaceModeWorktree = "worktree"

	WorkspaceStateReserved         = "reserved"
	WorkspaceStateProvisioning     = "provisioning"
	WorkspaceStateReady            = "ready"
	WorkspaceStateConflicted       = "conflicted"
	WorkspaceStateCleanupPending   = "cleanup_pending"
	WorkspaceStateOrphaned         = "orphaned"
	WorkspaceStateRecoveryRequired = "recovery_required"
	WorkspaceStateFailed           = "failed"

	GitOperationQueued               = "queued"
	GitOperationRunning              = "running"
	GitOperationWaitingForResolution = "waiting_for_resolution"
	GitOperationSucceeded            = "succeeded"
	GitOperationFailed               = "failed"
	GitOperationCanceled             = "canceled"
	GitOperationInterrupted          = "interrupted"

	WorkflowDirect = "direct"
	WorkflowReview = "review"

	LaneTodo    = "todo"
	LaneRunning = "running"
	LaneReview  = "review"
	LaneDone    = "done"

	DoneArchiveNever       = "never"
	DoneArchiveImmediately = "immediately"
	DoneArchiveAfter1Day   = "after_1_day"
	DoneArchiveAfter7Days  = "after_7_days"
	DoneArchiveAfter30Days = "after_30_days"
	DoneArchiveAfter90Days = "after_90_days"
)

type Lane struct {
	ID   string `json:"id" yaml:"id"`
	Name string `json:"name" yaml:"name"`
}

func WorkflowLanes(workflow string) []Lane {
	lanes := []Lane{{ID: LaneTodo, Name: "Todo"}, {ID: LaneRunning, Name: "Running"}}
	if workflow == WorkflowReview {
		lanes = append(lanes, Lane{ID: LaneReview, Name: "Review"})
	}
	return append(lanes, Lane{ID: LaneDone, Name: "Done"})
}

type Project struct {
	ID                   string              `json:"id" yaml:"id"`
	Name                 string              `json:"name" yaml:"name"`
	Path                 string              `json:"path" yaml:"path"`
	Summary              string              `json:"summary,omitempty" yaml:"summary,omitempty"`
	Prompt               string              `json:"prompt" yaml:"-"`
	PromptTemplate       string              `json:"promptTemplate,omitempty" yaml:"prompt_template,omitempty"`
	Archived             bool                `json:"archived,omitempty" yaml:"archived,omitempty"`
	CreatedAt            string              `json:"createdAt" yaml:"created_at"`
	UpdatedAt            string              `json:"updatedAt" yaml:"updated_at"`
	BoardCount           int                 `json:"boardCount,omitempty" yaml:"-"`
	CardCount            int                 `json:"cardCount,omitempty" yaml:"-"`
	ChatCount            int                 `json:"chatCount,omitempty" yaml:"-"`
	DefaultWorkspaceMode string              `json:"defaultWorkspaceMode,omitempty" yaml:"default_workspace_mode,omitempty"`
	BaseRemote           string              `json:"baseRemote,omitempty" yaml:"base_remote,omitempty"`
	BaseBranch           string              `json:"baseBranch,omitempty" yaml:"base_branch,omitempty"`
	ValidationCommands   []ValidationCommand `json:"validationCommands,omitempty" yaml:"validation_commands,omitempty"`
}

type ValidationCommand struct {
	Name             string            `json:"name" yaml:"name"`
	Executable       string            `json:"executable" yaml:"executable"`
	Arguments        []string          `json:"arguments,omitempty" yaml:"arguments,omitempty"`
	WorkingDirectory string            `json:"workingDirectory,omitempty" yaml:"working_directory,omitempty"`
	Environment      map[string]string `json:"environment,omitempty" yaml:"environment,omitempty"`
	TimeoutSeconds   int               `json:"timeoutSeconds,omitempty" yaml:"timeout_seconds,omitempty"`
}

type Board struct {
	ID                string  `json:"id" yaml:"id"`
	ProjectID         string  `json:"projectId" yaml:"project_id"`
	Name              string  `json:"name" yaml:"name"`
	Workflow          string  `json:"workflow" yaml:"workflow"`
	Description       string  `json:"description,omitempty" yaml:"-"`
	PromptTemplate    string  `json:"promptTemplate,omitempty" yaml:"prompt_template,omitempty"`
	DoneArchivePolicy string  `json:"doneArchivePolicy" yaml:"done_archive_policy,omitempty"`
	CreatedAt         string  `json:"createdAt" yaml:"created_at"`
	UpdatedAt         string  `json:"updatedAt" yaml:"updated_at"`
	Labels            []Label `json:"labels,omitempty" yaml:"labels,omitempty"`
	Lanes             []Lane  `json:"lanes" yaml:"-"`
}

type Label struct {
	ID           string `json:"id" yaml:"id"`
	Name         string `json:"name" yaml:"name"`
	Color        string `json:"color" yaml:"color"`
	Instructions string `json:"instructions,omitempty" yaml:"instructions,omitempty"`
}

type Card struct {
	ID                  string              `json:"id" yaml:"id"`
	Scope               string              `json:"scope" yaml:"scope,omitempty"`
	ProjectID           string              `json:"projectId" yaml:"project_id"`
	BoardID             string              `json:"boardId" yaml:"board_id"`
	Lane                string              `json:"lane" yaml:"lane"`
	Position            int64               `json:"position" yaml:"position"`
	Title               string              `json:"title" yaml:"title"`
	InitialPrompt       string              `json:"initialPrompt" yaml:"-"`
	InitialPromptSentAt string              `json:"initialPromptSentAt,omitempty" yaml:"initial_prompt_sent_at,omitempty"`
	PhaseChangedAt      string              `json:"phaseChangedAt" yaml:"phase_changed_at"`
	Provider            string              `json:"provider,omitempty" yaml:"provider_cache,omitempty"`
	Model               string              `json:"model,omitempty" yaml:"model_cache,omitempty"`
	Effort              string              `json:"effort,omitempty" yaml:"effort_cache,omitempty"`
	ProviderOptions     map[string]string   `json:"providerOptions,omitempty" yaml:"provider_options_cache,omitempty"`
	Runtime             string              `json:"runtime" yaml:"runtime_cache,omitempty"`
	Summary             string              `json:"summary,omitempty" yaml:"summary_cache,omitempty"`
	RuntimeUpdatedAt    string              `json:"runtimeUpdatedAt,omitempty" yaml:"runtime_updated_at,omitempty"`
	LastActivityAt      string              `json:"lastActivityAt,omitempty" yaml:"last_activity_at,omitempty"`
	Archived            bool                `json:"archived,omitempty" yaml:"archived,omitempty"`
	DoneArchiveExempt   bool                `json:"doneArchiveExempt,omitempty" yaml:"done_archive_exempt,omitempty"`
	Pinned              bool                `json:"pinned,omitempty" yaml:"pinned,omitempty"`
	CreatedAt           string              `json:"createdAt" yaml:"created_at"`
	UpdatedAt           string              `json:"updatedAt" yaml:"updated_at"`
	LabelIDs            []string            `json:"labelIds,omitempty" yaml:"labels,omitempty"`
	Origin              *CardOrigin         `json:"origin,omitempty" yaml:"origin,omitempty"`
	CommentCount        int                 `json:"commentCount" yaml:"-"`
	WorkspaceMode       string              `json:"workspaceMode,omitempty" yaml:"workspace_mode,omitempty"`
	WorkspaceBranch     string              `json:"workspaceBranch,omitempty" yaml:"workspace_branch,omitempty"`
	WorkspaceBaseBranch string              `json:"workspaceBaseBranch,omitempty" yaml:"workspace_base_branch,omitempty"`
	Workspace           *WorkspaceSummary   `json:"workspace,omitempty" yaml:"-"`
	PullRequest         *PullRequestSummary `json:"pullRequest,omitempty" yaml:"-"`
}

// Workspace is the durable execution location for either a board card or a
// standalone chat. Both scopes use the card ID as their conversation and
// workspace identity, so lifecycle and Git behavior cannot drift apart.
type Workspace struct {
	CardID              string   `json:"cardId"`
	ProjectID           string   `json:"projectId"`
	Mode                string   `json:"mode"`
	Path                string   `json:"path"`
	BaseRemote          string   `json:"baseRemote,omitempty"`
	BaseBranch          string   `json:"baseBranch,omitempty"`
	BaseSHA             string   `json:"baseSha,omitempty"`
	CurrentBaseSHA      string   `json:"currentBaseSha,omitempty"`
	Branch              string   `json:"branch,omitempty"`
	HeadSHA             string   `json:"headSha,omitempty"`
	UpstreamRef         string   `json:"upstreamRef,omitempty"`
	ManagedBranch       bool     `json:"managedBranch,omitempty"`
	LegacyUnmanaged     bool     `json:"legacyUnmanaged,omitempty"`
	State               string   `json:"state"`
	Revision            string   `json:"revision,omitempty"`
	CurrentOperationID  string   `json:"currentOperationId,omitempty"`
	IntegratedHeadSHA   string   `json:"integratedHeadSha,omitempty"`
	IntegratedResultSHA string   `json:"integratedResultSha,omitempty"`
	IntegrationStrategy string   `json:"integrationStrategy,omitempty"`
	IntegratedAt        string   `json:"integratedAt,omitempty"`
	PreviousCardIDs     []string `json:"previousCardIds,omitempty"`
	ChangedFiles        int      `json:"changedFiles,omitempty"`
	Additions           int      `json:"additions,omitempty"`
	Deletions           int      `json:"deletions,omitempty"`
	Ahead               int      `json:"ahead,omitempty"`
	Behind              int      `json:"behind,omitempty"`
	Dirty               bool     `json:"dirty,omitempty"`
	SizeBytes           int64    `json:"sizeBytes,omitempty"`
	CreatedAt           string   `json:"createdAt"`
	UpdatedAt           string   `json:"updatedAt"`
	LastActivityAt      string   `json:"lastActivityAt,omitempty"`
}

type WorkspaceSummary struct {
	Mode               string `json:"mode"`
	State              string `json:"state"`
	Branch             string `json:"branch,omitempty"`
	BaseBranch         string `json:"baseBranch,omitempty"`
	Revision           string `json:"revision,omitempty"`
	HeadSHA            string `json:"headSha,omitempty"`
	BaseSHA            string `json:"baseSha,omitempty"`
	CurrentOperationID string `json:"currentOperationId,omitempty"`
	Dirty              bool   `json:"dirty,omitempty"`
	Conflicted         bool   `json:"conflicted,omitempty"`
	Ahead              int    `json:"ahead,omitempty"`
	Behind             int    `json:"behind,omitempty"`
	ChangedFiles       int    `json:"changedFiles,omitempty"`
	Additions          int    `json:"additions,omitempty"`
	Deletions          int    `json:"deletions,omitempty"`
	SizeBytes          int64  `json:"sizeBytes,omitempty"`
	LastRefreshedAt    string `json:"lastRefreshedAt,omitempty"`
}

type ChangedFile struct {
	Path         string `json:"path"`
	PreviousPath string `json:"previousPath,omitempty"`
	Status       string `json:"status"`
	Additions    int    `json:"additions,omitempty"`
	Deletions    int    `json:"deletions,omitempty"`
	Binary       bool   `json:"binary,omitempty"`
	Submodule    bool   `json:"submodule,omitempty"`
	Conflicted   bool   `json:"conflicted,omitempty"`
	HunkCount    int    `json:"hunkCount,omitempty"`
}

type WorkspaceCommit struct {
	SHA        string `json:"sha"`
	ParentSHA  string `json:"parentSha,omitempty"`
	Subject    string `json:"subject"`
	Author     string `json:"author,omitempty"`
	AuthoredAt string `json:"authoredAt,omitempty"`
	Additions  int    `json:"additions,omitempty"`
	Deletions  int    `json:"deletions,omitempty"`
	Files      int    `json:"files,omitempty"`
}

type Changeset struct {
	CardID         string            `json:"cardId"`
	Revision       string            `json:"revision"`
	BaseBranch     string            `json:"baseBranch,omitempty"`
	BaseSHA        string            `json:"baseSha,omitempty"`
	CurrentBaseSHA string            `json:"currentBaseSha,omitempty"`
	MergeBaseSHA   string            `json:"mergeBaseSha,omitempty"`
	HeadSHA        string            `json:"headSha,omitempty"`
	Ahead          int               `json:"ahead,omitempty"`
	Behind         int               `json:"behind,omitempty"`
	Additions      int               `json:"additions,omitempty"`
	Deletions      int               `json:"deletions,omitempty"`
	Dirty          bool              `json:"dirty,omitempty"`
	Volatile       bool              `json:"volatile,omitempty"`
	Files          []ChangedFile     `json:"files,omitempty"`
	Commits        []WorkspaceCommit `json:"commits,omitempty"`
	CreatedAt      string            `json:"createdAt"`
}

type FileDiff struct {
	CardID       string `json:"cardId"`
	Revision     string `json:"revision"`
	Path         string `json:"path"`
	PreviousPath string `json:"previousPath,omitempty"`
	CommitSHA    string `json:"commitSha,omitempty"`
	Patch        string `json:"patch,omitempty"`
	Binary       bool   `json:"binary,omitempty"`
	Truncated    bool   `json:"truncated,omitempty"`
	NextOffset   int    `json:"nextOffset,omitempty"`
	TotalBytes   int    `json:"totalBytes,omitempty"`
}

type ValidationResult struct {
	Name       string `json:"name"`
	ExitCode   int    `json:"exitCode"`
	Output     string `json:"output,omitempty"`
	Truncated  bool   `json:"truncated,omitempty"`
	DurationMS int64  `json:"durationMs,omitempty"`
}

type GitConflict struct {
	Path      string `json:"path"`
	HunkCount int    `json:"hunkCount,omitempty"`
}

type GitOperation struct {
	ID                string             `json:"id"`
	CardID            string             `json:"cardId"`
	ProjectID         string             `json:"projectId"`
	Kind              string             `json:"kind"`
	Status            string             `json:"status"`
	ExpectedRevision  string             `json:"expectedRevision,omitempty"`
	ExpectedBaseSHA   string             `json:"expectedBaseSha,omitempty"`
	ExpectedHeadSHA   string             `json:"expectedHeadSha,omitempty"`
	Parameters        map[string]string  `json:"parameters,omitempty"`
	CompletedSteps    []string           `json:"completedSteps,omitempty"`
	Conflicts         []GitConflict      `json:"conflicts,omitempty"`
	ValidationResults []ValidationResult `json:"validationResults,omitempty"`
	Result            string             `json:"result,omitempty"`
	Error             string             `json:"error,omitempty"`
	Sequence          uint64             `json:"sequence,omitempty"`
	CreatedAt         string             `json:"createdAt"`
	StartedAt         string             `json:"startedAt,omitempty"`
	FinishedAt        string             `json:"finishedAt,omitempty"`
	UpdatedAt         string             `json:"updatedAt"`
}

type PullRequestSummary struct {
	Provider       string `json:"provider,omitempty"`
	Number         int    `json:"number"`
	URL            string `json:"url,omitempty"`
	State          string `json:"state,omitempty"`
	ReviewDecision string `json:"reviewDecision,omitempty"`
	ChecksState    string `json:"checksState,omitempty"`
	Mergeable      bool   `json:"mergeable,omitempty"`
	Draft          bool   `json:"draft,omitempty"`
	HeadSHA        string `json:"headSha,omitempty"`
	BaseSHA        string `json:"baseSha,omitempty"`
	UpdatedAt      string `json:"updatedAt,omitempty"`
}

type PullRequest struct {
	CardID         string `json:"cardId"`
	Provider       string `json:"provider"`
	Host           string `json:"host,omitempty"`
	Owner          string `json:"owner,omitempty"`
	Repository     string `json:"repository,omitempty"`
	Number         int    `json:"number"`
	URL            string `json:"url,omitempty"`
	HeadRef        string `json:"headRef,omitempty"`
	HeadSHA        string `json:"headSha,omitempty"`
	BaseRef        string `json:"baseRef,omitempty"`
	BaseSHA        string `json:"baseSha,omitempty"`
	State          string `json:"state,omitempty"`
	Draft          bool   `json:"draft,omitempty"`
	Mergeable      bool   `json:"mergeable,omitempty"`
	ReviewDecision string `json:"reviewDecision,omitempty"`
	ChecksState    string `json:"checksState,omitempty"`
	Additions      int    `json:"additions,omitempty"`
	Deletions      int    `json:"deletions,omitempty"`
	ChangedFiles   int    `json:"changedFiles,omitempty"`
	LastSyncedAt   string `json:"lastSyncedAt,omitempty"`
}

type SCMCapabilities struct {
	Provider             string `json:"provider,omitempty"`
	Host                 string `json:"host,omitempty"`
	Owner                string `json:"owner,omitempty"`
	Repository           string `json:"repository,omitempty"`
	Remote               string `json:"remote,omitempty"`
	RemoteAvailable      bool   `json:"remoteAvailable,omitempty"`
	PushAvailable        bool   `json:"pushAvailable,omitempty"`
	ProviderAPIAvailable bool   `json:"providerApiAvailable,omitempty"`
	Authenticated        bool   `json:"authenticated,omitempty"`
	UnavailableReason    string `json:"unavailableReason,omitempty"`
}

type ChangeComment struct {
	ID                string `json:"id"`
	CardID            string `json:"cardId"`
	ChangesetRevision string `json:"changesetRevision"`
	Path              string `json:"path"`
	Side              string `json:"side,omitempty"`
	Line              int    `json:"line,omitempty"`
	HunkContext       string `json:"hunkContext,omitempty"`
	Body              string `json:"body"`
	Author            Author `json:"author"`
	CreatedAt         string `json:"createdAt"`
	ResolvedAt        string `json:"resolvedAt,omitempty"`
}

// CardOrigin links cards produced by automations back to the durable
// occurrence that created them. User-created cards leave Origin unset.
type CardOrigin struct {
	Kind          string `json:"kind" yaml:"kind"`
	ScheduleID    string `json:"scheduleId" yaml:"schedule_id"`
	ScheduleRunID string `json:"scheduleRunId" yaml:"schedule_run_id"`
	ScheduledFor  string `json:"scheduledFor" yaml:"scheduled_for"`
}

const (
	ScheduleActionDraft = "draft"
	ScheduleActionRun   = "run"

	ScheduleRunPending           = "pending"
	ScheduleRunWaitingForProject = "waiting_for_project"
	ScheduleRunStarting          = "starting"
	ScheduleRunRunning           = "running"
	ScheduleRunCompleted         = "completed"
	ScheduleRunInterrupted       = "interrupted"
	ScheduleRunFailed            = "failed"
	ScheduleRunSkipped           = "skipped"
	ScheduleRunCancelled         = "cancelled"
)

// Settings are global admission controls. Zero means unlimited. Overrides
// are keyed by stable harness and board IDs so renames do not change policy.
type Settings struct {
	GlobalParallelLimit         int            `json:"globalParallelLimit" yaml:"global_parallel_limit"`
	AgentParallelLimits         map[string]int `json:"agentParallelLimits,omitempty" yaml:"agent_parallel_limits,omitempty"`
	BoardParallelLimits         map[string]int `json:"boardParallelLimits,omitempty" yaml:"board_parallel_limits,omitempty"`
	PromptTemplate              string         `json:"promptTemplate,omitempty" yaml:"prompt_template,omitempty"`
	BoardSkillTemplate          string         `json:"boardSkillTemplate,omitempty" yaml:"board_skill_template,omitempty"`
	ChatSkillTemplate           string         `json:"chatSkillTemplate,omitempty" yaml:"chat_skill_template,omitempty"`
	RemoteDesktopEnabled        bool           `json:"remoteDesktopEnabled,omitempty" yaml:"remote_desktop_enabled,omitempty"`
	RemoteDesktopControlEnabled bool           `json:"remoteDesktopControlEnabled,omitempty" yaml:"remote_desktop_control_enabled,omitempty"`
	UpdatedAt                   string         `json:"updatedAt,omitempty" yaml:"updated_at,omitempty"`
}

type Schedule struct {
	ID              string            `json:"id" yaml:"id"`
	ProjectID       string            `json:"projectId" yaml:"project_id"`
	BoardID         string            `json:"boardId" yaml:"board_id"`
	Name            string            `json:"name" yaml:"name"`
	Description     string            `json:"description,omitempty" yaml:"description,omitempty"`
	Cron            string            `json:"cron" yaml:"cron"`
	Timezone        string            `json:"timezone" yaml:"timezone"`
	Enabled         bool              `json:"enabled" yaml:"enabled"`
	Action          string            `json:"action" yaml:"action"`
	TitleTemplate   string            `json:"titleTemplate" yaml:"title_template"`
	PromptTemplate  string            `json:"promptTemplate" yaml:"-"`
	Provider        string            `json:"provider" yaml:"provider"`
	Model           string            `json:"model" yaml:"model"`
	Effort          string            `json:"effort,omitempty" yaml:"effort,omitempty"`
	ProviderOptions map[string]string `json:"providerOptions,omitempty" yaml:"provider_options,omitempty"`
	LabelIDs        []string          `json:"labelIds,omitempty" yaml:"labels,omitempty"`
	OpenCardPolicy  string            `json:"openCardPolicy" yaml:"open_card_policy"`
	MisfirePolicy   string            `json:"misfirePolicy" yaml:"misfire_policy"`
	BusyPolicy      string            `json:"busyPolicy" yaml:"busy_policy"`
	NextRunAt       string            `json:"nextRunAt,omitempty" yaml:"next_run_at,omitempty"`
	LastRunAt       string            `json:"lastRunAt,omitempty" yaml:"last_run_at,omitempty"`
	CreatedAt       string            `json:"createdAt" yaml:"created_at"`
	UpdatedAt       string            `json:"updatedAt" yaml:"updated_at"`
	NextRuns        []string          `json:"nextRuns,omitempty" yaml:"-"`
}

type ScheduleRun struct {
	ID           string `json:"id" yaml:"id"`
	ScheduleID   string `json:"scheduleId" yaml:"schedule_id"`
	ProjectID    string `json:"projectId" yaml:"project_id"`
	BoardID      string `json:"boardId" yaml:"board_id"`
	CardID       string `json:"cardId,omitempty" yaml:"card_id,omitempty"`
	ScheduledFor string `json:"scheduledFor" yaml:"scheduled_for"`
	Manual       bool   `json:"manual,omitempty" yaml:"manual,omitempty"`
	Action       string `json:"action" yaml:"action"`
	Status       string `json:"status" yaml:"status"`
	Attempt      int    `json:"attempt" yaml:"attempt"`
	Message      string `json:"message,omitempty" yaml:"-"`
	CreatedAt    string `json:"createdAt" yaml:"created_at"`
	UpdatedAt    string `json:"updatedAt" yaml:"updated_at"`
	StartedAt    string `json:"startedAt,omitempty" yaml:"started_at,omitempty"`
	FinishedAt   string `json:"finishedAt,omitempty" yaml:"finished_at,omitempty"`
}

type Author struct {
	Kind      string `json:"kind" yaml:"kind"`
	Name      string `json:"name,omitempty" yaml:"name,omitempty"`
	ProjectID string `json:"projectId,omitempty" yaml:"project_id,omitempty"`
	CardID    string `json:"cardId,omitempty" yaml:"card_id,omitempty"`
	Provider  string `json:"provider,omitempty" yaml:"provider,omitempty"`
	Model     string `json:"model,omitempty" yaml:"model,omitempty"`
}

// Conversation is Dieter's durable projection of one harness session. The
// opaque Session value is produced by AI SDK HarnessAgent.stop and is passed
// back untouched on the next turn.
type Conversation struct {
	ProjectionVersion int         `json:"projectionVersion"`
	CardID            string      `json:"cardId"`
	Status            string      `json:"status"`
	Messages          []UIMessage `json:"messages"`
	// ForkSeed is the immutable source transcript used to seed the first turn
	// of a forked chat. It is cleared as soon as the new harness session emits
	// resumable state; copied Messages remain the user-visible history.
	ForkSeed         []UIMessage       `json:"forkSeed,omitempty"`
	DraftAttachments []UIMessagePart   `json:"draftAttachments,omitempty"`
	PendingTools     []PendingTool     `json:"pendingTools,omitempty"`
	Subagents        []Subagent        `json:"subagents,omitempty"`
	TaskPlans        []TaskPlan        `json:"taskPlans,omitempty"`
	Queue            []QueuedMessage   `json:"queue,omitempty"`
	Session          json.RawMessage   `json:"session,omitempty"`
	ActiveTurn       *ConversationTurn `json:"activeTurn,omitempty"`
	LastSeq          int64             `json:"lastSeq"`
	UpdatedAt        string            `json:"updatedAt"`
}

// ConversationTurn identifies the one in-flight response. Persisting the
// response ID lets a restarted Dieter process continue streaming into the same
// assistant message instead of creating a duplicate.
type ConversationTurn struct {
	ID                string   `json:"id"`
	UserMessageID     string   `json:"userMessageId"`
	ResponseMessageID string   `json:"responseMessageId"`
	Instructions      string   `json:"instructions,omitempty"`
	InstructionSource string   `json:"instructionSource,omitempty"`
	InstructionLabels []string `json:"instructionLabels,omitempty"`
}

// TaskPlan is the provider-neutral latest progress snapshot for one assistant
// response. Capability events replace a snapshot without rewriting history.
type TaskPlan struct {
	ID          string          `json:"id"`
	Provider    string          `json:"provider"`
	MessageID   string          `json:"messageId"`
	Revision    int64           `json:"revision"`
	State       string          `json:"state"`
	Explanation string          `json:"explanation,omitempty"`
	Source      string          `json:"source,omitempty"`
	Phases      []TaskPlanPhase `json:"phases"`
	UpdatedAt   string          `json:"updatedAt,omitempty"`
}

type TaskPlanPhase struct {
	Name  string         `json:"name,omitempty"`
	Tasks []TaskPlanItem `json:"tasks"`
}

type TaskPlanItem struct {
	ID         string `json:"id,omitempty"`
	Content    string `json:"content"`
	ActiveForm string `json:"activeForm,omitempty"`
	Status     string `json:"status"`
	Blocker    string `json:"blocker,omitempty"`
	Priority   string `json:"priority,omitempty"`
	Order      int64  `json:"order,omitempty"`
}

// Subagent is the provider-neutral projection of one delegated agent. Harness
// adapters fill the fields they can observe; the UI never needs provider-
// specific event shapes.
type Subagent struct {
	ID                  string   `json:"id"`
	Provider            string   `json:"provider"`
	MessageID           string   `json:"messageId"`
	ParentToolCallID    string   `json:"parentToolCallId,omitempty"`
	Name                string   `json:"name,omitempty"`
	AgentType           string   `json:"agentType,omitempty"`
	AgentSource         string   `json:"agentSource,omitempty"`
	Description         string   `json:"description,omitempty"`
	Task                string   `json:"task,omitempty"`
	Assignment          string   `json:"assignment,omitempty"`
	Status              string   `json:"status"`
	Model               string   `json:"model,omitempty"`
	Activity            string   `json:"activity,omitempty"`
	CurrentTool         string   `json:"currentTool,omitempty"`
	CurrentToolArgs     string   `json:"currentToolArgs,omitempty"`
	ToolCount           int64    `json:"toolCount,omitempty"`
	Requests            int64    `json:"requests,omitempty"`
	Tokens              int64    `json:"tokens,omitempty"`
	ContextTokens       int64    `json:"contextTokens,omitempty"`
	ContextWindow       int64    `json:"contextWindow,omitempty"`
	Cost                float64  `json:"cost,omitempty"`
	DurationMS          int64    `json:"durationMs,omitempty"`
	RecentOutput        []string `json:"recentOutput,omitempty"`
	Retry               string   `json:"retry,omitempty"`
	Error               string   `json:"error,omitempty"`
	Detached            bool     `json:"detached,omitempty"`
	TranscriptAvailable bool     `json:"transcriptAvailable,omitempty"`
	StartedAt           string   `json:"startedAt,omitempty"`
	UpdatedAt           string   `json:"updatedAt,omitempty"`
	EndedAt             string   `json:"endedAt,omitempty"`
}

type UIMessage struct {
	ID       string          `json:"id"`
	Role     string          `json:"role"`
	Metadata json.RawMessage `json:"metadata,omitempty"`
	Parts    []UIMessagePart `json:"parts"`
}

// UnmarshalJSON migrates the pre-0.3 message timestamp into AI SDK message
// metadata. UIMessage is a wire protocol type, so application fields must not
// be added at its top level.
func (message *UIMessage) UnmarshalJSON(data []byte) error {
	var wire struct {
		ID              string          `json:"id"`
		Role            string          `json:"role"`
		Metadata        json.RawMessage `json:"metadata"`
		Parts           []UIMessagePart `json:"parts"`
		LegacyCreatedAt string          `json:"createdAt"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	metadata := append(json.RawMessage(nil), wire.Metadata...)
	if (len(metadata) == 0 || string(metadata) == "null") && wire.LegacyCreatedAt != "" {
		metadata, _ = json.Marshal(map[string]string{"createdAt": wire.LegacyCreatedAt})
	}
	*message = UIMessage{ID: wire.ID, Role: wire.Role, Metadata: metadata, Parts: wire.Parts}
	return nil
}

type UIMessagePart struct {
	Type       string          `json:"type"`
	Text       string          `json:"text,omitempty"`
	MediaType  string          `json:"mediaType,omitempty"`
	Filename   string          `json:"filename,omitempty"`
	URL        string          `json:"url,omitempty"`
	State      string          `json:"state,omitempty"`
	ToolCallID string          `json:"toolCallId,omitempty"`
	ToolName   string          `json:"toolName,omitempty"`
	Input      json.RawMessage `json:"input,omitempty"`
	Output     json.RawMessage `json:"output,omitempty"`
	ErrorText  string          `json:"errorText,omitempty"`
}

type PendingTool struct {
	ID, ToolCallID, ToolName string
	Input                    json.RawMessage
}

type QueuedMessage struct {
	ID        string          `json:"id"`
	Text      string          `json:"text"`
	Parts     []UIMessagePart `json:"parts,omitempty"`
	CreatedAt string          `json:"createdAt"`
}

type ConversationEvent struct {
	Seq       int64           `json:"seq"`
	Type      string          `json:"type"`
	TurnID    string          `json:"turnId,omitempty"`
	MessageID string          `json:"messageId,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	CreatedAt string          `json:"createdAt"`
}

type Comment struct {
	ID        string `json:"id" yaml:"id"`
	CardID    string `json:"cardId" yaml:"card_id"`
	Author    Author `json:"author" yaml:"author"`
	Body      string `json:"body" yaml:"-"`
	CreatedAt string `json:"createdAt" yaml:"created_at"`
}

type CardDetail struct {
	Card     Card      `json:"card"`
	Project  Project   `json:"project"`
	Board    Board     `json:"board"`
	Comments []Comment `json:"comments"`
}

type State struct {
	StorePath string    `json:"storePath"`
	Projects  []Project `json:"projects"`
	Project   *Project  `json:"project,omitempty"`
	Boards    []Board   `json:"boards"`
	Cards     []Card    `json:"cards"`
	Chats     []Card    `json:"chats"`
}
