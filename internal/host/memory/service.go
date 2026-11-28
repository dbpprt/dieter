// Package memory runs agent memory on a daemon (docs/adr/0007-agent-memory.md):
// it indexes the finished turns of memory-enabled conversations this daemon
// owns into the machine-local index, answers recall across the account's
// daemons, saves curated memories as replicated records, and schedules and
// applies dreams. Background work starts only with Run (dieter serve).
package memory

import (
	"context"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/memory/embed"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	storememory "github.com/dbpprt/dieter/internal/store/memory"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

// Background bounds.
const (
	queueSize          = 1024
	reconcileInterval  = 2 * time.Minute
	maintenanceEvery   = time.Hour
	dreamCheckInterval = 5 * time.Minute
	indexBatch         = 32
)

// Dialer reaches another daemon of the account over the roster-pinned peer
// carriers (direct, WebRTC or relay); nil when the daemon is not enrolled.
type Dialer func(ctx context.Context, daemonID string) (dieterclient.Client, func(), error)

// Options configure the memory service.
type Options struct {
	Store *store.Store
	App   *engine.Service
	Log   *slog.Logger
	// Name is this machine's enrolled name.
	Name string
	// Dial reaches peer daemons for recall across machines.
	Dial Dialer
	// DreamCheckInterval overrides how often dream gates are checked (tests).
	DreamCheckInterval time.Duration
	// Now overrides the clock (tests).
	Now func() time.Time
	// Embedder computes recall's text vectors; nil uses the built-in model,
	// loaded on first use and released when idle.
	Embedder *embed.Shared
}

// Service is a daemon's agent memory.
type Service struct {
	store *store.Store
	app   *engine.Service
	log   *slog.Logger
	name  string
	dial  Dialer
	index *storememory.Index
	now   func() time.Time
	embed *embed.Shared

	dreamInterval time.Duration

	mu      sync.Mutex
	pending map[string]bool
	queue   chan string
	dreamMu sync.Mutex
}

// New builds the memory service. It starts nothing; see Run.
func New(options Options) *Service {
	logger := options.Log
	if logger == nil {
		logger = slog.Default()
	}
	now := options.Now
	if now == nil {
		now = time.Now
	}
	name := options.Name
	if name == "" {
		name, _ = os.Hostname()
	}
	interval := options.DreamCheckInterval
	if interval <= 0 {
		interval = dreamCheckInterval
	}
	embedder := options.Embedder
	if embedder == nil {
		embedder = embed.NewShared(0)
	}
	return &Service{
		store: options.Store, app: options.App, log: logger, name: name, dial: options.Dial,
		index: storememory.New(options.Store.Root), now: now, dreamInterval: interval, embed: embedder,
		pending: map[string]bool{}, queue: make(chan string, queueSize),
	}
}

// Index is the machine-local index (tests).
func (s *Service) Index() *storememory.Index { return s.index }

// SetDialer sets how peer daemons are reached (after enrollment).
func (s *Service) SetDialer(dial Dialer) { s.dial = dial }

// Run indexes, reconciles, maintains and dreams until ctx ends.
func (s *Service) Run(ctx context.Context) {
	defer s.index.Close()
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		s.runIndexer(ctx)
	}()
	s.reconcile()
	reconcile := time.NewTicker(reconcileInterval)
	maintenance := time.NewTicker(maintenanceEvery)
	dreams := time.NewTicker(s.dreamInterval)
	defer reconcile.Stop()
	defer maintenance.Stop()
	defer dreams.Stop()
	for {
		select {
		case <-ctx.Done():
			workers.Wait()
			return
		case <-reconcile.C:
			s.reconcile()
		case <-maintenance.C:
			s.maintain()
		case <-dreams.C:
			s.checkDreams(ctx)
		}
	}
}

// TurnFinished queues a conversation for indexing. It never blocks: a full
// queue is caught up by the next reconciliation.
func (s *Service) TurnFinished(cardID string) {
	s.enqueue(cardID)
	s.dreamTurnFinished(cardID)
}

func (s *Service) enqueue(cardID string) {
	s.mu.Lock()
	if s.pending[cardID] {
		s.mu.Unlock()
		return
	}
	s.pending[cardID] = true
	s.mu.Unlock()
	select {
	case s.queue <- cardID:
	default:
		s.mu.Lock()
		delete(s.pending, cardID)
		s.mu.Unlock()
	}
}

func (s *Service) backlog() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.pending)
}

func (s *Service) runIndexer(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case cardID := <-s.queue:
			s.mu.Lock()
			delete(s.pending, cardID)
			s.mu.Unlock()
			if err := s.indexCard(cardID); err != nil {
				s.log.Warn("agent memory could not index a conversation", "card", cardID, "error", err)
			}
		}
	}
}

// IndexNow indexes one conversation synchronously (tests and reindex).
func (s *Service) IndexNow(cardID string) error { return s.indexCard(cardID) }

