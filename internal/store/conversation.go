package store

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

const conversationProjectionVersion = 5

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

// ConversationByID avoids a full card-directory scan when the caller already
// holds a canonical card ID from the global projection.
func (s *Store) ConversationByID(cardID string) (model.Conversation, error) {
	if !validFileID(cardID) {
		return model.Conversation{}, fmt.Errorf("card %q: %w", cardID, ErrNotFound)
	}
	if _, err := s.ResolveCard(cardID); err != nil {
		return model.Conversation{}, err
	}
	return s.loadConversation(cardID)
}

// InitializeForkConversation copies a completed prefix into a newly created
// standalone chat. The source session is deliberately not copied: lifecycle
// payloads identify one provider session and cannot safely back two chats.
func (s *Store) InitializeForkConversation(targetRef string, messages []model.UIMessage) (model.Conversation, error) {
	if len(messages) == 0 {
		return model.Conversation{}, errors.New("fork requires at least one message")
	}
	cloned := append([]model.UIMessage(nil), messages...)
	_, conversation, err := s.AppendConversationEvent(targetRef, "fork", "", "", cloned)
	return conversation, err
}

// ForkChat creates a provider-neutral transcript fork. The target gets its
// own card ID, workspace, runtime lease, and harness lifecycle.
func (s *Store) ForkChat(sourceRef, messageID, title string) (model.Card, error) {
	source, err := s.CardDetail(sourceRef)
	if err != nil {
		return model.Card{}, err
	}
	conversation, err := s.Conversation(source.Card.ID)
	if err != nil {
		return model.Card{}, err
	}
	if conversation.Status == "running" || conversation.Status == "starting" || conversation.ActiveTurn != nil {
		return model.Card{}, errors.New("cannot fork a conversation with an active turn")
	}
	end := len(conversation.Messages)
	if strings.TrimSpace(messageID) != "" {
		end = 0
		for index, message := range conversation.Messages {
			if message.ID == messageID {
				end = index + 1
				break
			}
		}
		if end == 0 {
			return model.Card{}, fmt.Errorf("message %q is not in the source conversation", messageID)
		}
	}
	if end == 0 {
		return model.Card{}, errors.New("cannot fork an empty conversation")
	}
	if strings.TrimSpace(title) == "" {
		title = "Fork of " + source.Card.Title
	}
	target, err := s.CreateChat(CreateCardInput{
		CheckoutID: source.Card.CheckoutID, Project: source.Project.ID, Title: title, Provider: source.Card.Provider,
		Model: source.Card.Model, Effort: source.Card.Effort,
		ProviderOptions: source.Card.ProviderOptions,
		WorkspaceMode:   source.Card.WorkspaceMode, WorkspaceBaseRemote: source.Card.WorkspaceBaseRemote,
		RemotePublishMode: source.Card.RemotePublishMode,
	})
	if err != nil {
		return model.Card{}, err
	}
	if _, err = s.InitializeForkConversation(target.ID, conversation.Messages[:end]); err != nil {
		return target, err
	}
	if _, err = s.MarkPromptSent(target.ID); err != nil {
		return target, err
	}
	return s.ResolveCard(target.ID)
}

// ConversationRevision is a cheap change token for the durable transcript.
// It lets read-only pollers avoid decoding snapshot.json when neither the
// snapshot nor its append-only event source has changed.
func (s *Store) ConversationRevision(cardRef string) (string, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return "", err
	}
	return s.ConversationRevisionByID(card.ID)
}

