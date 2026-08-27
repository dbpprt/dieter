package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
)

func protoState(value model.State) *dieterv1.State {
	result := &dieterv1.State{StorePath: value.StorePath}
	for _, item := range value.Projects {
		result.Projects = append(result.Projects, protoProject(item))
	}
	if value.Project != nil {
		result.Project = protoProject(*value.Project)
	}
	for _, item := range value.Boards {
		result.Boards = append(result.Boards, protoBoard(item))
	}
	for _, item := range value.Cards {
		result.Cards = append(result.Cards, protoCard(item))
	}
	for _, item := range value.Chats {
		result.Chats = append(result.Chats, protoCard(item))
	}
	return result
}

func protoProject(value model.Project) *dieterv1.Project {
	result := &dieterv1.Project{
		Id: value.ID, Name: value.Name, Path: value.Path, Summary: value.Summary,
		Prompt: value.Prompt, Archived: value.Archived, CreatedAt: value.CreatedAt,
		UpdatedAt: value.UpdatedAt, BoardCount: int32(value.BoardCount),
		CardCount: int32(value.CardCount), ChatCount: int32(value.ChatCount), PromptTemplate: value.PromptTemplate,
		DefaultWorkspaceMode: value.DefaultWorkspaceMode, BaseRemote: value.BaseRemote, BaseBranch: value.BaseBranch,
	}
	for _, command := range value.ValidationCommands {
		result.ValidationCommands = append(result.ValidationCommands, protoValidationCommand(command))
	}
	return result
}

func protoValidationCommand(value model.ValidationCommand) *dieterv1.ValidationCommand {
	return &dieterv1.ValidationCommand{
		Name: value.Name, Executable: value.Executable, Arguments: append([]string(nil), value.Arguments...),
		WorkingDirectory: value.WorkingDirectory, Environment: cloneProtoStringMap(value.Environment), TimeoutSeconds: int32(value.TimeoutSeconds),
	}
}

func modelValidationCommands(values []*dieterv1.ValidationCommand) []model.ValidationCommand {
	result := make([]model.ValidationCommand, 0, len(values))
	for _, value := range values {
		if value == nil {
			continue
		}
		result = append(result, model.ValidationCommand{
			Name: value.GetName(), Executable: value.GetExecutable(), Arguments: append([]string(nil), value.GetArguments()...),
			WorkingDirectory: value.GetWorkingDirectory(), Environment: cloneProtoStringMap(value.GetEnvironment()), TimeoutSeconds: int(value.GetTimeoutSeconds()),
		})
	}
	return result
}

func protoBoard(value model.Board) *dieterv1.Board {
	result := &dieterv1.Board{
		Id: value.ID, ProjectId: value.ProjectID, Name: value.Name,
		Workflow: value.Workflow, Description: value.Description,
		DoneArchivePolicy: value.DoneArchivePolicy, CreatedAt: value.CreatedAt,
		UpdatedAt: value.UpdatedAt, PromptTemplate: value.PromptTemplate,
	}
	for _, item := range value.Labels {
		result.Labels = append(result.Labels, &dieterv1.Label{Id: item.ID, Name: item.Name, Color: item.Color, Instructions: item.Instructions})
	}
	for _, item := range value.Lanes {
		result.Lanes = append(result.Lanes, &dieterv1.Lane{Id: item.ID, Name: item.Name})
	}
	return result
}

