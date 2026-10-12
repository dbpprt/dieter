// Package home is the central DIETER_HOME store that every aggregate builds on:
// its directory layout, the cross-process writer lock and its admission, the
// storage schema, the durable change counter and its notifications, the SQLite
// opener, and the private JSON and Markdown file helpers. Aggregates never
// bypass the writer lock; every mutation writes atomically (fsx.WriteFile).
package home

import (
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

var ErrNotFound = fault.New(fault.NotFound, "not found")

// Dir is one process's handle on DIETER_HOME. Every aggregate of a composed
// store shares the same Dir, so its in-process writer queue, hooks and change
// notifications cover all of them.
type Dir struct {
	// writeMu queues this instance's writers in process before they contend
	// for the cross-process writer admission lock under Root.
	writeMu       ContextMutex
	hooks         Hooks
	notifications changeNotifications
	Root          string
}

// New opens the central store rooted at the absolute DIETER_HOME root. The
// composition root resolves DIETER_HOME; an empty root is a programming error.
func New(root string) *Dir {
	if strings.TrimSpace(root) == "" {
		panic("store: DIETER_HOME root is required")
	}
	if !filepath.IsAbs(root) {
		if absolute, err := filepath.Abs(root); err == nil {
			root = absolute
		}
	}
	return &Dir{Root: root}
}
