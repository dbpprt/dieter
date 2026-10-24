// Package channels stores the agent channels of one daemon: per project an
// append-only event log (channels/<project>/events.ndjson) of posts and their
// later pins and deliveries, and a read state (state.json) with the human read
// position. Every mutation runs under the central writer lock; appends are
// fsynced and compaction replaces the log atomically.
package channels

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store/home"
)

// Retention keeps the newest retainMessages posts (and every pinned post) once
// a log reaches compactLines lines.
var (
	retainMessages = 2000
	compactLines   = 6000
)

var validProjectID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// ErrUnknownMessage reports a message ID that is not in the channel.
var ErrUnknownMessage = fault.New(fault.NotFound, "channel message not found")

// Store is the channel aggregate of one DIETER_HOME.
type Store struct {
	home *home.Dir

	mu   sync.Mutex
	logs map[string]*projectLog
}

// New returns the channel aggregate of dir.
func New(dir *home.Dir) *Store { return &Store{home: dir, logs: map[string]*projectLog{}} }

type event struct {
	Type        string                `json:"type"`
	Message     *model.ChannelMessage `json:"message,omitempty"`
	OperationID string                `json:"operationId,omitempty"`
	ID          string                `json:"id,omitempty"`
	Pinned      bool                  `json:"pinned,omitempty"`
	CardID      string                `json:"cardId,omitempty"`
	Mode        string                `json:"mode,omitempty"`
	At          string                `json:"at,omitempty"`
}

type projectLog struct {
	size       int64
	lines      int
	messages   []model.ChannelMessage
	index      map[string]int
	operations map[string]string
}

type readState struct {
	Seen int64 `json:"seen"`
}

func (s *Store) dir(projectID string) (string, error) {
	if !validProjectID.MatchString(projectID) {
		return "", fault.New(fault.Invalid, "invalid project ID")
	}
	return filepath.Join(s.home.Root, "channels", projectID), nil
}

// Projects lists the projects that have a channel log on this daemon.
func (s *Store) Projects() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(s.home.Root, "channels"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var projects []string
	for _, entry := range entries {
		if entry.IsDir() && validProjectID.MatchString(entry.Name()) {
			projects = append(projects, entry.Name())
		}
	}
	return projects, nil
}

// load returns the cached log of projectID, rereading it when the file
// changed size. Callers hold s.mu.
func (s *Store) load(projectID string) (*projectLog, error) {
	dir, err := s.dir(projectID)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "events.ndjson")
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		log := &projectLog{index: map[string]int{}, operations: map[string]string{}}
		s.logs[projectID] = log
		return log, nil
	}
	if err != nil {
		return nil, err
	}
	if cached := s.logs[projectID]; cached != nil && cached.size == info.Size() {
		return cached, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	log := &projectLog{size: int64(len(raw)), index: map[string]int{}, operations: map[string]string{}}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var e event
		// A crash can leave a torn final line; every complete line is valid.
		if json.Unmarshal(line, &e) != nil {
			continue
		}
		log.lines++
		log.apply(e)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	s.logs[projectID] = log
	return log, nil
}

func (l *projectLog) apply(e event) {
	switch e.Type {
	case "post":
		if e.Message == nil {
			return
		}
		message := *e.Message
		if _, exists := l.index[message.ID]; exists {
			return
		}
		l.index[message.ID] = len(l.messages)
		l.messages = append(l.messages, message)
		if e.OperationID != "" {
			l.operations[e.OperationID] = message.ID
		}
		if message.ThreadID != "" {
			if root, ok := l.index[message.ThreadID]; ok {
				l.messages[root].ReplyCount++
			}
		}
	case "pin":
		if at, ok := l.index[e.ID]; ok {
			l.messages[at].Pinned = e.Pinned
		}
	case "deliver":
		if at, ok := l.index[e.ID]; ok {
			deliveries := l.messages[at].Deliveries
			for i := range deliveries {
				if deliveries[i].CardID == e.CardID {
					deliveries[i] = model.ChannelDelivery{CardID: e.CardID, Mode: e.Mode, At: e.At}
					return
				}
			}
			l.messages[at].Deliveries = append(deliveries, model.ChannelDelivery{CardID: e.CardID, Mode: e.Mode, At: e.At})
		}
	}
}

func (l *projectLog) lastSeq() int64 {
	if len(l.messages) == 0 {
		return 0
	}
	return l.messages[len(l.messages)-1].Seq
}

// append writes events durably and applies them to the cached log. Callers
// hold the writer lock and s.mu.
func (s *Store) append(projectID string, log *projectLog, events ...event) error {
	dir, err := s.dir(projectID)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	var buffer bytes.Buffer
	for _, e := range events {
		raw, err := json.Marshal(e)
		if err != nil {
			return err
		}
		buffer.Write(raw)
		buffer.WriteByte('\n')
	}
	path := filepath.Join(dir, "events.ndjson")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(buffer.Bytes()); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		// The cached projection may now lag a partial append; reread next time.
		delete(s.logs, projectID)
		return err
	}
	for _, e := range events {
		log.lines++
		log.apply(e)
	}
	log.size += int64(buffer.Len())
	if log.lines >= compactLines {
		return s.compact(projectID, log)
	}
	return nil
}