func protoCard(value model.Card) *dieterv1.Card {
	result := &dieterv1.Card{
		Id: value.ID, Scope: value.Scope, ProjectId: value.ProjectID,
		BoardId: value.BoardID, Lane: value.Lane, Position: value.Position,
		Title: value.Title, InitialPrompt: value.InitialPrompt,
		InitialPromptSentAt: value.InitialPromptSentAt, PhaseChangedAt: value.PhaseChangedAt,
		Provider: value.Provider, Model: value.Model, Effort: value.Effort,
		ProviderOptions: cloneProtoStringMap(value.ProviderOptions),
		Runtime:         value.Runtime, Summary: value.Summary,
		RuntimeUpdatedAt: value.RuntimeUpdatedAt, LastActivityAt: value.LastActivityAt,
		Archived: value.Archived, DoneArchiveExempt: value.DoneArchiveExempt,
		Pinned: value.Pinned, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt,
		LabelIds: append([]string(nil), value.LabelIDs...), CommentCount: int32(value.CommentCount),
		WorkspaceMode: value.WorkspaceMode, WorkspaceBranch: value.WorkspaceBranch, WorkspaceBaseBranch: value.WorkspaceBaseBranch,
	}
	if value.Workspace != nil {
		result.Workspace = protoWorkspaceSummary(*value.Workspace)
	}
	if value.PullRequest != nil {
		result.PullRequest = protoPullRequestSummary(*value.PullRequest)
	}
	if value.Origin != nil {
		result.Origin = &dieterv1.CardOrigin{
			Kind: value.Origin.Kind, ScheduleId: value.Origin.ScheduleID,
			ScheduleRunId: value.Origin.ScheduleRunID, ScheduledFor: value.Origin.ScheduledFor,
		}
	}
	return result
}

func protoWorkspaceSummary(value model.WorkspaceSummary) *dieterv1.WorkspaceSummary {
	return &dieterv1.WorkspaceSummary{
		Mode: value.Mode, State: value.State, Branch: value.Branch, BaseBranch: value.BaseBranch,
		HeadSha: value.HeadSHA, BaseSha: value.BaseSHA, Revision: value.Revision,
		ChangedFiles: int32(value.ChangedFiles), Additions: int32(value.Additions), Deletions: int32(value.Deletions),
		Ahead: int32(value.Ahead), Behind: int32(value.Behind), CurrentOperationId: value.CurrentOperationID,
	}
}

func protoPullRequestSummary(value model.PullRequestSummary) *dieterv1.PullRequestSummary {
	return &dieterv1.PullRequestSummary{
		Provider: value.Provider, Number: int32(value.Number), Url: value.URL, State: value.State,
		Draft: value.Draft, Mergeable: value.Mergeable, ReviewDecision: value.ReviewDecision,
		ChecksState: value.ChecksState, HeadSha: value.HeadSHA, BaseSha: value.BaseSHA, LastSyncedAt: value.UpdatedAt,
	}
}

func protoWorkspace(value model.Workspace) *dieterv1.Workspace {
	return &dieterv1.Workspace{
		CardId: value.CardID, ProjectId: value.ProjectID, Mode: value.Mode, Path: value.Path,
		BaseRemote: value.BaseRemote, BaseBranch: value.BaseBranch, BaseSha: value.BaseSHA,
		CurrentBaseSha: value.CurrentBaseSHA, Branch: value.Branch, HeadSha: value.HeadSHA,
		UpstreamRef: value.UpstreamRef, ManagedBranch: value.ManagedBranch, LegacyUnmanaged: value.LegacyUnmanaged,
		State: value.State, Revision: value.Revision, CurrentOperationId: value.CurrentOperationID,
		PreviousCardIds: append([]string(nil), value.PreviousCardIDs...), ChangedFiles: int32(value.ChangedFiles),
		Additions: int32(value.Additions), Deletions: int32(value.Deletions), Ahead: int32(value.Ahead),
		Behind: int32(value.Behind), SizeBytes: value.SizeBytes, CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt,
		IntegratedHeadSha: value.IntegratedHeadSHA, IntegratedResultSha: value.IntegratedResultSHA,
		IntegrationStrategy: value.IntegrationStrategy, IntegratedAt: value.IntegratedAt,
	}
}

