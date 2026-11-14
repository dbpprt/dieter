// Package mail stores the agent mail of one daemon. Each message is a small
// JSON record (mail/<id>.json: header, read, flag and folder state, sender
// and the key of its send) beside its Markdown body (mail/<id>.md). Sending
// writes the body, then the record; state changes rewrite only the record.
// Every mutation runs under the central writer lock, writes atomically and
// wakes change subscribers when it commits.
//
// An in-memory index of the records serves lists and the change stream. It
// loads lazily and reloads when another process changed the directory.
// Bodies without a record (a send interrupted between its two writes) and
// Trash older than model.MailTrashRetention are removed under the writer
// lock, when the index loads and on every mutation; nothing runs in the
// background.
package mail

import (
	"cmp"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store/home"
)

// timeLayout is RFC 3339 in UTC with fixed-width milliseconds, so stored
// times also sort as text.
const timeLayout = "2006-01-02T15:04:05.000Z07:00"

var validID = regexp.MustCompile(`^ml_[A-Za-z0-9_-]{1,64}$`)

var (
	// ErrNotFound reports a message ID this daemon does not hold.
	ErrNotFound = fault.New(fault.NotFound, "mail not found")
	// ErrFull reports a send that no prunable message makes room for: every
	// message left is unread or flagged.
	ErrFull = fault.New(fault.ResourceExhausted, "the mailbox on this machine is full")
)

// Store bounds; tests lower them.
var (
	maxMessages   = model.MailMaxMessages
	maxBodyBytes  = int64(model.MailMaxStoredBodies)
	trashLifetime = model.MailTrashRetention
)

// Store is the mail aggregate of one DIETER_HOME.
type Store struct {
	home *home.Dir
	now  func() time.Time

	mu       sync.Mutex
	loaded   bool
	stamp    time.Time // directory modification time the index reflects
	records  map[string]*record
	orphans  []string
	bodies   int64
	revision uint64
	sorted   []*record // newest first; nil when records changed
}

// New returns the mail aggregate of dir.
func New(dir *home.Dir) *Store {
	return &Store{home: dir, now: time.Now, records: map[string]*record{}}
}

// record is the stored form of one message.
type record struct {
	model.MailHeader
	// OperationID is the retry key of the send, scoped by its origin.
	OperationID string `json:"operationId,omitempty"`

	sent time.Time
}

// origin scopes operation IDs: an agent's conversation, an operator's
// device, or the local operator.
func origin(sender model.MailSender) string {
	switch {
	case sender.Kind == model.MailSenderAgent:
		return "card:" + sender.CardID
	case sender.DeviceID != "":
		return "device:" + sender.DeviceID
	}
	return "local"
}

// trashedAt is when a message in the Trash was moved there.
func (r *record) trashedAt() time.Time {
	if at, err := time.Parse(time.RFC3339Nano, r.StateChangedAt); err == nil {
		return at
	}
	return r.sent
}

func (s *Store) dir() string { return filepath.Join(s.home.Root, "mail") }

func (s *Store) recordPath(id string) string { return filepath.Join(s.dir(), id+".json") }

func (s *Store) bodyPath(id string) string { return filepath.Join(s.dir(), id+".md") }

// Draft is a message to send.
type Draft struct {
	Sender      model.MailSender
	Subject     string
	Body        string
	Important   bool
	OperationID string
	// SentAt backdates a seeded message; zero is now.
	SentAt time.Time
}

// Change is a state change; nil and empty fields stay unchanged.
type Change struct {
	Read, Flagged *bool
	Folder        string
}

// Filter selects a page of messages, newest first.
type Filter struct {
	// Folder is inbox, archive or trash; empty lists every folder.
	Folder          string
	Unread, Flagged bool
	// BeforeID continues after this message (exclusive).
	BeforeID string
	// Limit defaults to model.MailDefaultPageSize, at most
	// model.MailMaxPageSize.
	Limit int
}