func (s *Service) indexCard(cardID string) error {
	card, err := s.store.Kanban.ResolveCard(cardID)
	if err != nil {
		return err
	}
	if err = s.store.Kanban.RequireLocalCard(card); err != nil {
		return nil
	}
	project, err := s.store.Kanban.ResolveProject(card.ProjectID)
	if err != nil {
		return err
	}
	if !engine.MemoryActive(project, card, s.adapterRuntime(card.Provider)) || card.MemoryRole == engine.MemoryRoleDreamer {
		// A dream quotes every saved memory; indexing it would make it the
		// best match for everything.
		return nil
	}
	conversation, err := s.store.Conversations.Get(card.ID)
	if err != nil {
		return err
	}
	// A conversation without vectors (indexed before embeddings, or by
	// another model) is reindexed in full so all its texts are embedded.
	embedded, err := s.index.HasVectors(card.ID)
	if err != nil {
		return err
	}
	result, err := s.index.IndexCard(indexCard(card), conversation.Messages, !embedded)
	if err != nil {
		return err
	}
	s.embedTexts(card.ID, card.ProjectID, result.Texts)
	return nil
}

// embedTexts stores the vectors of a conversation's new or changed texts. A
// failure only costs semantic recall; keyword recall is already indexed.
func (s *Service) embedTexts(cardID, projectID string, texts []storememory.Text) {
	missing, err := s.index.MissingVectors(cardID, texts)
	if err != nil || len(missing) == 0 {
		return
	}
	bodies := make([]string, len(missing))
	for i, text := range missing {
		bodies[i] = text.Body
	}
	vectors, err := s.embed.Embed(bodies...)
	if err == nil {
		err = s.index.PutVectors(cardID, projectID, missing, vectors)
	}
	if err != nil {
		s.log.Warn("agent memory could not embed a conversation", "card", cardID, "error", err)
	}
}

// queryVector embeds a recall query; nil (keyword recall only) when the
// model cannot run.
func (s *Service) queryVector(query string) []float32 {
	vectors, err := s.embed.Embed(query)
	if err != nil {
		s.log.Warn("agent memory could not embed a query", "error", err)
		return nil
	}
	return vectors[0]
}

func indexCard(card model.Card) storememory.Card {
	return storememory.Card{
		ID: card.ID, Project: card.ProjectID, Title: card.Title, Lane: card.Lane, Harness: card.Provider,
		Scope: card.Scope, LastActivityAt: card.LastActivityAt, Brief: card.InitialPrompt, Archived: card.Archived,
	}
}

// cliWord is how agent turns invoke this daemon's CLI.
func (s *Service) cliWord() string {
	if s.app != nil {
		return s.app.CLIWord()
	}
	return "dieter"
}

func (s *Service) adapterRuntime(provider string) string {
	if s.app != nil && s.app.Catalog != nil {
		for _, adapter := range s.app.Catalog.Adapters() {
			if adapter.ID == provider {
				return adapter.Runtime
			}
		}
	}
	return provider
}

// reconcile brings the index up to date with the conversations this daemon
// owns: it queues memory-enabled conversations with activity the index has
// not seen, refreshes titles and lanes, and drops conversations that were
// deleted or whose project turned memory off.
func (s *Service) reconcile() {
	projects, err := s.store.Kanban.ListProjects()
	if err != nil {
		return
	}
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return
	}
	for _, project := range projects {
		indexed, _ := s.index.Cards(project.ID)
		if !project.MemoryEnabled {
			continue
		}
		known := map[string]storememory.IndexedCard{}
		for _, card := range indexed {
			known[card.ID] = card
		}
		embedded, _ := s.index.CardsWithVectors(project.ID)
		cards, err := s.store.Kanban.ListCards(kanban.CardFilter{Project: project.ID, IncludeArchived: true})
		if err != nil {
			continue
		}
		present := map[string]bool{}
		for _, card := range cards {
			if card.OwnerDaemonID != identity.DaemonID {
				continue
			}
			present[card.ID] = true
			entry, ok := known[card.ID]
			if card.MemoryRole == engine.MemoryRoleDreamer {
				if ok {
					_ = s.index.ForgetCard(card.ID)
				}
				continue
			}
			if !engine.MemoryActive(project, card, s.adapterRuntime(card.Provider)) || card.Runtime == "running" {
				continue
			}
			switch {
			case !ok:
				if !s.index.Exists() && !hasTranscript(card) {
					continue
				}
				s.enqueue(card.ID)
			case later(card.LastActivityAt, entry.LastActivityAt), card.Title != entry.Title:
				s.enqueue(card.ID)
			case !embedded[card.ID] && s.embed.Usable():
				// Indexed before embeddings, or by another model.
				s.enqueue(card.ID)
			case card.Lane != entry.Lane || card.Archived != entry.Archived:
				_ = s.index.UpdateCard(indexCard(card))
			}
		}
		for id := range known {
			if !present[id] {
				if _, err := s.store.Kanban.ResolveCard(id); err != nil {
					_ = s.index.ForgetCard(id)
				}
			}
		}
	}
}

// later reports whether RFC 3339 timestamp a is after b; an empty b is
// before everything. RFC3339Nano drops trailing zeros, so the strings do not
// sort.
func later(a, b string) bool {
	if b == "" {
		return a != ""
	}
	left, leftErr := time.Parse(time.RFC3339Nano, a)
	right, rightErr := time.Parse(time.RFC3339Nano, b)
	if leftErr != nil || rightErr != nil {
		return a > b
	}
	return left.After(right)
}

func hasTranscript(card model.Card) bool {
	return card.InitialPromptSentAt != "" || card.LastActivityAt != card.CreatedAt
}

// maintain applies the index bounds and expires this daemon's saved
// memories whose time has come.
func (s *Service) maintain() {
	if removed, err := s.index.Enforce(); err == nil && removed > 0 {
		s.log.Info("agent memory evicted old observations", "count", removed)
	}
	s.expireMemories()
}