func protoChangeset(value model.Changeset) *dieterv1.Changeset {
	result := &dieterv1.Changeset{
		CardId: value.CardID, Revision: value.Revision, ComparisonSha: value.MergeBaseSHA,
		HeadSha: value.HeadSHA, BaseSha: value.CurrentBaseSHA, Additions: int32(value.Additions),
		Deletions: int32(value.Deletions), Volatile: value.Volatile, GeneratedAt: value.CreatedAt,
	}
	for _, file := range value.Files {
		result.Files = append(result.Files, &dieterv1.ChangedFile{
			Path: file.Path, OldPath: file.PreviousPath, Status: file.Status, Additions: int32(file.Additions),
			Deletions: int32(file.Deletions), Binary: file.Binary, Untracked: file.Status == "untracked", Conflicted: file.Conflicted,
		})
	}
	for _, commit := range value.Commits {
		result.Commits = append(result.Commits, &dieterv1.WorkspaceCommit{
			Sha: commit.SHA, ShortSha: shortProtoSHA(commit.SHA), Subject: commit.Subject, AuthorName: commit.Author,
			AuthoredAt: commit.AuthoredAt, Additions: int32(commit.Additions), Deletions: int32(commit.Deletions), ChangedFiles: int32(commit.Files),
		})
	}
	return result
}

func shortProtoSHA(value string) string {
	if len(value) > 12 {
		return value[:12]
	}
	return value
}

func protoFileDiff(value model.FileDiff) *dieterv1.FileDiff {
	return &dieterv1.FileDiff{
		CardId: value.CardID, Path: value.Path, CommitSha: value.CommitSHA, Revision: value.Revision, Patch: value.Patch,
		Binary: value.Binary, Truncated: value.Truncated, NextOffset: int64(value.NextOffset), TotalBytes: int64(value.TotalBytes),
	}
}

func protoChangeComment(value model.ChangeComment) *dieterv1.ChangeComment {
	return &dieterv1.ChangeComment{
		Id: value.ID, CardId: value.CardID, Path: value.Path, Side: value.Side, Line: int32(value.Line),
		Body: value.Body, Author: value.Author.Name, Revision: value.ChangesetRevision, CreatedAt: value.CreatedAt,
	}
}

func protoSCMCapabilities(value model.SCMCapabilities) *dieterv1.SCMCapabilities {
	return &dieterv1.SCMCapabilities{
		Provider: value.Provider, Remote: value.Remote, Host: value.Host, Owner: value.Owner, Repository: value.Repository,
		RemoteAvailable: value.RemoteAvailable, PushAvailable: value.PushAvailable,
		ProviderApiAvailable: value.ProviderAPIAvailable, Authenticated: value.Authenticated, UnavailableReason: value.UnavailableReason,
	}
}

func protoGitOperation(value model.GitOperation) *dieterv1.GitOperation {
	result := &dieterv1.GitOperation{
		Id: value.ID, CardId: value.CardID, ProjectId: value.ProjectID, Kind: value.Kind, Status: value.Status,
		ExpectedRevision: value.ExpectedRevision, ExpectedBaseSha: value.ExpectedBaseSHA, ExpectedHeadSha: value.ExpectedHeadSHA,
		Parameters: cloneProtoStringMap(value.Parameters), CompletedSteps: append([]string(nil), value.CompletedSteps...),
		Result: value.Result, Error: value.Error, Sequence: value.Sequence, CreatedAt: value.CreatedAt,
		StartedAt: value.StartedAt, FinishedAt: value.FinishedAt, UpdatedAt: value.UpdatedAt,
	}
	for _, conflict := range value.Conflicts {
		result.Conflicts = append(result.Conflicts, &dieterv1.GitConflict{Path: conflict.Path, HunkCount: int32(conflict.HunkCount)})
	}
	for _, validation := range value.ValidationResults {
		result.ValidationResults = append(result.ValidationResults, &dieterv1.ValidationResult{
			Name: validation.Name, ExitCode: int32(validation.ExitCode), Output: validation.Output,
			Truncated: validation.Truncated, DurationMs: validation.DurationMS,
		})
	}
	return result
}

