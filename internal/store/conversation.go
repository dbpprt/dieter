package store

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

const conversationProjectionVersion = 4

const maxConversationEventBytes = 16 << 20

func newConversation(cardID string) model.Conversation {
	return model.Conversation{ProjectionVersion: conversationProjectionVersion, CardID: cardID, Status: "idle", Messages: []model.UIMessage{}, DraftAttachments: []model.UIMessagePart{}, PendingTools: []model.PendingTool{}, Queue: []model.QueuedMessage{}}
}

func (s *Store) conversationPath(cardID string) string {
	return filepath.Join(s.conversationDir(), cardID)
}

func (s *Store) Conversation(cardRef string) (model.Conversation, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.Conversation{}, err
	}
	return s.loadConversation(card.ID)
}

// ConversationRevision is a cheap change token for the durable transcript.
// It lets read-only pollers avoid decoding snapshot.json when neither the
// snapshot nor its append-only event source has changed.
func (s *Store) ConversationRevision(cardRef string) (string, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return "", err
	}
	parts := make([]string, 0, 2)
	for _, name := range []string{"snapshot.json", "events.ndjson"} {
		info, statErr := os.Stat(filepath.Join(s.conversationPath(card.ID), name))
		if errors.Is(statErr, os.ErrNotExist) {
			parts = append(parts, name+":missing")
			continue
		}
		if statErr != nil {
			return "", statErr
		}
		parts = append(parts, fmt.Sprintf("%s:%d:%d", name, info.Size(), info.ModTime().UnixNano()))
	}
	return strings.Join(parts, "|"), nil
}

// conversationStatus reads the early status field without decoding a
// potentially very large transcript. If the append-only event source is newer
// than its projection (the crash window), it falls back to a full replay.
func (s *Store) conversationStatus(cardID string) (string, error) {
	snapshotPath := filepath.Join(s.conversationPath(cardID), "snapshot.json")
	snapshotInfo, err := os.Stat(snapshotPath)
	if errors.Is(err, os.ErrNotExist) {
		conversation, loadErr := s.loadConversation(cardID)
		return conversation.Status, loadErr
	}
	if err != nil {
		return "", err
	}
	if eventsInfo, statErr := os.Stat(filepath.Join(s.conversationPath(cardID), "events.ndjson")); statErr == nil && eventsInfo.ModTime().After(snapshotInfo.ModTime()) {
		conversation, loadErr := s.loadConversation(cardID)
		return conversation.Status, loadErr
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return "", statErr
	}
	file, err := os.Open(snapshotPath)
	if err != nil {
		return "", err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	if _, err := decoder.Token(); err != nil {
		return "", err
	}
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return "", err
		}
		if key == "status" {
			var status string
			if err := decoder.Decode(&status); err != nil {
				return "", err
			}
			return status, nil
		}
		var ignored json.RawMessage
		if err := decoder.Decode(&ignored); err != nil {
			return "", err
		}
	}
	return "idle", nil
}

func (s *Store) loadConversation(cardID string) (model.Conversation, error) {
	conversation := newConversation(cardID)
	snapshotPath := filepath.Join(s.conversationPath(cardID), "snapshot.json")
	if raw, err := os.ReadFile(snapshotPath); err == nil {
		var snapshot model.Conversation
		if err := json.Unmarshal(raw, &snapshot); err != nil {
			return model.Conversation{}, fmt.Errorf("decode conversation snapshot: %w", err)
		}
		conversation = snapshot
		normalizeAssistantMessageParts(&conversation)
	} else if !errors.Is(err, os.ErrNotExist) {
		return model.Conversation{}, err
	}

	// Reconcile events written immediately before a crash but not yet projected
	// into snapshot.json. JSONL deliberately tolerates one partial final line.
	eventsPath := filepath.Join(s.conversationPath(cardID), "events.ndjson")
	file, err := os.Open(eventsPath)
	if errors.Is(err, os.ErrNotExist) {
		conversation.ProjectionVersion = conversationProjectionVersion
		return conversation, nil
	}
	if err != nil {
		return model.Conversation{}, err
	}
	defer file.Close()
	if conversation.ProjectionVersion < conversationProjectionVersion {
		// Snapshots are disposable projections. Replaying the source events is
		// the lossless migration path when reducer semantics change.
		conversation = newConversation(cardID)
	}
	scanner := bufio.NewScanner(file)
	buffer := make([]byte, 64*1024)
	scanner.Buffer(buffer, maxConversationEventBytes)
	for scanner.Scan() {
		var event model.ConversationEvent
		if json.Unmarshal(scanner.Bytes(), &event) != nil || event.Seq <= conversation.LastSeq {
			continue
		}
		reduceConversation(&conversation, event)
	}
	if err := scanner.Err(); err != nil {
		return model.Conversation{}, err
	}
	conversation.ProjectionVersion = conversationProjectionVersion
	return conversation, nil
}

