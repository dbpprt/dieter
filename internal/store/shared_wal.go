package store

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"

	md "github.com/dbpprt/dieter/internal/markdown"
	"github.com/dbpprt/dieter/internal/model"
)

// Local effects commit in the same SQLite transaction as their directory records.
// Recovery replays bytes, never a stale domain mutation or causal clock. The
// central writer lock prevents a newer local effect from overtaking recovery.
type localEffect struct {
	Path   string
	Value  []byte
	Remove bool
}

func (s *Store) writeCard(item model.Card) error {
	if err := s.RequireLocalCard(item); err != nil {
		if errors.Is(err, ErrRemoteConversation) {
			return s.publishCard(item)
		}
		return err
	}
	raw, err := md.Marshal(item, item.InitialPrompt)
	if err != nil {
		return err
	}
	target, stale := "cards/", "archived-cards/"
	if item.Archived {
		target, stale = stale, target
	}
	return s.publishCard(item,
		localEffect{Path: target + item.ID + ".md", Value: raw},
		localEffect{Path: stale + item.ID + ".md", Remove: true})
}

func (s *Store) applyPeerEffects(db *sql.DB) error {
	rows, err := db.Query("SELECT path,value,remove_file FROM peer_effects ORDER BY path")
	if err != nil {
		return err
	}
	var effects []localEffect
	for rows.Next() {
		var effect localEffect
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
			return errors.New("invalid local transaction path")
		}
		path := filepath.Join(s.Root, clean)
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
			err = atomicWrite(path, effect.Value)
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

func (s *Store) recoverCardWrites() error {
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
