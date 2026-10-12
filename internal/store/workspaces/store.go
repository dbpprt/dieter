// Package workspaces holds the execution state a conversation owns on this
// machine: its workspace record (project checkout or managed worktree), Git
// operation records and logs, pull request state and change comments.
package workspaces

import (
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/leases"
)

// Store is the workspace aggregate of one DIETER_HOME.
type Store struct {
	home   *home.Dir
	kanban *kanban.Store
	leases *leases.Store
}

// New returns the workspaces of dir; cards and projects resolve through board.
func New(dir *home.Dir, board *kanban.Store, turns *leases.Store) *Store {
	return &Store{home: dir, kanban: board, leases: turns}
}
