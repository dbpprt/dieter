// Package kv is the replicated key-value aggregate: namespaced records of the
// peer replica written with durable, operation-ID receipts and ordered moves.
package kv

import (
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Store writes key-value records of one DIETER_HOME replica.
type Store struct {
	home    *home.Dir
	replica *replica.Store
}

// New returns the key-value aggregate on dir and its replica.
func New(dir *home.Dir, peers *replica.Store) *Store { return &Store{home: dir, replica: peers} }
