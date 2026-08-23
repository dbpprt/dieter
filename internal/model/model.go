package model

import "encoding/json"

const (
	ConversationScopeBoard = "board"
	ConversationScopeChat  = "chat"

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
	ID             string `json:"id" yaml:"id"`
	Name           string `json:"name" yaml:"name"`
	Path           string `json:"path" yaml:"path"`
	Summary        string `json:"summary,omitempty" yaml:"summary,omitempty"`
	Prompt         string `json:"prompt" yaml:"-"`
	PromptTemplate string `json:"promptTemplate,omitempty" yaml:"prompt_template,omitempty"`
	Archived       bool   `json:"archived,omitempty" yaml:"archived,omitempty"`
	CreatedAt      string `json:"createdAt" yaml:"created_at"`
	UpdatedAt      string `json:"updatedAt" yaml:"updated_at"`
	BoardCount     int    `json:"boardCount,omitempty" yaml:"-"`
	CardCount      int    `json:"cardCount,omitempty" yaml:"-"`
	ChatCount      int    `json:"chatCount,omitempty" yaml:"-"`
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
	ID                  string            `json:"id" yaml:"id"`
	Scope               string            `json:"scope" yaml:"scope,omitempty"`
	ProjectID           string            `json:"projectId" yaml:"project_id"`
	BoardID             string            `json:"boardId" yaml:"board_id"`
	Lane                string            `json:"lane" yaml:"lane"`
	Position            int64             `json:"position" yaml:"position"`
	Title               string            `json:"title" yaml:"title"`
	InitialPrompt       string            `json:"initialPrompt" yaml:"-"`
	InitialPromptSentAt string            `json:"initialPromptSentAt,omitempty" yaml:"initial_prompt_sent_at,omitempty"`
	PhaseChangedAt      string            `json:"phaseChangedAt" yaml:"phase_changed_at"`
	Provider            string            `json:"provider,omitempty" yaml:"provider_cache,omitempty"`
	Model               string            `json:"model,omitempty" yaml:"model_cache,omitempty"`
	Effort              string            `json:"effort,omitempty" yaml:"effort_cache,omitempty"`
	ProviderOptions     map[string]string `json:"providerOptions,omitempty" yaml:"provider_options_cache,omitempty"`
	Runtime             string            `json:"runtime" yaml:"runtime_cache,omitempty"`
	Summary             string            `json:"summary,omitempty" yaml:"summary_cache,omitempty"`
	RuntimeUpdatedAt    string            `json:"runtimeUpdatedAt,omitempty" yaml:"runtime_updated_at,omitempty"`
	LastActivityAt      string            `json:"lastActivityAt,omitempty" yaml:"last_activity_at,omitempty"`
	Archived            bool              `json:"archived,omitempty" yaml:"archived,omitempty"`
	DoneArchiveExempt   bool              `json:"doneArchiveExempt,omitempty" yaml:"done_archive_exempt,omitempty"`
	Pinned              bool              `json:"pinned,omitempty" yaml:"pinned,omitempty"`
	CreatedAt           string            `json:"createdAt" yaml:"created_at"`
	UpdatedAt           string            `json:"updatedAt" yaml:"updated_at"`
	LabelIDs            []string          `json:"labelIds,omitempty" yaml:"labels,omitempty"`
	Origin              *CardOrigin       `json:"origin,omitempty" yaml:"origin,omitempty"`
	CommentCount        int               `json:"commentCount" yaml:"-"`
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
	GlobalParallelLimit int            `json:"globalParallelLimit" yaml:"global_parallel_limit"`
	AgentParallelLimits map[string]int `json:"agentParallelLimits,omitempty" yaml:"agent_parallel_limits,omitempty"`
	BoardParallelLimits map[string]int `json:"boardParallelLimits,omitempty" yaml:"board_parallel_limits,omitempty"`
	PromptTemplate      string         `json:"promptTemplate,omitempty" yaml:"prompt_template,omitempty"`
	BoardSkillTemplate  string         `json:"boardSkillTemplate,omitempty" yaml:"board_skill_template,omitempty"`
	ChatSkillTemplate   string         `json:"chatSkillTemplate,omitempty" yaml:"chat_skill_template,omitempty"`
	UpdatedAt           string         `json:"updatedAt,omitempty" yaml:"updated_at,omitempty"`
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
	ProjectionVersion int               `json:"projectionVersion"`
	CardID            string            `json:"cardId"`
	Status            string            `json:"status"`
	Messages          []UIMessage       `json:"messages"`
	DraftAttachments  []UIMessagePart   `json:"draftAttachments,omitempty"`
	PendingTools      []PendingTool     `json:"pendingTools,omitempty"`
	Subagents         []Subagent        `json:"subagents,omitempty"`
	TaskPlans         []TaskPlan        `json:"taskPlans,omitempty"`
	Queue             []QueuedMessage   `json:"queue,omitempty"`
	Session           json.RawMessage   `json:"session,omitempty"`
	ActiveTurn        *ConversationTurn `json:"activeTurn,omitempty"`
	LastSeq           int64             `json:"lastSeq"`
	UpdatedAt         string            `json:"updatedAt"`
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