// compact atomically rewrites the log with the newest RetainMessages posts,
// every pinned post and their deliveries.
func (s *Store) compact(projectID string, log *projectLog) error {
	dir, _ := s.dir(projectID)
	keepFrom := max(0, len(log.messages)-retainMessages)
	var kept []model.ChannelMessage
	for i, message := range log.messages {
		if i >= keepFrom || message.Pinned {
			kept = append(kept, message)
		}
	}
	operations := map[string]string{}
	for operation, id := range log.operations {
		operations[id] = operation
	}
	var buffer bytes.Buffer
	next := &projectLog{index: map[string]int{}, operations: map[string]string{}}
	write := func(e event) {
		raw, _ := json.Marshal(e)
		buffer.Write(raw)
		buffer.WriteByte('\n')
		next.lines++
		next.apply(e)
	}
	for _, message := range kept {
		post := message
		deliveries := post.Deliveries
		post.Deliveries, post.ReplyCount = nil, 0
		write(event{Type: "post", Message: &post, OperationID: operations[post.ID]})
		if message.Pinned {
			write(event{Type: "pin", ID: post.ID, Pinned: true})
		}
		for _, delivery := range deliveries {
			write(event{Type: "deliver", ID: post.ID, CardID: delivery.CardID, Mode: delivery.Mode, At: delivery.At})
		}
	}
	if err := fsx.WriteFile(filepath.Join(dir, "events.ndjson"), buffer.Bytes(), 0o600); err != nil {
		delete(s.logs, projectID)
		return err
	}
	next.size = int64(buffer.Len())
	s.logs[projectID] = next
	return nil
}

// Post appends a message with the next sequence number of its project. A
// repeated operationID returns the original message and false.
func (s *Store) Post(message model.ChannelMessage, operationID string) (model.ChannelMessage, bool, error) {
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return model.ChannelMessage{}, false, err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(message.ProjectID)
	if err != nil {
		return model.ChannelMessage{}, false, err
	}
	if operationID != "" {
		if id, ok := log.operations[operationID]; ok {
			return log.messages[log.index[id]], false, nil
		}
	}
	if message.ThreadID != "" {
		root, ok := log.index[message.ThreadID]
		if !ok {
			return model.ChannelMessage{}, false, fault.New(fault.NotFound, "thread root not found")
		}
		// Replies always attach to the root, never to another reply.
		if parent := log.messages[root].ThreadID; parent != "" {
			message.ThreadID = parent
		}
	}
	message.ID = home.NewID("m_")
	message.Seq = log.lastSeq() + 1
	if message.CreatedAt == "" {
		message.CreatedAt = home.Timestamp()
	}
	message.Deliveries, message.ReplyCount, message.Pinned = nil, 0, false
	if err := s.append(message.ProjectID, log, event{Type: "post", Message: &message, OperationID: operationID}); err != nil {
		return model.ChannelMessage{}, false, err
	}
	return s.messageLocked(message.ProjectID, message.ID)
}

func (s *Store) messageLocked(projectID, id string) (model.ChannelMessage, bool, error) {
	log, err := s.load(projectID)
	if err != nil {
		return model.ChannelMessage{}, false, err
	}
	at, ok := log.index[id]
	if !ok {
		return model.ChannelMessage{}, false, ErrUnknownMessage
	}
	return cloneMessage(log.messages[at]), true, nil
}

// Message returns one message of a project channel.
func (s *Store) Message(projectID, id string) (model.ChannelMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	message, _, err := s.messageLocked(projectID, id)
	return message, err
}

// Pin sets a message's pinned state (a pinned message is a decision).
func (s *Store) Pin(projectID, id string, pinned bool) (model.ChannelMessage, error) {
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return model.ChannelMessage{}, err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return model.ChannelMessage{}, err
	}
	at, ok := log.index[id]
	if !ok {
		return model.ChannelMessage{}, ErrUnknownMessage
	}
	if log.messages[at].Pinned != pinned {
		if err := s.append(projectID, log, event{Type: "pin", ID: id, Pinned: pinned}); err != nil {
			return model.ChannelMessage{}, err
		}
	}
	message, _, err := s.messageLocked(projectID, id)
	return message, err
}

// Deliver records that messages (IDs) reached cardID by mode.
func (s *Store) Deliver(projectID, cardID, mode string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return err
	}
	at := home.Timestamp()
	events := make([]event, 0, len(ids))
	for _, id := range ids {
		if _, ok := log.index[id]; ok {
			events = append(events, event{Type: "deliver", ID: id, CardID: cardID, Mode: mode, At: at})
		}
	}
	if len(events) == 0 {
		return nil
	}
	return s.append(projectID, log, events...)
}