// ConversationRevisionByID is the constant-time form used by WatchSync's
// bounded conversation projection.
func (s *Store) ConversationRevisionByID(cardID string) (string, error) {
	if !validFileID(cardID) {
		return "", fmt.Errorf("card %q: %w", cardID, ErrNotFound)
	}
	parts := make([]string, 0, 2)
	for _, name := range []string{"snapshot.json", "events.ndjson"} {
		info, statErr := os.Stat(filepath.Join(s.conversationPath(cardID), name))
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

func (s *Store) loadConversation(cardID string) (model.Conversation, error) {
	// A replicated directory entry is never a local conversation.
	if !s.cardExists(cardID) {
		return model.Conversation{}, ErrRemoteConversation
	}
	identity, data, identityErr := s.sharedData()
	if identityErr != nil {
		return model.Conversation{}, identityErr
	}
	fields, _ := sharedFields(data, "item", cardID)
	var owner struct {
		OwnerDaemonID string `json:"ownerDaemonId"`
	}
	if json.Unmarshal(fields["identity"], &owner) != nil || owner.OwnerDaemonID != identity.DaemonID {
		return model.Conversation{}, ErrRemoteConversation
	}

	snapshotPath := filepath.Join(s.conversationPath(cardID), "snapshot.json")
	eventsPath := filepath.Join(s.conversationPath(cardID), "events.ndjson")
	snapshotInfo, err := os.Stat(snapshotPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return model.Conversation{}, err
	}
	eventsInfo, err := os.Stat(eventsPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return model.Conversation{}, err
	}
	conversation := newConversation(cardID)
	offset := int64(0)
	s.conversations.mu.Lock()
	cached, ok := s.conversations.entries[cardID]
	if ok && sameFileRevision(cached.snapshot, snapshotInfo) {
		if sameFileRevision(cached.events, eventsInfo) {
			s.conversations.clock++
			cached.used = s.conversations.clock
			s.conversations.entries[cardID] = cached
			result := cloneConversation(cached.conversation)
			s.conversations.mu.Unlock()
			return result, nil
		}
		// Only an append to the same journal can extend a cached projection.
		if cached.events != nil && eventsInfo != nil && os.SameFile(cached.events, eventsInfo) && eventsInfo.Size() > cached.events.Size() && cached.offset == cached.events.Size() {
			conversation = cloneConversation(cached.conversation)
			offset = cached.offset
		}
	}
	s.conversations.mu.Unlock()
	if offset == 0 {
		if raw, err := os.ReadFile(snapshotPath); err == nil {
			var checkpoint conversationCheckpointWire
			if err := json.Unmarshal(raw, &checkpoint); err != nil {
				return model.Conversation{}, fmt.Errorf("decode conversation snapshot: %w", err)
			}
			conversation = checkpoint.Conversation
			normalizeAssistantMessageParts(&conversation)
			if conversation.ProjectionVersion == conversationProjectionVersion && checkpoint.EventOffset > 0 && eventsInfo != nil && checkpoint.EventOffset <= eventsInfo.Size() {
				boundary, err := conversationEventBoundary(eventsPath, checkpoint.EventOffset)
				if err == nil && boundary != "" && boundary == checkpoint.EventBoundary {
					offset = checkpoint.EventOffset
				}
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return model.Conversation{}, err
		}
		if conversation.ProjectionVersion < conversationProjectionVersion {
			conversation = newConversation(cardID)
		}
	}
	file, err := os.Open(eventsPath)
	if errors.Is(err, os.ErrNotExist) {
		conversation.ProjectionVersion = conversationProjectionVersion
		return conversation, nil
	}
	if err != nil {
		return model.Conversation{}, err
	}
	defer file.Close()
	if eventsInfo == nil {
		eventsInfo, err = file.Stat()
		if err != nil {
			return model.Conversation{}, err
		}
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return model.Conversation{}, err
	}
	scanner := bufio.NewScanner(io.NewSectionReader(file, offset, eventsInfo.Size()-offset))
	scanner.Buffer(make([]byte, 64*1024), maxConversationEventBytes)
	for scanner.Scan() {
		line := scanner.Bytes()
		offset += int64(len(line) + 1)
		if offset > eventsInfo.Size() {
			// A complete JSON value without its newline is still a torn record.
			// The next append repairs that suffix, so it must not enter the projection.
			break
		}
		// Decode just the sequence before deciding whether to decode a large payload.
		// New snapshots record a validated journal offset; old snapshots still replay.
		sequence, valid := conversationEventSequence(line)
		if !valid || sequence <= conversation.LastSeq {
			continue
		}
		var event model.ConversationEvent
		if json.Unmarshal(line, &event) != nil {
			continue
		}
		reduceConversation(&conversation, event)
	}
	if err := scanner.Err(); err != nil {
		return model.Conversation{}, err
	}
	conversation.ProjectionVersion = conversationProjectionVersion
	afterEvents, _ := os.Stat(eventsPath)
	afterSnapshot, _ := os.Stat(snapshotPath)
	if sameFileRevision(eventsInfo, afterEvents) && sameFileRevision(snapshotInfo, afterSnapshot) && afterEvents != nil && offset == afterEvents.Size() {
		s.cacheConversation(cardID, conversation, snapshotInfo, eventsInfo, offset)
	}
	return conversation, nil
}

func (s *Store) AppendConversationEvent(cardRef, eventType, turnID, messageID string, data any) (model.ConversationEvent, model.Conversation, error) {
	raw, err := json.Marshal(data)
	if err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	writeKind := "store_changed"
	if eventType == "ui-chunk" || eventType == "capability" || eventType == "present-content" {
		writeKind = "conversation_changed"
		if eventType == "ui-chunk" {
			var chunk struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(raw, &chunk)
			// Usage updates change the Kanban directory projection; text deltas
			// continue using the inexpensive conversation-only sync route.
			if chunk.Type == "message-metadata" || chunk.Type == "finish" {
				writeKind = "store_changed"
			}
		}
	}
	release, err := s.beginWriteKind(writeKind)
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
	return s.appendConversationEvent(card, conversation, eventType, turnID, messageID, data)
}

// appendConversationEvent persists an event while the caller holds Dieter's
// cross-process write lock. Keeping the loaded projection and append in the
// same critical section lets conditional queue operations avoid racing the
// automatic transition into the next turn.
func (s *Store) appendConversationEvent(card model.Card, conversation model.Conversation, eventType, turnID, messageID string, data any) (model.ConversationEvent, model.Conversation, error) {
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
	if len(line)+1 >= maxConversationEventBytes {
		return model.ConversationEvent{}, model.Conversation{}, fmt.Errorf("conversation event exceeds %d bytes", maxConversationEventBytes)
	}
	if err := appendJournalRecord(filepath.Join(dir, "events.ndjson"), line); err != nil {
		return model.ConversationEvent{}, model.Conversation{}, err
	}
	reduceConversation(&conversation, event)
	// The fsynced journal is authoritative. Streaming deltas need no full
	// transcript rewrite; checkpoints bound cold replay and retain every event.
	checkpoint := event.Seq == 1 || event.Seq%128 == 0 || eventType != "ui-chunk"
	if eventType == "ui-chunk" {
		var chunk struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(raw, &chunk)
		checkpoint = checkpoint || chunk.Type == "finish" || chunk.Type == "abort" || chunk.Type == "error"
	}
	if checkpoint {
		s.queueConversationCheckpoint(card.ID, conversation)
	}

	snapshotInfo, _ := os.Stat(filepath.Join(dir, "snapshot.json"))
	eventsInfo, _ := os.Stat(filepath.Join(dir, "events.ndjson"))
	if eventsInfo != nil {
		s.cacheConversation(card.ID, conversation, snapshotInfo, eventsInfo, eventsInfo.Size())
	}
	s.rememberTokenUsage(card.ID, conversation)
	// Activity is a derived directory hint, not the event durability boundary.
	// Publish it at most four times/second during token bursts. Every semantic
	// event (including finish/error/abort, tools and runtime transitions) flushes
	// immediately. A killed worker can leave the hint <250ms behind; replay of
	// the fsynced journal still recovers every acknowledged token and timestamp.
	if shouldPublishConversationActivity(card.LastActivityAt, event) {
		card.LastActivityAt = event.CreatedAt
		card.UpdatedAt = event.CreatedAt
		if err := s.writeCard(card); err != nil {
			return model.ConversationEvent{}, model.Conversation{}, err
		}
	}
	return event, conversation, nil
}

func shouldPublishConversationActivity(previous string, event model.ConversationEvent) bool {
	if event.Type != "ui-chunk" {
		return true
	}
	var chunk struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(event.Data, &chunk) != nil {
		return true
	}
	switch chunk.Type {
	case "text-delta", "reasoning-delta", "tool-input-delta":
		before, err := time.Parse(time.RFC3339Nano, previous)
		at, atErr := time.Parse(time.RFC3339Nano, event.CreatedAt)
		return err != nil || atErr != nil || at.Before(before) || at.Sub(before) >= 250*time.Millisecond
	default:
		return true
	}
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
	release, err := s.beginWriteKind("store_changed")
	if err != nil {
		return model.Conversation{}, err
	}
	defer release()
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.Conversation{}, err
	}
	conversation, err := s.loadConversation(card.ID)
	if err != nil {
		return model.Conversation{}, err
	}
	if !slices.ContainsFunc(conversation.Queue, func(item model.QueuedMessage) bool { return item.ID == queueID }) {
		return model.Conversation{}, fmt.Errorf("%w: queued message %q", ErrNotFound, queueID)
	}
	createdAt := timestamp()
	metadata, _ := json.Marshal(map[string]string{"createdAt": createdAt})
	data := struct {
		QueueID string          `json:"queueId"`
		Message model.UIMessage `json:"message"`
	}{QueueID: queueID, Message: model.UIMessage{ID: messageID, Role: "user", Metadata: metadata, Parts: parts}}
	_, conversation, err = s.appendConversationEvent(card, conversation, "queued-user-message", turnID, messageID, data)
	return conversation, err
}

func (s *Store) QueueConversationMessage(cardRef, text string) (model.QueuedMessage, model.Conversation, error) {
	return s.QueueConversationMessageParts(cardRef, []model.UIMessagePart{{Type: "text", Text: strings.TrimSpace(text)}})
}

func (s *Store) QueueConversationMessageParts(cardRef string, parts []model.UIMessagePart) (model.QueuedMessage, model.Conversation, error) {
	return s.QueueConversationMessagePartsWithID(cardRef, "", parts)
}

func (s *Store) QueueConversationMessagePartsWithID(cardRef, messageID string, parts []model.UIMessagePart) (model.QueuedMessage, model.Conversation, error) {
	return s.QueueConversationMessageWithSelection(cardRef, messageID, parts, nil)
}

func (s *Store) QueueConversationMessageWithSelection(cardRef, messageID string, parts []model.UIMessagePart, selection *model.HarnessSelection) (model.QueuedMessage, model.Conversation, error) {
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
	queued := model.QueuedMessage{ID: messageID, Text: text, Parts: parts, CreatedAt: timestamp(), Selection: selection}
	_, conversation, err := s.AppendConversationEvent(cardRef, "queue-message", "", "", queued)
	return queued, conversation, err
}

// RemoveQueuedConversationMessage atomically removes one not-yet-started
// message and returns its full contents so a client can restore it to an
// editor without losing attachments.
func (s *Store) RemoveQueuedConversationMessage(cardRef, messageID string) (model.QueuedMessage, model.Conversation, error) {
	messageID = strings.TrimSpace(messageID)
	if messageID == "" {
		return model.QueuedMessage{}, model.Conversation{}, errors.New("queued message id is required")
	}
	release, err := s.beginWriteKind("store_changed")
	if err != nil {
		return model.QueuedMessage{}, model.Conversation{}, err
	}
	defer release()
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.QueuedMessage{}, model.Conversation{}, err
	}
	conversation, err := s.loadConversation(card.ID)
	if err != nil {
		return model.QueuedMessage{}, model.Conversation{}, err
	}
	index := slices.IndexFunc(conversation.Queue, func(item model.QueuedMessage) bool { return item.ID == messageID })
	if index < 0 {
		return model.QueuedMessage{}, model.Conversation{}, fmt.Errorf("%w: queued message %q", ErrNotFound, messageID)
	}
	removed := conversation.Queue[index]
	_, conversation, err = s.appendConversationEvent(card, conversation, "remove-queued-message", "", messageID, removed)
	return removed, conversation, err
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

func (s *Store) PresentConversationContent(cardRef, turnID string, presentation model.ContentPresentation) (model.ContentPresentation, error) {
	presentation.ID = newID("presentation_")
	_, _, err := s.AppendConversationEvent(cardRef, "present-content", turnID, "", presentation)
	return presentation, err
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
		runtime := "idle"
		if conversation.Status == "failed" {
			runtime = "failed"
		}
		if _, err := s.UpdateCardCache(card.ID, CardCacheInput{Runtime: runtime}); err != nil {
			return false, err
		}
	}
	return true, nil
}

func reduceConversation(conversation *model.Conversation, event model.ConversationEvent) {
	conversation.LastSeq = event.Seq
	conversation.UpdatedAt = event.CreatedAt
	switch event.Type {
	case "present-content":
		var presentation model.ContentPresentation
		if json.Unmarshal(event.Data, &presentation) == nil && presentation.ID != "" {
			conversation.PresentedContent = &presentation
		}
	case "draft-attachments":
		var parts []model.UIMessagePart
		if json.Unmarshal(event.Data, &parts) == nil {
			conversation.DraftAttachments = append(conversation.DraftAttachments[:0], parts...)
		}
	case "fork":
		var messages []model.UIMessage
		if json.Unmarshal(event.Data, &messages) == nil {
			conversation.Messages = append(conversation.Messages[:0], messages...)
			conversation.ForkSeed = append(conversation.ForkSeed[:0], messages...)
			conversation.Status = "idle"
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
			if queued.MergeSourceID != "" {
				conversation.MergedSourceIDs = append(conversation.MergedSourceIDs, queued.MergeSourceID)
			}
		}
	case "remove-queued-message":
		var removed model.QueuedMessage
		if json.Unmarshal(event.Data, &removed) == nil {
			conversation.Queue = slices.DeleteFunc(conversation.Queue, func(item model.QueuedMessage) bool {
				return item.ID == removed.ID
			})
		}
	case "session":
		var state json.RawMessage
		if json.Unmarshal(event.Data, &state) == nil {
			conversation.Session = append(conversation.Session[:0], state...)
			conversation.ForkSeed = nil
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

func conversationEventSequence(line []byte) (int64, bool) {
	if bytes.HasPrefix(line, []byte(`{"seq":`)) {
		end := bytes.IndexByte(line, ',')
		if end > 7 {
			sequence, err := strconv.ParseInt(string(line[7:end]), 10, 64)
			return sequence, err == nil
		}
	}
	var header struct {
		Seq int64 `json:"seq"`
	}
	err := json.Unmarshal(line, &header)
	return header.Seq, err == nil
}
