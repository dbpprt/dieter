// Package kanban is the account-shared work directory replicated by the peer
// store: projects and their checkouts, boards with their workflows and labels,
// and the cards and standalone chats placed on them, with consolidation,
// retirement, ordering and the projections built from them. These entities
// commit in one replica transaction together with their local file effects
// (card files, checkout files, receipts) and are projected from one replica
// snapshot, so they form one aggregate. Turn admission (AcquireRuntimeLease)
// lives here because it checks their unresolved conflicts.
package kanban

import (
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Store is the shared work directory of one DIETER_HOME.
type Store struct {
	home    *home.Dir
	replica *replica.Store
	leases  *leases.Store
	hooks   Hooks

	globalStateMu       home.ContextMutex
	globalStateSnapshot *model.State
	globalStateRevision home.Revision
}

// New returns the directory on dir, its replica and its runtime leases.
func New(dir *home.Dir, peers *replica.Store, turns *leases.Store) *Store {
	return &Store{home: dir, replica: peers, leases: turns}
}
