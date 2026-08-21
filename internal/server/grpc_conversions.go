package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/harness"
	"github.com/dbpprt/nauclio/internal/model"
)

func protoState(value model.State) *naucliov1.State {
	result := &naucliov1.State{StorePath: value.StorePath}
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

func protoProject(value model.Project) *naucliov1.Project {
	return &naucliov1.Project{
		Id: value.ID, Name: value.Name, Path: value.Path, Summary: value.Summary,
		Prompt: value.Prompt, Archived: value.Archived, CreatedAt: value.CreatedAt,
		UpdatedAt: value.UpdatedAt, BoardCount: int32(value.BoardCount),
		CardCount: int32(value.CardCount), ChatCount: int32(value.ChatCount), PromptTemplate: value.PromptTemplate,
	}
}

func protoBoard(value model.Board) *naucliov1.Board {
	result := &naucliov1.Board{
		Id: value.ID, ProjectId: value.ProjectID, Name: value.Name,
		Workflow: value.Workflow, Description: value.Description,
		DoneArchivePolicy: value.DoneArchivePolicy, CreatedAt: value.CreatedAt,
		UpdatedAt: value.UpdatedAt, PromptTemplate: value.PromptTemplate,
	}
	for _, item := range value.Labels {
		result.Labels = append(result.Labels, &naucliov1.Label{Id: item.ID, Name: item.Name, Color: item.Color, Instructions: item.Instructions})
	}
	for _, item := range value.Lanes {
		result.Lanes = append(result.Lanes, &naucliov1.Lane{Id: item.ID, Name: item.Name})
	}
	return result
}

func protoCard(value model.Card) *naucliov1.Card {
	result := &naucliov1.Card{
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
	}
	if value.Origin != nil {
		result.Origin = &naucliov1.CardOrigin{
			Kind: value.Origin.Kind, ScheduleId: value.Origin.ScheduleID,
			ScheduleRunId: value.Origin.ScheduleRunID, ScheduledFor: value.Origin.ScheduledFor,
		}
	}
	return result
}

func protoCardDetail(value model.CardDetail) *naucliov1.CardDetail {
	result := &naucliov1.CardDetail{
		Card: protoCard(value.Card), Project: protoProject(value.Project), Board: protoBoard(value.Board),
	}
	for _, item := range value.Comments {
		result.Comments = append(result.Comments, protoComment(item))
	}
	return result
}

func protoComment(value model.Comment) *naucliov1.Comment {
	return &naucliov1.Comment{
		Id: value.ID, CardId: value.CardID, Author: &naucliov1.Author{
			Kind: value.Author.Kind, Name: value.Author.Name, ProjectId: value.Author.ProjectID,
			CardId: value.Author.CardID, Provider: value.Author.Provider, Model: value.Author.Model,
		}, Body: value.Body, CreatedAt: value.CreatedAt,
	}
}

func protoConversation(value model.Conversation) *naucliov1.Conversation {
	result := &naucliov1.Conversation{
		ProjectionVersion: int32(value.ProjectionVersion), CardId: value.CardID,
		Status: value.Status, LastSeq: value.LastSeq, UpdatedAt: value.UpdatedAt,
	}
	for _, item := range value.Messages {
		message := &naucliov1.UiMessage{Id: item.ID, Role: item.Role, MetadataJson: append([]byte(nil), item.Metadata...)}
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
		result.PendingTools = append(result.PendingTools, &naucliov1.PendingTool{
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
		queued := &naucliov1.QueuedMessage{Id: item.ID, Text: item.Text, CreatedAt: item.CreatedAt}
		for _, part := range item.Parts {
			queued.Parts = append(queued.Parts, protoMessagePart(part))
		}
		result.Queue = append(result.Queue, queued)
	}
	return result
}

func protoTaskPlan(value model.TaskPlan) *naucliov1.TaskPlan {
	result := &naucliov1.TaskPlan{
		Id: value.ID, Provider: value.Provider, MessageId: value.MessageID,
		Revision: value.Revision, State: value.State, Explanation: value.Explanation,
		Source: value.Source, UpdatedAt: value.UpdatedAt,
	}
	for _, phase := range value.Phases {
		protoPhase := &naucliov1.TaskPlanPhase{Name: phase.Name}
		for _, task := range phase.Tasks {
			protoPhase.Tasks = append(protoPhase.Tasks, &naucliov1.TaskPlanItem{
				Id: task.ID, Content: task.Content, ActiveForm: task.ActiveForm,
				Status: task.Status, Blocker: task.Blocker, Priority: task.Priority,
				Order: task.Order,
			})
		}
		result.Phases = append(result.Phases, protoPhase)
	}
	return result
}

func protoSubagent(value model.Subagent) *naucliov1.Subagent {
	return &naucliov1.Subagent{
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

func protoMessagePart(value model.UIMessagePart) *naucliov1.MessagePart {
	inputPreview, hasInput, inputSize := payloadSummary(value.Input)
	outputPreview, hasOutput, outputSize := payloadSummary(value.Output)
	result := &naucliov1.MessagePart{
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

func modelUserMessageParts(values []*naucliov1.MessagePart) ([]model.UIMessagePart, error) {
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

func modelUserAttachmentParts(values []*naucliov1.MessagePart) ([]model.UIMessagePart, error) {
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

func protoHarnessCatalog(values []harness.Adapter) *naucliov1.HarnessCatalog {
	result := &naucliov1.HarnessCatalog{}
	for _, value := range values {
		item := &naucliov1.Harness{Id: value.ID, Name: value.Name, DefaultModel: value.DefaultModel}
		for _, capability := range value.Capabilities {
			item.Capabilities = append(item.Capabilities, &naucliov1.HarnessCapability{Id: capability.ID, Level: capability.Level})
		}
		for _, option := range value.Options {
			wireOption := &naucliov1.ProviderOption{Id: option.ID, Name: option.Name, Description: option.Description, Type: option.Type, DefaultValue: option.Default}
			for _, choice := range option.Choices {
				wireOption.Choices = append(wireOption.Choices, &naucliov1.ProviderOptionChoice{Value: choice.Value, Name: choice.Name})
			}
			item.Options = append(item.Options, wireOption)
		}
		for _, model := range value.Models {
			if model.Hidden {
				continue
			}
			item.Models = append(item.Models, &naucliov1.HarnessModel{
				Id: model.ID, Name: model.Name, ContextWindow: int32(model.ContextWindow),
				DefaultEffort: model.DefaultEffort, Efforts: dedupeEfforts(model.Efforts),
			})
		}
		if value.Effort != nil {
			item.Effort = &naucliov1.EffortConfig{Label: value.Effort.Label}
			for _, option := range value.Effort.Options {
				item.Effort.Options = append(item.Effort.Options, &naucliov1.EffortOption{Id: option.ID, Name: option.Name})
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

func protoSchedule(value model.Schedule) *naucliov1.Schedule {
	return &naucliov1.Schedule{
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

func protoScheduleRun(value model.ScheduleRun) *naucliov1.ScheduleRun {
	return &naucliov1.ScheduleRun{
		Id: value.ID, ScheduleId: value.ScheduleID, ProjectId: value.ProjectID,
		BoardId: value.BoardID, CardId: value.CardID, ScheduledFor: value.ScheduledFor,
		Manual: value.Manual, Action: value.Action, Status: value.Status,
		Attempt: int32(value.Attempt), Message: value.Message, CreatedAt: value.CreatedAt,
		UpdatedAt: value.UpdatedAt, StartedAt: value.StartedAt, FinishedAt: value.FinishedAt,
	}
}