// Send stores a message in the Inbox, unread. A repeated operation ID from
// the same origin returns the original message and false. Agents are bound
// per turn and per conversation over model.MailConversationWindow; the bounds
// count stored messages. When the store is full, the Trash, then archived
// read messages, then read Inbox messages make room, oldest first; unread and
// flagged messages outside the Trash are never pruned.
func (s *Store) Send(draft Draft) (model.MailHeader, bool, error) {
	subject, err := model.NormalizeMailSubject(draft.Subject)
	if err != nil {
		return model.MailHeader{}, false, err
	}
	body, err := model.NormalizeMailBody(draft.Body)
	if err != nil {
		return model.MailHeader{}, false, err
	}
	if err := model.ValidateMailOperationID(draft.OperationID); err != nil {
		return model.MailHeader{}, false, err
	}
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return model.MailHeader{}, false, err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	defer s.restampLocked()
	now := s.now().UTC()
	if err := s.writableLocked(now); err != nil {
		return model.MailHeader{}, false, err
	}
	if draft.OperationID != "" {
		key := origin(draft.Sender)
		for _, existing := range s.records {
			if existing.OperationID == draft.OperationID && origin(existing.Sender) == key {
				return existing.MailHeader, false, nil
			}
		}
	}
	if err := s.admitLocked(draft.Sender, now); err != nil {
		return model.MailHeader{}, false, err
	}
	if err := s.makeRoomLocked(int64(len(body))); err != nil {
		return model.MailHeader{}, false, err
	}
	sent := now
	if !draft.SentAt.IsZero() {
		sent = draft.SentAt.UTC()
	}
	importance := model.MailImportanceNormal
	if draft.Important {
		importance = model.MailImportanceHigh
	}
	digest := sha256.Sum256([]byte(body))
	stored := &record{MailHeader: model.MailHeader{
		ID: home.NewID("ml_"), Sender: draft.Sender, Subject: subject, Preview: model.MailPreview(body),
		Importance: importance, SentAt: sent.Format(timeLayout), BodyBytes: len(body),
		BodyDigest: hex.EncodeToString(digest[:]), Folder: model.MailFolderInbox,
	}, OperationID: draft.OperationID, sent: sent}
	if err := fsx.WriteFile(s.bodyPath(stored.ID), []byte(body), 0o600); err != nil {
		return model.MailHeader{}, false, err
	}
	if err := home.WriteJSON(s.recordPath(stored.ID), stored); err != nil {
		_ = os.Remove(s.bodyPath(stored.ID))
		return model.MailHeader{}, false, err
	}
	s.records[stored.ID] = stored
	s.bodies += int64(stored.BodyBytes)
	s.changedLocked()
	return stored.MailHeader, true, nil
}

// admitLocked applies the per-turn and per-conversation bounds of agents.
func (s *Store) admitLocked(sender model.MailSender, now time.Time) error {
	if sender.Kind != model.MailSenderAgent {
		return nil
	}
	turn, recent := 0, 0
	since := now.Add(-model.MailConversationWindow)
	for _, existing := range s.records {
		if existing.Sender.Kind != model.MailSenderAgent || existing.Sender.CardID != sender.CardID {
			continue
		}
		if sender.TurnID != "" && existing.Sender.TurnID == sender.TurnID {
			turn++
		}
		if existing.sent.After(since) {
			recent++
		}
	}
	if turn >= model.MailMaxPerTurn {
		return fault.Errorf(fault.ResourceExhausted, "this turn already sent %d messages, the most one turn may send; put the rest in one report", model.MailMaxPerTurn)
	}
	if recent >= model.MailMaxPerConversation {
		return fault.Errorf(fault.ResourceExhausted, "this conversation already sent %d messages in the last 24 hours, the most it may send; tell the user in this conversation instead", model.MailMaxPerConversation)
	}
	return nil
}