// Undelivered returns, oldest first, the messages addressed to cardID that
// were created at or after since and have no delivery to it yet.
func (s *Store) Undelivered(projectID, cardID, since string) ([]model.ChannelMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return nil, err
	}
	var pending []model.ChannelMessage
	for _, message := range log.messages {
		if message.CreatedAt < since || !message.AddressedTo(cardID) {
			continue
		}
		if slices.ContainsFunc(message.Deliveries, func(d model.ChannelDelivery) bool { return d.CardID == cardID }) {
			continue
		}
		pending = append(pending, cloneMessage(message))
	}
	return pending, nil
}

// Page selects messages of a project channel. With threadID it returns the
// thread root and its replies. limit is clamped to 1..200 (default 50).
func (s *Store) Page(projectID string, afterSeq, beforeSeq int64, limit int, threadID string) ([]model.ChannelMessage, int64, bool, error) {
	if limit <= 0 {
		limit = 50
	}
	limit = min(limit, 200)
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return nil, 0, false, err
	}
	var selected []model.ChannelMessage
	for _, message := range log.messages {
		if threadID != "" && message.ID != threadID && message.ThreadID != threadID {
			continue
		}
		if afterSeq > 0 && message.Seq <= afterSeq || beforeSeq > 0 && message.Seq >= beforeSeq {
			continue
		}
		selected = append(selected, message)
	}
	more := false
	if len(selected) > limit {
		more = true
		if afterSeq > 0 {
			selected = selected[:limit]
		} else {
			selected = selected[len(selected)-limit:]
		}
	}
	page := make([]model.ChannelMessage, len(selected))
	for i, message := range selected {
		page[i] = cloneMessage(message)
	}
	return page, log.lastSeq(), more, nil
}

// Matching returns up to limit messages, newest first, that satisfy keep.
func (s *Store) Matching(projectID string, limit int, keep func(model.ChannelMessage) bool) ([]model.ChannelMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return nil, err
	}
	var matched []model.ChannelMessage
	for i := len(log.messages) - 1; i >= 0 && len(matched) < limit; i-- {
		if keep(log.messages[i]) {
			matched = append(matched, cloneMessage(log.messages[i]))
		}
	}
	return matched, nil
}

// LastSeq returns the newest sequence number of a project channel.
func (s *Store) LastSeq(projectID string) (int64, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return 0, "", err
	}
	if len(log.messages) == 0 {
		return 0, "", nil
	}
	last := log.messages[len(log.messages)-1]
	return last.Seq, last.CreatedAt, nil
}

// Unread counts the messages after the human read position.
func (s *Store) Unread(projectID string) (seen int64, unread int, err error) {
	seen, err = s.Seen(projectID)
	if err != nil {
		return 0, 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	log, err := s.load(projectID)
	if err != nil {
		return 0, 0, err
	}
	at := sort.Search(len(log.messages), func(i int) bool { return log.messages[i].Seq > seen })
	for _, message := range log.messages[at:] {
		if message.Author.Kind != model.ChannelAuthorHuman {
			unread++
		}
	}
	return seen, unread, nil
}

// Seen returns the human read position of a project channel.
func (s *Store) Seen(projectID string) (int64, error) {
	dir, err := s.dir(projectID)
	if err != nil {
		return 0, err
	}
	var state readState
	if err := home.ReadJSON(filepath.Join(dir, "state.json"), &state); err != nil && !errors.Is(err, home.ErrNotFound) {
		return 0, err
	}
	return state.Seen, nil
}

// MarkSeen advances the human read position; it never moves backwards.
func (s *Store) MarkSeen(projectID string, seq int64) error {
	dir, err := s.dir(projectID)
	if err != nil {
		return err
	}
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return err
	}
	defer release()
	path := filepath.Join(dir, "state.json")
	var state readState
	if err := home.ReadJSON(path, &state); err != nil && !errors.Is(err, home.ErrNotFound) {
		return err
	}
	if seq <= state.Seen {
		return nil
	}
	state.Seen = seq
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return home.WriteJSON(path, state)
}

func cloneMessage(message model.ChannelMessage) model.ChannelMessage {
	message.To = slices.Clone(message.To)
	message.Files = slices.Clone(message.Files)
	message.Deliveries = slices.Clone(message.Deliveries)
	return message
}

// NormalizeKind maps an empty kind to note and rejects kinds agents and
// humans may not write.
func NormalizeKind(kind string) (string, error) {
	switch kind = strings.TrimSpace(strings.ToLower(kind)); kind {
	case "":
		return model.ChannelKindNote, nil
	case model.ChannelKindNote, model.ChannelKindRequest, model.ChannelKindDone, model.ChannelKindDecision:
		return kind, nil
	}
	return "", fault.New(fault.Invalid, `kind is "note", "request", "done" or "decision"`)
}
