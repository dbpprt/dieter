// Package leases holds the runtime leases under runtime/leases: at most one
// active agent turn per conversation across API, CLI and scheduled starts. A
// lease belongs to a live Dieter process; leases of dead processes are pruned
// on read. Writers hold the central writer lock of home.Dir.
package leases

import "github.com/dbpprt/dieter/internal/store/home"

// Store is the runtime lease table of one DIETER_HOME.
type Store struct{ home *home.Dir }

// New returns the lease table of dir.
func New(dir *home.Dir) *Store { return &Store{home: dir} }