// makeRoomLocked prunes until a body of size bytes fits, or fails with
// ErrFull and prunes nothing.
func (s *Store) makeRoomLocked(size int64) error {
	count, bytes := len(s.records)+1, s.bodies+size
	if count <= maxMessages && bytes <= maxBodyBytes {
		return nil
	}
	var trash, archived, inbox []*record
	for _, existing := range s.records {
		switch {
		case existing.Folder == model.MailFolderTrash:
			trash = append(trash, existing)
		case !existing.Read || existing.Flagged:
		case existing.Folder == model.MailFolderArchive:
			archived = append(archived, existing)
		default:
			inbox = append(inbox, existing)
		}
	}
	slices.SortFunc(trash, func(a, b *record) int {
		return cmp.Or(a.trashedAt().Compare(b.trashedAt()), a.sent.Compare(b.sent), cmp.Compare(a.ID, b.ID))
	})
	oldest := func(a, b *record) int { return cmp.Or(a.sent.Compare(b.sent), cmp.Compare(a.ID, b.ID)) }
	slices.SortFunc(archived, oldest)
	slices.SortFunc(inbox, oldest)
	var prune []string
	for _, candidate := range slices.Concat(trash, archived, inbox) {
		if count <= maxMessages && bytes <= maxBodyBytes {
			break
		}
		prune = append(prune, candidate.ID)
		count--
		bytes -= int64(candidate.BodyBytes)
	}
	if count > maxMessages || bytes > maxBodyBytes {
		return ErrFull
	}
	return s.removeLocked(prune)
}

// removeLocked deletes messages: the record first, so an interrupted delete
// leaves only an orphan body for the next load to clean.
func (s *Store) removeLocked(ids []string) error {
	for _, id := range ids {
		existing := s.records[id]
		if existing == nil {
			continue
		}
		if err := os.Remove(s.recordPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		delete(s.records, id)
		s.bodies -= int64(existing.BodyBytes)
		s.changedLocked()
		if err := os.Remove(s.bodyPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			s.orphans = append(s.orphans, id)
		}
	}
	return nil
}

func (s *Store) changedLocked() {
	s.revision++
	s.sorted = nil
}

// loadLocked brings the index up to the directory. It never deletes; orphan
// bodies are remembered for purgeLocked.
func (s *Store) loadLocked() error {
	info, err := os.Stat(s.dir())
	if errors.Is(err, os.ErrNotExist) {
		if !s.loaded || len(s.records) > 0 || len(s.orphans) > 0 {
			s.records, s.orphans, s.bodies = map[string]*record{}, nil, 0
			s.changedLocked()
		}
		s.loaded, s.stamp = true, time.Time{}
		return nil
	}
	if err != nil {
		return err
	}
	if s.loaded && info.ModTime().Equal(s.stamp) {
		return nil
	}
	entries, err := os.ReadDir(s.dir())
	if err != nil {
		return err
	}
	records, bodies := map[string]*record{}, map[string]bool{}
	var total int64
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() {
			continue
		}
		if id, ok := strings.CutSuffix(name, ".md"); ok && validID.MatchString(id) {
			bodies[id] = true
			continue
		}
		id, ok := strings.CutSuffix(name, ".json")
		if !ok || !validID.MatchString(id) {
			continue
		}
		var stored record
		// A record another process removed meanwhile, or one that does not
		// parse, is not part of the mailbox.
		if home.ReadJSON(filepath.Join(s.dir(), name), &stored) != nil || stored.ID != id {
			continue
		}
		if stored.sent, err = time.Parse(time.RFC3339Nano, stored.SentAt); err != nil {
			continue
		}
		if !model.ValidMailFolder(stored.Folder) {
			stored.Folder = model.MailFolderInbox
		}
		records[id] = &stored
		total += int64(stored.BodyBytes)
	}
	var orphans []string
	for id := range bodies {
		if records[id] == nil {
			orphans = append(orphans, id)
		}
	}
	s.records, s.orphans, s.bodies = records, orphans, total
	s.loaded, s.stamp = true, info.ModTime()
	s.changedLocked()
	return nil
}

// restampLocked records that the index reflects this process's own writes.
// Callers hold the writer lock, so no other process changed the directory.
func (s *Store) restampLocked() {
	if info, err := os.Stat(s.dir()); err == nil {
		s.stamp = info.ModTime()
	}
}

