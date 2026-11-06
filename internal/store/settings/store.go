// Package settings holds the daemon's global settings (settings.yaml): prompt
// and skill templates and harness defaults, validated on every read and write.
package settings

import "github.com/dbpprt/dieter/internal/store/home"

// Store is the settings file of one DIETER_HOME.
type Store struct{ home *home.Dir }

// New returns the settings of dir.
func New(dir *home.Dir) *Store { return &Store{home: dir} }
