package server

import (
	"cmp"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"slices"
	"sort"
	"sync"
	"time"
	"unicode/utf8"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
)

const (
	// Recently active conversations keep their latest turn in the stream after
	// it ends, for result previews and delivery confirmation.
	recentActivities = 8
	// Bounds of one activity: its latest turn, without payload bodies.
	activityMessages  = 24
	activityTextBytes = 4 << 10
	activityBytes     = 256 << 10
	peerSyncKey       = "peer-sync"
)

// Peer replication diagnostics change without a store write, so the index
// rereads them at this interval.
var localDiagnosticsInterval = 10 * time.Second

// localChanges indexes what only this daemon knows: owner-only details of the
// cards it runs and of its checkouts, the activity of its conversations and
// its peer replication diagnostics. Changes are detected by content, so no
// writer declares what it touched. Change streams bring it current whenever
// the store changes, so every frame's local half matches its records. The
// index lives as long as the process; a restart changes the epoch and
// clients replay it.
type localChanges struct {
	server *Server

	mu       sync.Mutex
	epoch    string
	sequence uint64
	entries  map[string]*localEntry
	advanced chan struct{}

	// Inputs of the last refresh, so unchanged parts are not rebuilt.
	scanned     bool
	metadata    store.StoreRevision
	owned       []model.Card
	checkouts   []model.Checkout
	transcripts map[string]string
	diagnosed   time.Time
}

type localEntry struct {
	sequence uint64
	digest   [sha256.Size]byte
	size     int
	removed  bool
	card     *dieterv1.Card
	checkout *dieterv1.Checkout
	activity *dieterv1.Conversation
	peerSync *dieterv1.PeerSyncStatus
}

type localChange struct {
	key   string
	entry localEntry
}

func newLocalChanges(server *Server) *localChanges {
	return &localChanges{
		server: server, epoch: newLocalEpoch(), entries: map[string]*localEntry{},
		advanced: make(chan struct{}), transcripts: map[string]string{},
	}
}

func newLocalEpoch() string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return "local_" + hex.EncodeToString(raw)
}

// current brings the index up to the store. A writer that died before its
// commit left a pending marker; crossing the writer boundary recovers it
// first, so its changes are counted.
func (l *localChanges) current(ctx context.Context) error {
	if l.server.store.SyncMutationPending() {
		if err := l.server.store.WaitForWriter(ctx); err != nil {
			return err
		}
	}
	return l.refresh(ctx)
}

// refresh rebuilds what may have changed and records every entry whose
// content differs from the index.
func (l *localChanges) refresh(ctx context.Context) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	revision, err := l.server.store.MetadataRevision()
	if err != nil {
		return err
	}
	if !l.scanned || revision != l.metadata {
		owned, err := l.server.store.OwnedCards(ctx)
		if err != nil {
			return err
		}
		checkouts, err := l.server.store.OwnedCheckouts()
		if err != nil {
			return err
		}
		l.owned, l.checkouts, l.metadata, l.scanned = owned, checkouts, revision, true
	}
	next := make(map[string]proto.Message, len(l.owned)*2+len(l.checkouts)+1)
	for _, card := range l.owned {
		next["card/"+card.ID] = protoOwnedCard(card)
	}
	for _, checkout := range l.checkouts {
		next["checkout/"+checkout.ID] = protoCheckout(checkout)
	}
	// A conversation is reread only when its files change. One that cannot be
	// read is skipped until it changes again, so it never stalls the others.
	transcripts := map[string]string{}
	for _, id := range activityCards(l.owned) {
		key := "activity/" + id
		transcript, err := l.server.store.ConversationRevisionByID(id)
		if err != nil {
			continue
		}
		transcripts[id] = transcript
		if read, ok := l.transcripts[id]; ok && read == transcript {
			if entry := l.entries[key]; entry != nil && !entry.removed {
				next[key] = entry.activity
			}
			continue
		}
		conversation, err := l.server.store.ActivityConversation(id, activityMessages)
		if err != nil {
			if !errors.Is(err, store.ErrNotFound) && !errors.Is(err, os.ErrNotExist) {
				l.server.log.Warn("conversation activity unavailable", "card", id, "error", err)
			}
			continue
		}
		next[key] = protoActivity(conversation)
	}
	if entry := l.entries[peerSyncKey]; entry == nil || time.Since(l.diagnosed) >= localDiagnosticsInterval {
		status, err := l.server.peerSyncStatus()
		if err != nil {
			return err
		}
		next[peerSyncKey] = status
		l.diagnosed = time.Now()
	} else if !entry.removed {
		next[peerSyncKey] = entry.peerSync
	}
	if err := l.apply(next); err != nil {
		return err
	}
	l.transcripts = transcripts
	return nil
}

// apply must hold mu. Every changed or removed key gets the next sequence.
func (l *localChanges) apply(next map[string]proto.Message) error {
	changed := false
	keys := make([]string, 0, len(next))
	for key := range next {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(next[key])
		if err != nil {
			return err
		}
		digest := sha256.Sum256(raw)
		if entry := l.entries[key]; entry != nil && !entry.removed && entry.digest == digest {
			continue
		}
		l.sequence++
		entry := &localEntry{sequence: l.sequence, digest: digest, size: len(raw)}
		switch value := next[key].(type) {
		case *dieterv1.Card:
			entry.card = value
		case *dieterv1.Checkout:
			entry.checkout = value
		case *dieterv1.Conversation:
			entry.activity = value
		case *dieterv1.PeerSyncStatus:
			entry.peerSync = value
		}
		l.entries[key] = entry
		changed = true
	}
	for key, entry := range l.entries {
		if _, ok := next[key]; !ok && !entry.removed {
			l.sequence++
			l.entries[key] = &localEntry{sequence: l.sequence, size: len(key), removed: true}
			changed = true
		}
	}
	if changed {
		close(l.advanced)
		l.advanced = make(chan struct{})
	}
	return nil
}