// purgeDueLocked reports whether orphan bodies or expired Trash wait.
func (s *Store) purgeDueLocked(now time.Time) bool {
	if len(s.orphans) > 0 {
		return true
	}
	for _, existing := range s.records {
		if existing.Folder == model.MailFolderTrash && now.Sub(existing.trashedAt()) >= trashLifetime {
			return true
		}
	}
	return false
}

// purgeLocked removes orphan bodies and expired Trash. Callers hold the
// writer lock: a body whose record exists by now belonged to a send that
// completed meanwhile.
func (s *Store) purgeLocked(now time.Time) error {
	for _, id := range s.orphans {
		if _, err := os.Stat(s.recordPath(id)); errors.Is(err, os.ErrNotExist) {
			if err := os.Remove(s.bodyPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	s.orphans = nil
	var expired []string
	for id, existing := range s.records {
		if existing.Folder == model.MailFolderTrash && now.Sub(existing.trashedAt()) >= trashLifetime {
			expired = append(expired, id)
		}
	}
	return s.removeLocked(expired)
}

// writableLocked prepares a mutation: the index is current and purged.
// Callers hold the writer lock and s.mu, and restamp after writing.
func (s *Store) writableLocked(now time.Time) error {
	if err := s.loadLocked(); err != nil {
		return err
	}
	return s.purgeLocked(now)
}

// current loads the index for a read. A load that found orphan bodies or
// expired Trash cleans them under the writer lock first.
func (s *Store) current() error {
	s.mu.Lock()
	err := s.loadLocked()
	due := err == nil && s.purgeDueLocked(s.now())
	s.mu.Unlock()
	if err != nil || !due {
		return err
	}
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	defer s.restampLocked()
	return s.writableLocked(s.now())
}

// sortedLocked lists every message newest first, ties by ID.
func (s *Store) sortedLocked() []*record {
	if s.sorted == nil {
		s.sorted = make([]*record, 0, len(s.records))
		for _, existing := range s.records {
			s.sorted = append(s.sorted, existing)
		}
		slices.SortFunc(s.sorted, func(a, b *record) int {
			return cmp.Or(b.sent.Compare(a.sent), cmp.Compare(b.ID, a.ID))
		})
	}
	return s.sorted
}

// Revision changes whenever the messages or their state change.
func (s *Store) Revision() (uint64, error) {
	if err := s.current(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.revision, nil
}

// Headers returns every message newest first, with the revision they match.
func (s *Store) Headers() ([]model.MailHeader, uint64, error) {
	if err := s.current(); err != nil {
		return nil, 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sorted := s.sortedLocked()
	headers := make([]model.MailHeader, len(sorted))
	for index, existing := range sorted {
		headers[index] = existing.MailHeader
	}
	return headers, s.revision, nil
}

// List returns a page of messages, newest first, and whether more follow.
func (s *Store) List(filter Filter) ([]model.MailHeader, bool, error) {
	if filter.Folder != "" && !model.ValidMailFolder(filter.Folder) {
		return nil, false, fault.New(fault.Invalid, "the folder is inbox, archive or trash")
	}
	if filter.Limit < 0 {
		return nil, false, fault.New(fault.Invalid, "the limit cannot be negative")
	}
	limit := filter.Limit
	if limit == 0 {
		limit = model.MailDefaultPageSize
	}
	limit = min(limit, model.MailMaxPageSize)
	if err := s.current(); err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sorted := s.sortedLocked()
	start := 0
	if filter.BeforeID != "" {
		at := slices.IndexFunc(sorted, func(existing *record) bool { return existing.ID == filter.BeforeID })
		if at < 0 {
			return nil, false, ErrNotFound
		}
		start = at + 1
	}
	var page []model.MailHeader
	for _, existing := range sorted[start:] {
		if filter.Folder != "" && existing.Folder != filter.Folder || filter.Unread && existing.Read || filter.Flagged && !existing.Flagged {
			continue
		}
		if len(page) == limit {
			return page, true, nil
		}
		page = append(page, existing.MailHeader)
	}
	return page, false, nil
}

// Get returns one message with its Markdown body.
func (s *Store) Get(id string) (model.MailHeader, string, error) {
	if !validID.MatchString(id) {
		return model.MailHeader{}, "", ErrNotFound
	}
	if err := s.current(); err != nil {
		return model.MailHeader{}, "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	existing := s.records[id]
	if existing == nil {
		return model.MailHeader{}, "", ErrNotFound
	}
	body, err := os.ReadFile(s.bodyPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return model.MailHeader{}, "", ErrNotFound
	}
	if err != nil {
		return model.MailHeader{}, "", err
	}
	return existing.MailHeader, string(body), nil
}

func validIDs(ids []string) error {
	if len(ids) > model.MailMaxIDsPerCall {
		return fault.Invalidf("at most %d message IDs per call", model.MailMaxIDsPerCall)
	}
	return nil
}

// Update changes the state of messages and returns those it found, in the
// order of ids. Unknown IDs are skipped, so a retried batch applies the
// rest; only messages whose state changes are rewritten.
func (s *Store) Update(ids []string, change Change) ([]model.MailHeader, error) {
	if len(ids) == 0 {
		return nil, fault.New(fault.Invalid, "at least one message ID is required")
	}
	if err := validIDs(ids); err != nil {
		return nil, err
	}
	if change.Read == nil && change.Flagged == nil && change.Folder == "" {
		return nil, fault.New(fault.Invalid, "nothing to change: set read, flagged or a folder")
	}
	if change.Folder != "" && !model.ValidMailFolder(change.Folder) {
		return nil, fault.New(fault.Invalid, "the folder is inbox, archive or trash")
	}
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return nil, err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	defer s.restampLocked()
	now := s.now().UTC()
	if err := s.writableLocked(now); err != nil {
		return nil, err
	}
	var updated []model.MailHeader
	seen := map[string]bool{}
	for _, id := range ids {
		existing := s.records[id]
		if existing == nil || seen[id] {
			continue
		}
		seen[id] = true
		next := *existing
		if change.Read != nil {
			next.Read = *change.Read
		}
		if change.Flagged != nil {
			next.Flagged = *change.Flagged
		}
		if change.Folder != "" {
			next.Folder = change.Folder
		}
		if next.Read != existing.Read || next.Flagged != existing.Flagged || next.Folder != existing.Folder {
			next.StateChangedAt = now.Format(timeLayout)
			if err := home.WriteJSON(s.recordPath(id), &next); err != nil {
				return nil, err
			}
			*existing = next
			s.changedLocked()
		}
		updated = append(updated, existing.MailHeader)
	}
	return updated, nil
}

// Delete removes messages for good, or every message in the Trash with
// emptyTrash, and returns the IDs it removed. Unknown IDs are skipped.
func (s *Store) Delete(ids []string, emptyTrash bool) ([]string, error) {
	if (len(ids) == 0) == !emptyTrash {
		return nil, fault.New(fault.Invalid, "name message IDs or empty the Trash")
	}
	if err := validIDs(ids); err != nil {
		return nil, err
	}
	release, err := s.home.BeginWriteKind(home.ConversationChange)
	if err != nil {
		return nil, err
	}
	defer release()
	s.mu.Lock()
	defer s.mu.Unlock()
	defer s.restampLocked()
	if err := s.writableLocked(s.now().UTC()); err != nil {
		return nil, err
	}
	var deleted []string
	if emptyTrash {
		for _, existing := range s.sortedLocked() {
			if existing.Folder == model.MailFolderTrash {
				deleted = append(deleted, existing.ID)
			}
		}
	} else {
		for _, id := range ids {
			if s.records[id] != nil && !slices.Contains(deleted, id) {
				deleted = append(deleted, id)
			}
		}
	}
	return deleted, s.removeLocked(deleted)
}
