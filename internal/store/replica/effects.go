package replica

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// Effects are local file writes or removals that commit in the same SQLite transaction as their directory records.
// Recovery replays bytes, never a stale domain mutation or causal clock. The
// central writer lock prevents a newer local effect from overtaking recovery.
type Effect struct {
	Path   string
	Value  []byte
	Remove bool
}

func (s *Store) applyPeerEffects(db *sql.DB) error {
	rows, err := db.Query("SELECT path,value,remove_file FROM peer_effects ORDER BY path")
	if err != nil {
		return err
	}
	var effects []Effect
	for rows.Next() {
		var effect Effect
		if err = rows.Scan(&effect.Path, &effect.Value, &effect.Remove); err != nil {
			break
		}
		effects = append(effects, effect)
	}
	rowErr := rows.Err()
	_ = rows.Close()
	if err != nil {
		return err
	}
	if rowErr != nil {
		return rowErr
	}
	for _, effect := range effects {
		clean := filepath.Clean(effect.Path)
		if filepath.IsAbs(clean) || clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return fault.New(fault.Invalid, "invalid local transaction path")
		}
		path := filepath.Join(s.home.Root, clean)
		if effect.Remove {
			err = os.Remove(path)
			if err == nil {
				directory, openErr := os.Open(filepath.Dir(path))
				if openErr != nil {
					return openErr
				}
				err = directory.Sync()
				_ = directory.Close()
			}
			if errors.Is(err, os.ErrNotExist) {
				err = nil
			}
		} else {
			err = fsx.WriteFile(path, effect.Value, 0o600)
		}
		if err != nil {
			return err
		}
		if _, err = db.Exec("DELETE FROM peer_effects WHERE path=?", effect.Path); err != nil {
			return err
		}
	}
	return nil
}

// RecoverEffects applies local effects that a committed transaction left
// behind (a writer killed between commit and apply).
func (s *Store) RecoverEffects() error {
	identity, err := s.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err = os.Stat(s.peerPath(identity.Account)); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	db, err := s.peerDatabase(identity.Account)
	if err != nil {
		return err
	}
	return s.applyPeerEffects(db)
}