func protoCardDetail(value model.CardDetail) *dieterv1.CardDetail {
	result := &dieterv1.CardDetail{
		Card: protoCard(value.Card), Project: protoProject(value.Project), Board: protoBoard(value.Board),
	}
	for _, item := range value.Comments {
		result.Comments = append(result.Comments, protoComment(item))
	}
	return result
}

func protoComment(value model.Comment) *dieterv1.Comment {
	return &dieterv1.Comment{
		Id: value.ID, CardId: value.CardID, Author: &dieterv1.Author{
			Kind: value.Author.Kind, Name: value.Author.Name, ProjectId: value.Author.ProjectID,
			CardId: value.Author.CardID, Provider: value.Author.Provider, Model: value.Author.Model,
		}, Body: value.Body, CreatedAt: value.CreatedAt,
	}
}

func protoConversation(value model.Conversation) *dieterv1.Conversation {
	result := &dieterv1.Conversation{
		ProjectionVersion: int32(value.ProjectionVersion), CardId: value.CardID,
		Status: value.Status, LastSeq: value.LastSeq, UpdatedAt: value.UpdatedAt,
	}
	for _, item := range value.Messages {
		message := &dieterv1.UiMessage{Id: item.ID, Role: item.Role, MetadataJson: append([]byte(nil), item.Metadata...)}
		for _, part := range item.Parts {
			message.Parts = append(message.Parts, protoMessagePart(part))
		}
		result.Messages = append(result.Messages, message)
	}
	for _, item := range value.DraftAttachments {
		result.DraftAttachments = append(result.DraftAttachments, protoMessagePart(item))
	}
	for _, item := range value.PendingTools {
		preview, hasInput, inputSize := payloadSummary(item.Input)
		revision := toolPayloadRevision(model.UIMessagePart{Input: item.Input})
		result.PendingTools = append(result.PendingTools, &dieterv1.PendingTool{
			Id: item.ID, ToolCallId: item.ToolCallID, ToolName: item.ToolName,
			HasInput: hasInput, InputSize: inputSize, InputPreview: preview, PayloadRevision: revision,
		})
	}
	for _, item := range value.Subagents {
		result.Subagents = append(result.Subagents, protoSubagent(item))
	}
	for _, item := range value.TaskPlans {
		result.TaskPlans = append(result.TaskPlans, protoTaskPlan(item))
	}
	for _, item := range value.Queue {
		queued := &dieterv1.QueuedMessage{Id: item.ID, Text: item.Text, CreatedAt: item.CreatedAt}
		for _, part := range item.Parts {
			queued.Parts = append(queued.Parts, protoMessagePart(part))
		}
		result.Queue = append(result.Queue, queued)
	}
	return result
}

func protoTaskPlan(value model.TaskPlan) *dieterv1.TaskPlan {
	result := &dieterv1.TaskPlan{
		Id: value.ID, Provider: value.Provider, MessageId: value.MessageID,
		Revision: value.Revision, State: value.State, Explanation: value.Explanation,
		Source: value.Source, UpdatedAt: value.UpdatedAt,
	}
	for _, phase := range value.Phases {
		protoPhase := &dieterv1.TaskPlanPhase{Name: phase.Name}
		for _, task := range phase.Tasks {
			protoPhase.Tasks = append(protoPhase.Tasks, &dieterv1.TaskPlanItem{
				Id: task.ID, Content: task.Content, ActiveForm: task.ActiveForm,
				Status: task.Status, Blocker: task.Blocker, Priority: task.Priority,
				Order: task.Order,
			})
		}
		result.Phases = append(result.Phases, protoPhase)
	}
	return result
}

