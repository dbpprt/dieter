// Package schedules holds this machine's schedules in schedules.db: the
// definitions and their keyset pages, the occurrence records a claim writes in
// the same SQLite transaction that advances the schedule cursor, and the
// transactional outbox that publishes definition summaries to the account's
// replica. Projects, boards, labels and checkouts resolve through kanban.
package schedules

import (
	"database/sql"
	"sync"

	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Store is the schedule aggregate of one DIETER_HOME.
type Store struct {
	home    *home.Dir
	replica *replica.Store
	kanban  *kanban.Store

	dbMu sync.Mutex
	db   *sql.DB
}

// New returns the schedules of dir; projects and boards resolve through board.
func New(dir *home.Dir, peers *replica.Store, board *kanban.Store) *Store {
	return &Store{home: dir, replica: peers, kanban: board}
}
