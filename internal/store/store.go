// Package store is the composition root of the central DIETER_HOME storage.
// Each aggregate lives in a subpackage and imports only the aggregates named
// in its parentheses, all listed above it, so the graph stays acyclic
// (.golangci.yml enforces it with depguard):
//
//	home           DIETER_HOME paths, writer lock and admission, storage schema,
//	               change counter and notifications, SQLite opener, file helpers
//	replica        the account's peer replica: identity and binding, record
//	               database, views, WAL effects, merge, order keys (home)
//	leases         runtime turn leases (home)
//	kv             replicated client key-value records (home, replica)
//	settings       settings.yaml (home)
//	commands       idempotent command results (home)
//	channels       agent channel messages, deliveries and read state (home)
//	mail           agent mail: message records, bodies and their state (home)
//	kanban         the shared work directory: projects, checkouts, boards,
//	               labels, cards and chats, turn admission (home, replica, leases)
//	workspaces     workspaces, Git operations, pull requests, change comments
//	               (home, kanban, leases)
//	conversations  transcripts, journals, checkpoints, and the operations that
//	               span a conversation and its card (home, replica, kanban, leases)
//	schedules      schedules.db, occurrences, and the shared schedule outbox
//	               (home, replica, kanban)
//
// New wires the hooks through which a lower aggregate reaches a higher one:
// the writer flushes the schedule outbox before each change commits and
// conversation checkpoints after it releases the lock; the replica validates
// peer writes and adopts checkout records through kanban and schedule owners
// through schedules; kanban reads workspace, pull request, token usage and
// schedule summaries and calls Ensure. Ensure, Recover, RecoverEvery and Close
// act on the composed store. The vaults and daemonstate packages build on the
// composed store.
package store

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/dbpprt/dieter/internal/store/channels"
	"github.com/dbpprt/dieter/internal/store/commands"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/mail"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/store/schedules"
	"github.com/dbpprt/dieter/internal/store/settings"
	"github.com/dbpprt/dieter/internal/store/workspaces"
)

// Store composes the aggregates of one DIETER_HOME. The embedded home.Dir
// carries the root, the writer lock and the change counter that every
// aggregate shares.
type Store struct {
	*home.Dir
	Replica       *replica.Store
	Leases        *leases.Store
	Kanban        *kanban.Store
	Workspaces    *workspaces.Store
	Conversations *conversations.Store
	Schedules     *schedules.Store
	KV            *kv.Store
	Settings      *settings.Store
	Commands      *commands.Store
	Channels      *channels.Store
	Mail          *mail.Store
}

// New opens the central store rooted at the absolute DIETER_HOME root. The
// composition root resolves DIETER_HOME; an empty root is a programming error.
func New(root string) *Store {
	dir := home.New(root)
	peers := replica.New(dir)
	turns := leases.New(dir)
	board := kanban.New(dir, peers, turns)
	s := &Store{Dir: dir, Replica: peers, Leases: turns, Kanban: board,
		Workspaces:    workspaces.New(dir, board, turns),
		Conversations: conversations.New(dir, peers, board, turns),
		Schedules:     schedules.New(dir, peers, board),
		KV:            kv.New(dir, peers), Settings: settings.New(dir), Commands: commands.New(dir),
		Channels: channels.New(dir), Mail: mail.New(dir)}
	s.SetHooks(home.Hooks{
		BeforeCommit: func() {
			if err := s.Schedules.FlushOutbox(); err != nil {
				slog.Error("schedule publication deferred to recovery", "error", err)
			}
		},
		AfterRelease: s.Conversations.FlushCheckpoints,
	})
	s.Replica.SetHooks(replica.Hooks{
		ValidateWrite: s.Kanban.ValidatePeerWrite,
		AdoptRecord:   s.Kanban.AdoptOwnerRecord,
		AdoptLocal:    s.Schedules.AdoptOwner,
	})
	s.Kanban.SetHooks(kanban.Hooks{
		Ensure:             s.Ensure,
		WorkspaceSummary:   s.Workspaces.WorkspaceSummary,
		PullRequestSummary: s.Workspaces.PullRequestSummary,
		TokenUsage:         s.Conversations.TokenUsage,
		ScheduleOnBoard:    s.Schedules.OnBoard,
	})
	return s
}

// Close releases database handles owned by the store. Callers must stop
// background work before closing the store.
func (s *Store) Close() error {
	s.CloseNotifications()
	return errors.Join(s.Replica.Close(), s.Schedules.Close())
}

// Ensure checks the storage schema, creates the private DIETER_HOME layout,
// rehardens its permissions, stamps the sync epoch and runs Recover.
func (s *Store) Ensure() error {
	if err := s.CheckStorageSchema(); err != nil {
		return err
	}
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(s.Root, 0o700); err != nil {
		return err
	}
	for _, dir := range []string{
		s.CardDir(), s.ArchivedCardDir(), s.ConversationDir(), s.RuntimeDir(), s.SyncDir(),
		s.WorkspaceDir(), s.GitOperationDir(), s.PullRequestDir(), s.ChangeCommentDir(), s.RecoveryDir(), filepath.Join(s.Root, "logs"), filepath.Join(s.RuntimeDir(), "leases"),
	} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	if err := s.EnsurePrivateMetadataPermissions(); err != nil {
		return err
	}
	if err := s.EnsureSyncEpoch(); err != nil {
		return err
	}
	return s.Recover()
}

// Recover completes work a crashed or failed writer left behind: local file
// effects of committed peer transactions, an uncommitted change counter, and
// the schedule publication outbox. Ensure runs it at startup and the daemon
// sweeps periodically (RecoverEvery). Writers do not repeat it: every peer
// transaction applies all pending effects after its own commit, and every new
// change first commits a pending predecessor (home.Dir.PrepareMutation).
func (s *Store) Recover() error {
	release, err := s.BeginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	return errors.Join(s.Replica.RecoverEffects(), s.RecoverMutation(), s.Schedules.FlushOutbox())
}

// RecoverEvery runs Recover every interval until ctx ends. Failures are
// retried on the next tick; the store stays usable meanwhile.
func (s *Store) RecoverEvery(ctx context.Context, interval time.Duration, logger *slog.Logger) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.Recover(); err != nil && ctx.Err() == nil {
				logger.Warn("storage recovery sweep failed; retrying", "error", err)
			}
		}
	}
}