// since returns the entries changed after a cursor, oldest first: at most
// limit of them within budget bytes, though always the first when alone is
// set. A cursor from another epoch resets to the beginning, where removals are
// not needed.
func (l *localChanges) since(epoch string, after uint64, limit, budget int, alone bool) (changes []localChange, current string, next uint64, reset, more bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if epoch != l.epoch || after > l.sequence {
		after, reset = 0, true
	}
	var pending []localChange
	for key, entry := range l.entries {
		if entry.sequence > after && !(after == 0 && entry.removed) {
			pending = append(pending, localChange{key, *entry})
		}
	}
	slices.SortFunc(pending, func(a, b localChange) int { return cmp.Compare(a.entry.sequence, b.entry.sequence) })
	size := 0
	for _, change := range pending {
		fits := len(changes) < limit && size+change.entry.size <= budget
		if !fits && !(alone && len(changes) == 0) {
			more = true
			break
		}
		changes = append(changes, change)
		size += change.entry.size
	}
	next = l.sequence
	if more {
		next = after
		if len(changes) > 0 {
			next = changes[len(changes)-1].entry.sequence
		}
	}
	return changes, l.epoch, next, reset, more
}

// changed is closed when the index next advances.
func (l *localChanges) changed() <-chan struct{} {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.advanced
}

// activityCards are the conversations whose latest turn the stream carries:
// every turn in progress and the most recently active others.
func activityCards(owned []model.Card) []string {
	recent := make([]model.Card, 0, len(owned))
	var ids []string
	for _, card := range owned {
		if model.RuntimeHoldsTurn(card.Runtime) {
			ids = append(ids, card.ID)
		} else if card.InitialPromptSentAt != "" {
			recent = append(recent, card)
		}
	}
	sort.SliceStable(recent, func(i, j int) bool {
		if recent[i].LastActivityAt != recent[j].LastActivityAt {
			return recent[i].LastActivityAt > recent[j].LastActivityAt
		}
		return recent[i].ID < recent[j].ID
	})
	for index := 0; index < len(recent) && index < recentActivities; index++ {
		ids = append(ids, recent[index].ID)
	}
	return ids
}

// protoOwnedCard keeps only what the owner alone knows; shared fields come
// from the peer records.
func protoOwnedCard(card model.Card) *dieterv1.Card {
	full := protoCard(card)
	return &dieterv1.Card{
		Id: full.Id, OwnerDaemonId: full.OwnerDaemonId, CheckoutId: full.CheckoutId,
		InitialPrompt: full.InitialPrompt, Summary: full.Summary, Origin: full.Origin,
		ProviderOptions: full.ProviderOptions, ProviderAccountKey: full.ProviderAccountKey,
		WorkspaceMode: full.WorkspaceMode, WorkspaceBranch: full.WorkspaceBranch, WorkspaceBaseBranch: full.WorkspaceBaseBranch,
		WorkspaceBaseRemote: full.WorkspaceBaseRemote, RemotePublishMode: full.RemotePublishMode,
		Workspace: full.Workspace, PullRequest: full.PullRequest, TokenUsage: full.TokenUsage, UpdatedAt: full.UpdatedAt,
	}
}

// protoActivity is the latest turn without payload bodies: tool calls keep
// their name, state and preview, text keeps a bounded prefix.
func protoActivity(conversation model.Conversation) *dieterv1.Conversation {
	value := protoConversation(conversation)
	value.DraftAttachments = nil
	value.PresentedContent = nil
	for _, message := range value.Messages {
		for _, part := range message.Parts {
			stripPayload(part)
		}
	}
	for _, queued := range value.Queue {
		queued.Text = boundedText(queued.Text)
		for _, part := range queued.Parts {
			stripPayload(part)
		}
	}
	for _, tool := range value.PendingTools {
		tool.InputJson = nil
	}
	plans := value.TaskPlans[:0]
	for _, plan := range value.TaskPlans {
		if plan.GetState() == "active" {
			plans = append(plans, plan)
		}
	}
	value.TaskPlans = plans
	for proto.Size(value) > activityBytes && len(value.Messages) > 1 {
		value.Messages = value.Messages[1:]
	}
	return value
}

func stripPayload(part *dieterv1.MessagePart) {
	part.InputJson, part.OutputJson, part.Data = nil, nil, nil
	part.Url = ""
	part.Text = boundedText(part.Text)
}

func boundedText(text string) string {
	if len(text) <= activityTextBytes {
		return text
	}
	cut := activityTextBytes
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut]
}

func (s *Server) peerSyncStatus() (*dieterv1.PeerSyncStatus, error) {
	status := &dieterv1.PeerSyncStatus{}
	identity, err := s.store.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return status, nil
	}
	if err != nil {
		return nil, err
	}
	diagnostics, err := s.store.PeerSyncDiagnostics(identity.Account)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	for _, value := range diagnostics {
		if value.IsCurrentIssue(now) {
			status.Issues = append(status.Issues, protoPeerDiagnostic(value))
		}
	}
	return status, nil
}
