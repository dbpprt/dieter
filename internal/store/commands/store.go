// Package commands keeps the results of idempotent client commands under
// sync/commands, keyed by client and command ID, so a retried create, send or
// start returns the original outcome instead of repeating it.
package commands

import "github.com/dbpprt/dieter/internal/store/home"

// Store is the command result log of one DIETER_HOME.
type Store struct{ home *home.Dir }

// New returns the command results of dir.
func New(dir *home.Dir) *Store { return &Store{home: dir} }