func protoSubagent(value model.Subagent) *dieterv1.Subagent {
	return &dieterv1.Subagent{
		Id: value.ID, Provider: value.Provider, MessageId: value.MessageID,
		ParentToolCallId: value.ParentToolCallID, Name: value.Name, AgentType: value.AgentType,
		AgentSource: value.AgentSource, Description: value.Description, Task: value.Task,
		Assignment: value.Assignment, Status: value.Status, Model: value.Model,
		Activity: value.Activity, CurrentTool: value.CurrentTool, CurrentToolArgs: value.CurrentToolArgs,
		ToolCount: value.ToolCount, Requests: value.Requests, Tokens: value.Tokens,
		ContextTokens: value.ContextTokens, ContextWindow: value.ContextWindow, Cost: value.Cost,
		DurationMs: value.DurationMS, RecentOutput: append([]string(nil), value.RecentOutput...),
		Retry: value.Retry, Error: value.Error, Detached: value.Detached,
		TranscriptAvailable: value.TranscriptAvailable, StartedAt: value.StartedAt,
		UpdatedAt: value.UpdatedAt, EndedAt: value.EndedAt,
	}
}

func protoMessagePart(value model.UIMessagePart) *dieterv1.MessagePart {
	inputPreview, hasInput, inputSize := payloadSummary(value.Input)
	outputPreview, hasOutput, outputSize := payloadSummary(value.Output)
	result := &dieterv1.MessagePart{
		Type: value.Type, Text: value.Text, MediaType: value.MediaType,
		Filename: value.Filename, Url: value.URL, State: value.State,
		ToolCallId: value.ToolCallID, ToolName: value.ToolName,
		ErrorText: value.ErrorText, HasInput: hasInput, HasOutput: hasOutput,
		InputSize: inputSize, OutputSize: outputSize, InputPreview: inputPreview,
		OutputPreview: outputPreview, PayloadRevision: toolPayloadRevision(value),
	}
	if value.Type == "file" {
		prefix := "data:" + value.MediaType + ";base64,"
		if encoded, found := strings.CutPrefix(value.URL, prefix); found {
			if data, err := base64.StdEncoding.DecodeString(encoded); err == nil {
				result.Url = ""
				result.Data = data
			}
		}
	}
	return result
}

func payloadSummary(raw json.RawMessage) (string, bool, int64) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return "", false, 0
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(trimmed))
	decoder.UseNumber()
	if decoder.Decode(&value) != nil {
		return truncatePreview(string(trimmed), 160), true, int64(len(raw))
	}
	if object, ok := value.(map[string]any); ok {
		for _, key := range []string{"command", "path", "file_path", "query", "url"} {
			if preferred, exists := object[key]; exists {
				value = preferred
				break
			}
		}
	}
	text, ok := value.(string)
	if !ok {
		encoded, err := json.Marshal(value)
		if err != nil {
			encoded = trimmed
		}
		text = string(encoded)
	}
	return truncatePreview(text, 160), true, int64(len(raw))
}

func truncatePreview(value string, limit int) string {
	value = strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:limit-1]) + "…"
}

func toolPayloadRevision(value model.UIMessagePart) string {
	if len(value.Input) == 0 && len(value.Output) == 0 && value.ErrorText == "" {
		return ""
	}
	hash := sha256.New()
	_, _ = hash.Write(value.Input)
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write(value.Output)
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write([]byte(value.ErrorText))
	return fmt.Sprintf("%x", hash.Sum(nil)[:12])
}

type grpcUserMessagePart struct{ Type, Text, MediaType, Filename, URL string }

func modelUserMessageParts(values []*dieterv1.MessagePart) ([]model.UIMessagePart, error) {
	wire := make([]grpcUserMessagePart, 0, len(values))
	for _, value := range values {
		if value == nil {
			continue
		}
		url := value.GetUrl()
		if len(value.GetData()) > 0 {
			url = "data:" + value.GetMediaType() + ";base64," + base64.StdEncoding.EncodeToString(value.GetData())
		}
		wire = append(wire, grpcUserMessagePart{
			Type: value.GetType(), Text: value.GetText(), MediaType: value.GetMediaType(),
			Filename: value.GetFilename(), URL: url,
		})
	}
	return validateUserMessageParts(wire)
}

