// Package conversations holds the durable local harness conversation of every
// card and chat this machine owns: the fsynced event journal and its reducer,
// optional checkpoints written outside the writer lock, the bounded projection
// and status caches, client windows, UI chunk batches and token usage. It also
// hosts the operations that span a conversation and its card: forks, merges,
// interruption, read receipts and the orphaned-turn scan.
package conversations

import (
	"sync"

	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Store is the conversation aggregate of one DIETER_HOME.
type Store struct {
	home    *home.Dir
	replica *replica.Store
	kanban  *kanban.Store
	leases  *leases.Store

	conversations conversationCache
	statuses      conversationStatusCache
	checkpoints   conversationCheckpoints

	usageMu    sync.Mutex
	usageCache map[string]cardUsageCacheEntry
}

// New returns the conversations of dir; cards resolve through board.
func New(dir *home.Dir, peers *replica.Store, board *kanban.Store, turns *leases.Store) *Store {
	return &Store{home: dir, replica: peers, kanban: board, leases: turns}
}