func (s *Store) AppendConversationEvent(cardRef, eventType, turnID, messageID string, data any) (model.ConversationEvent, model.Conversation, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	defer release()
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	conversation, err := s.loadConversation(card.ID)
	if err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	event := model.ConversationEvent{Seq: conversation.LastSeq + 1, Type: eventType, TurnID: turnID, MessageID: messageID, Data: raw, CreatedAt: timestamp()}
	dir := s.conversationPath(card.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	line, _ := json.Marshal(event)
	file, err := os.OpenFile(filepath.Join(dir, "events.ndjson"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	_, writeErr := file.Write(append(line, '\n'))
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if writeErr != nil {
		return model.ConversationEvent{}, model.Conversation{}, writeErr
	}
	if closeErr != nil {
		return model.ConversationEvent{}, model.Conversation{}, closeErr
	}
	reduceConversation(&conversation, event)
	snapshot, _ := json.MarshalIndent(conversation, "", "  ")
	if err := atomicWrite(filepath.Join(dir, "snapshot.json"), append(snapshot, '\n')); err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	card.LastActivityAt = event.CreatedAt
	card.UpdatedAt = event.CreatedAt
	if err := s.writeCard(card); err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	return event, conversation, nil
}

func (s *Store) StartConversationTurn(cardRef, turnID, messageID, text string) (model.Conversation, error) {
	return s.StartConversationTurnParts(cardRef, turnID, messageID, []model.UIMessagePart{{Type: "text", Text: strings.TrimSpace(text)}})
}

func (s *Store) SetConversationDraftAttachments(cardRef string, parts []model.UIMessagePart) (model.Conversation, error) {
	attachments := append([]model.UIMessagePart(nil), parts...)
	_, conversation, err := s.AppendConversationEvent(cardRef, "draft-attachments", "", "", attachments)
	return conversation, err
}

func (s *Store) StartConversationTurnParts(cardRef, turnID, messageID string, parts []model.UIMessagePart) (model.Conversation, error) {
	createdAt := timestamp()
	metadata, _ := json.Marshal(map[string]string{"createdAt": createdAt})
	message := model.UIMessage{ID: messageID, Role: "user", Metadata: metadata, Parts: parts}
	_, conversation, err := s.AppendConversationEvent(cardRef, "user-message", turnID, messageID, message)
	return conversation, err
}

func (s *Store) StartQueuedConversationTurn(cardRef, turnID, messageID, queueID, text string) (model.Conversation, error) {
	return s.StartQueuedConversationTurnParts(cardRef, turnID, messageID, queueID, []model.UIMessagePart{{Type: "text", Text: strings.TrimSpace(text)}})
}

func (s *Store) StartQueuedConversationTurnParts(cardRef, turnID, messageID, queueID string, parts []model.UIMessagePart) (model.Conversation, error) {
	createdAt := timestamp()
	metadata, _ := json.Marshal(map[string]string{"createdAt": createdAt})
	data := struct {
		QueueID string          `json:"queueId"`
		Message model.UIMessage `json:"message"`
	}{QueueID: queueID, Message: model.UIMessage{ID: messageID, Role: "user", Metadata: metadata, Parts: parts}}
	_, conversation, err := s.AppendConversationEvent(cardRef, "queued-user-message", turnID, messageID, data)
	return conversation, err
}

func (s *Store) QueueConversationMessage(cardRef, text string) (model.QueuedMessage, model.Conversation, error) {
	return s.QueueConversationMessageParts(cardRef, []model.UIMessagePart{{Type: "text", Text: strings.TrimSpace(text)}})
}

func (s *Store) QueueConversationMessageParts(cardRef string, parts []model.UIMessagePart) (model.QueuedMessage, model.Conversation, error) {
	return s.QueueConversationMessagePartsWithID(cardRef, "", parts)
}

func (s *Store) QueueConversationMessagePartsWithID(cardRef, messageID string, parts []model.UIMessagePart) (model.QueuedMessage, model.Conversation, error) {
	text := ""
	for _, part := range parts {
		if part.Type == "text" {
			text += part.Text
		}
	}
	text = strings.TrimSpace(text)
	if text == "" && len(parts) == 0 {
		return model.QueuedMessage{}, model.Conversation{}, errors.New("message is required")
	}
	if strings.TrimSpace(messageID) == "" {
		messageID = newID("queued_")
	}
	if conversation, err := s.Conversation(cardRef); err == nil {
		for _, queued := range conversation.Queue {
			if queued.ID == messageID {
				return queued, conversation, nil
			}
		}
		for _, message := range conversation.Messages {
			if message.ID == messageID {
				return model.QueuedMessage{ID: messageID, Text: text, Parts: parts, CreatedAt: conversation.UpdatedAt}, conversation, nil
			}
		}
	}
	queued := model.QueuedMessage{ID: messageID, Text: text, Parts: parts, CreatedAt: timestamp()}
	_, conversation, err := s.AppendConversationEvent(cardRef, "queue-message", "", "", queued)
	return queued, conversation, err
}

func (s *Store) SetConversationSession(cardRef, turnID string, state json.RawMessage) (model.Conversation, error) {
	if len(bytes.TrimSpace(state)) == 0 {
		state = json.RawMessage("null")
	}
	_, conversation, err := s.AppendConversationEvent(cardRef, "session", turnID, "", state)
	return conversation, err
}

func (s *Store) SetConversationActiveTurn(cardRef string, turn model.ConversationTurn) (model.Conversation, error) {
	_, conversation, err := s.AppendConversationEvent(cardRef, "turn-start", turn.ID, turn.UserMessageID, turn)
	return conversation, err
}

func (s *Store) SetConversationStatus(cardRef, turnID, status string) (model.Conversation, error) {
	_, conversation, err := s.AppendConversationEvent(cardRef, "status", turnID, "", status)
	return conversation, err
}

func (s *Store) AppendUIChunk(cardRef, turnID string, chunk json.RawMessage) (model.ConversationEvent, model.Conversation, error) {
	return s.AppendConversationEvent(cardRef, "ui-chunk", turnID, "", chunk)
}

func (s *Store) AppendCapability(cardRef, turnID string, capability json.RawMessage) (model.ConversationEvent, model.Conversation, error) {
	return s.AppendConversationEvent(cardRef, "capability", turnID, "", capability)
}

// InterruptConversation durably closes a turn whose worker is no longer
// owned by this process. It is deliberately idempotent so cancellation and
// startup recovery can race safely.
func (s *Store) InterruptConversation(cardRef string) (bool, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return false, err
	}
	conversation, err := s.Conversation(card.ID)
	if err != nil {
		return false, err
	}
	activeConversation := conversation.Status == "running" || conversation.Status == "starting"
	activeCard := card.Runtime == "running" || card.Runtime == "starting"
	if !activeConversation && !activeCard {
		return false, nil
	}
	if activeConversation {
		chunk, _ := json.Marshal(map[string]any{"type": "abort", "reason": "agent turn interrupted"})
		if _, _, err := s.AppendUIChunk(card.ID, "", chunk); err != nil {
			return false, err
		}
	}
	if activeCard {
		if _, err := s.UpdateCardCache(card.ID, CardCacheInput{Runtime: "idle"}); err != nil {
			return false, err
		}
	}
	return true, nil
}

func reduceConversation(conversation *model.Conversation, event model.ConversationEvent) {
	conversation.LastSeq = event.Seq
	conversation.UpdatedAt = event.CreatedAt
	switch event.Type {
	case "draft-attachments":
		var parts []model.UIMessagePart
		if json.Unmarshal(event.Data, &parts) == nil {
			conversation.DraftAttachments = append(conversation.DraftAttachments[:0], parts...)
		}
	case "user-message":
		var message model.UIMessage
		if json.Unmarshal(event.Data, &message) == nil {
			conversation.Messages = append(conversation.Messages, message)
			conversation.DraftAttachments = nil
			conversation.Status = "running"
		}
	case "queued-user-message":
		var data struct {
			QueueID string          `json:"queueId"`
			Message model.UIMessage `json:"message"`
		}
		if json.Unmarshal(event.Data, &data) == nil {
			for index := range conversation.Queue {
				if conversation.Queue[index].ID == data.QueueID {
					conversation.Queue = append(conversation.Queue[:index], conversation.Queue[index+1:]...)
					break
				}
			}
			conversation.Messages = append(conversation.Messages, data.Message)
			conversation.Status = "running"
		}
	case "queue-message":
		var queued model.QueuedMessage
		if json.Unmarshal(event.Data, &queued) == nil {
			conversation.Queue = append(conversation.Queue, queued)
		}
	case "session":
		var state json.RawMessage
		if json.Unmarshal(event.Data, &state) == nil {
			conversation.Session = append(conversation.Session[:0], state...)
		}
	case "turn-start":
		var turn model.ConversationTurn
		if json.Unmarshal(event.Data, &turn) == nil && turn.ID != "" {
			conversation.ActiveTurn = &turn
		}
	case "status":
		var status string
		if json.Unmarshal(event.Data, &status) == nil {
			conversation.Status = status
		}
	case "ui-chunk":
		var raw json.RawMessage
		if json.Unmarshal(event.Data, &raw) == nil {
			reduceUIChunk(conversation, raw, event.CreatedAt)
		}
	case "capability":
		var raw json.RawMessage
		if json.Unmarshal(event.Data, &raw) == nil {
			reduceCapability(conversation, raw)
		}
	}
}

func reduceCapability(conversation *model.Conversation, raw json.RawMessage) {
	var envelope struct {
		ID        string         `json:"id"`
		Operation string         `json:"operation"`
		Subagent  model.Subagent `json:"subagent"`
		Plan      model.TaskPlan `json:"plan"`
	}
	if json.Unmarshal(raw, &envelope) != nil {
		return
	}
	if envelope.ID == "task-plan" && envelope.Operation == "replace" && envelope.Plan.ID != "" && envelope.Plan.MessageID != "" {
		for index := range conversation.TaskPlans {
			current := conversation.TaskPlans[index]
			if current.ID == envelope.Plan.ID && current.MessageID == envelope.Plan.MessageID && current.Provider == envelope.Plan.Provider {
				if envelope.Plan.Revision >= current.Revision {
					conversation.TaskPlans[index] = envelope.Plan
				}
				return
			}
		}
		conversation.TaskPlans = append(conversation.TaskPlans, envelope.Plan)
		return
	}
	if envelope.ID != "subagents" || envelope.Operation != "upsert" || envelope.Subagent.ID == "" {
		return
	}
	for index := range conversation.Subagents {
		current := conversation.Subagents[index]
		if current.ID == envelope.Subagent.ID && current.MessageID == envelope.Subagent.MessageID && current.Provider == envelope.Subagent.Provider {
			conversation.Subagents[index] = envelope.Subagent
			return
		}
	}
	conversation.Subagents = append(conversation.Subagents, envelope.Subagent)
}

func reduceUIChunk(conversation *model.Conversation, raw json.RawMessage, createdAt string) {
	var chunk map[string]json.RawMessage
	if json.Unmarshal(raw, &chunk) != nil {
		return
	}
	var chunkType string
	_ = json.Unmarshal(chunk["type"], &chunkType)
	stringValue := func(name string) string {
		var value string
		_ = json.Unmarshal(chunk[name], &value)
		return value
	}
	ensureAssistant := func() *model.UIMessage {
		id := stringValue("messageId")
		if len(conversation.Messages) > 0 {
			last := &conversation.Messages[len(conversation.Messages)-1]
			if last.Role == "assistant" && (id == "" || last.ID == id) {
				return last
			}
		}
		if id == "" {
			id = newID("msg_")
		}
		metadata, _ := json.Marshal(map[string]string{"createdAt": createdAt})
		conversation.Messages = append(conversation.Messages, model.UIMessage{ID: id, Role: "assistant", Metadata: metadata, Parts: []model.UIMessagePart{}})
		return &conversation.Messages[len(conversation.Messages)-1]
	}
	applyMetadata := func(message *model.UIMessage) {
		if metadata := chunk["messageMetadata"]; len(metadata) > 0 && string(metadata) != "null" {
			message.Metadata = append(message.Metadata[:0], metadata...)
		}
	}
	findStreamingPart := func(message *model.UIMessage, kind string) *model.UIMessagePart {
		// ACP providers may close and immediately reopen a text or reasoning
		// stream for each content block, even though no semantic boundary was
		// emitted. Continue the adjacent part, but never reach across a tool or
		// a different visible part in the message timeline.
		if len(message.Parts) > 0 {
			last := &message.Parts[len(message.Parts)-1]
			if last.Type == kind && (last.State == "streaming" || last.State == "done") {
				last.State = "streaming"
				return last
			}
		}
		message.Parts = append(message.Parts, model.UIMessagePart{Type: kind, State: "streaming"})
		return &message.Parts[len(message.Parts)-1]
	}
	switch chunkType {
	case "start":
		applyMetadata(ensureAssistant())
		conversation.Status = "running"
	case "message-metadata":
		applyMetadata(ensureAssistant())
	case "text-start", "reasoning-start":
		kind := strings.TrimSuffix(chunkType, "-start")
		findStreamingPart(ensureAssistant(), kind)
	case "text-delta", "reasoning-delta":
		kind := strings.TrimSuffix(chunkType, "-delta")
		findStreamingPart(ensureAssistant(), kind).Text += stringValue("delta")
	case "text-end", "reasoning-end":
		kind := strings.TrimSuffix(chunkType, "-end")
		findStreamingPart(ensureAssistant(), kind).State = "done"
	case "tool-input-available", "tool-approval-request", "tool-output-available", "tool-output-error":
		message := ensureAssistant()
		toolCallID := stringValue("toolCallId")
		state := map[string]string{
			"tool-input-available":  "input-available",
			"tool-approval-request": "approval-requested",
			"tool-output-available": "output-available",
			"tool-output-error":     "output-error",
		}[chunkType]
		part := model.UIMessagePart{Type: "dynamic-tool", ToolCallID: toolCallID, ToolName: stringValue("toolName"), State: state}
		part.Input, part.Output = chunk["input"], chunk["output"]
		part.ErrorText = stringValue("errorText")
		for index := range message.Parts {
			if message.Parts[index].ToolCallID == toolCallID && toolCallID != "" {
				previous := message.Parts[index]
				if part.ToolName == "" {
					part.ToolName = previous.ToolName
				}
				if len(part.Input) == 0 {
					part.Input = previous.Input
				}
				if len(part.Output) == 0 {
					part.Output = previous.Output
				}
				message.Parts[index] = part
				return
			}
		}
		message.Parts = append(message.Parts, part)
	case "error":
		message := ensureAssistant()
		message.Parts = append(message.Parts, model.UIMessagePart{Type: "text", Text: stringValue("errorText"), State: "error"})
		conversation.Status = "failed"
		conversation.ActiveTurn = nil
	case "abort":
		conversation.Status = "interrupted"
		conversation.ActiveTurn = nil
		for index := range conversation.Subagents {
			if conversation.Subagents[index].Status == "running" || conversation.Subagents[index].Status == "pending" {
				conversation.Subagents[index].Status = "aborted"
				conversation.Subagents[index].Activity = "Stopped"
				conversation.Subagents[index].EndedAt = createdAt
				conversation.Subagents[index].UpdatedAt = createdAt
			}
		}
		for planIndex := range conversation.TaskPlans {
			if conversation.TaskPlans[planIndex].State != "active" {
				continue
			}
			conversation.TaskPlans[planIndex].State = "interrupted"
			conversation.TaskPlans[planIndex].UpdatedAt = createdAt
			for phaseIndex := range conversation.TaskPlans[planIndex].Phases {
				for taskIndex := range conversation.TaskPlans[planIndex].Phases[phaseIndex].Tasks {
					if conversation.TaskPlans[planIndex].Phases[phaseIndex].Tasks[taskIndex].Status == "in_progress" {
						conversation.TaskPlans[planIndex].Phases[phaseIndex].Tasks[taskIndex].Status = "abandoned"
					}
				}
			}
		}
	case "finish":
		applyMetadata(ensureAssistant())
		conversation.Status = "idle"
		conversation.ActiveTurn = nil
	}
}

func normalizeAssistantMessageParts(conversation *model.Conversation) {
	for messageIndex := range conversation.Messages {
		message := &conversation.Messages[messageIndex]
		if message.Role != "assistant" || len(message.Parts) < 2 {
			continue
		}
		parts := make([]model.UIMessagePart, 0, len(message.Parts))
		for _, part := range message.Parts {
			if len(parts) > 0 && canCoalesceAssistantPart(parts[len(parts)-1], part) {
				last := &parts[len(parts)-1]
				last.Text += part.Text
				if part.State != "" {
					last.State = part.State
				}
				continue
			}
			parts = append(parts, part)
		}
		message.Parts = parts
	}
}

func canCoalesceAssistantPart(left, right model.UIMessagePart) bool {
	if left.Type != right.Type || (left.Type != "text" && left.Type != "reasoning") {
		return false
	}
	return left.State != "error" && right.State != "error"
}