func modelUserAttachmentParts(values []*dieterv1.MessagePart) ([]model.UIMessagePart, error) {
	if len(values) == 0 {
		return nil, nil
	}
	parts, err := modelUserMessageParts(values)
	if err != nil {
		return nil, err
	}
	for _, part := range parts {
		if part.Type != "file" {
			return nil, fmt.Errorf("card attachments must be images or files")
		}
	}
	return parts, nil
}

func protoHarnessCatalog(values []harness.Adapter) *dieterv1.HarnessCatalog {
	result := &dieterv1.HarnessCatalog{}
	for _, value := range values {
		item := &dieterv1.Harness{Id: value.ID, Name: value.Name, DefaultModel: value.DefaultModel}
		for _, capability := range value.Capabilities {
			item.Capabilities = append(item.Capabilities, &dieterv1.HarnessCapability{Id: capability.ID, Level: capability.Level})
		}
		for _, option := range value.Options {
			wireOption := &dieterv1.ProviderOption{Id: option.ID, Name: option.Name, Description: option.Description, Type: option.Type, DefaultValue: option.Default}
			for _, choice := range option.Choices {
				wireOption.Choices = append(wireOption.Choices, &dieterv1.ProviderOptionChoice{Value: choice.Value, Name: choice.Name})
			}
			item.Options = append(item.Options, wireOption)
		}
		for _, model := range value.Models {
			if model.Hidden {
				continue
			}
			item.Models = append(item.Models, &dieterv1.HarnessModel{
				Id: model.ID, Name: model.Name, ContextWindow: int32(model.ContextWindow),
				DefaultEffort: model.DefaultEffort, Efforts: dedupeEfforts(model.Efforts),
			})
		}
		if value.Effort != nil {
			item.Effort = &dieterv1.EffortConfig{Label: value.Effort.Label}
			for _, option := range value.Effort.Options {
				item.Effort.Options = append(item.Effort.Options, &dieterv1.EffortOption{Id: option.ID, Name: option.Name})
			}
		}
		result.Harnesses = append(result.Harnesses, item)
	}
	return result
}

// Discovered catalogs bypass the YAML loader's uniqueness validation; clients
// render effort lists with identity-keyed controls that reject duplicates.
func dedupeEfforts(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func protoSchedule(value model.Schedule) *dieterv1.Schedule {
	return &dieterv1.Schedule{
		Id: value.ID, ProjectId: value.ProjectID, BoardId: value.BoardID,
		Name: value.Name, Description: value.Description, Cron: value.Cron,
		Timezone: value.Timezone, Enabled: value.Enabled, Action: value.Action,
		TitleTemplate: value.TitleTemplate, PromptTemplate: value.PromptTemplate,
		Provider: value.Provider, Model: value.Model, Effort: value.Effort,
		ProviderOptions: cloneProtoStringMap(value.ProviderOptions),
		LabelIds:        append([]string(nil), value.LabelIDs...), OpenCardPolicy: value.OpenCardPolicy,
		MisfirePolicy: value.MisfirePolicy, BusyPolicy: value.BusyPolicy,
		NextRunAt: value.NextRunAt, LastRunAt: value.LastRunAt,
		CreatedAt: value.CreatedAt, UpdatedAt: value.UpdatedAt,
		NextRuns: append([]string(nil), value.NextRuns...),
	}
}

func protoScheduleRun(value model.ScheduleRun) *dieterv1.ScheduleRun {
	return &dieterv1.ScheduleRun{
		Id: value.ID, ScheduleId: value.ScheduleID, ProjectId: value.ProjectID,
		BoardId: value.BoardID, CardId: value.CardID, ScheduledFor: value.ScheduledFor,
		Manual: value.Manual, Action: value.Action, Status: value.Status,
		Attempt: int32(value.Attempt), Message: value.Message, CreatedAt: value.CreatedAt,
		UpdatedAt: value.UpdatedAt, StartedAt: value.StartedAt, FinishedAt: value.FinishedAt,
	}
}
