package folders

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"

	"github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
)

// MaxTrashItems bounds a folder's trash manifest.
const MaxTrashItems = 10000

// TrashItem is an old version this daemon kept: a deleted or replaced file.
type TrashItem struct {
	ID         string          `json:"id"`
	Path       string          `json:"path"`
	Size       int64           `json:"size"`
	SHA256     string          `json:"sha256,omitempty"`
	Executable bool            `json:"executable,omitempty"`
	Modified   int64           `json:"modified,omitempty"`
	Version    folders.Version `json:"version,omitempty"`
	DeletedAt  string          `json:"deletedAt"`
	DeletedBy  string          `json:"deletedBy,omitempty"`
	Reason     string          `json:"reason"`
}

// TrashDir is where trashed payloads of folder id live, named by item ID.
func (s *Store) TrashDir(id string) string { return filepath.Join(s.dir(id), "trash", "items") }

func (s *Store) trashManifest(id string) string {
	return filepath.Join(s.dir(id), "trash", "manifest.json")
}

// Trash lists folder id's trash, newest first.
func (s *Store) Trash(id string) ([]TrashItem, error) {
	var items []TrashItem
	err := home.ReadJSON(s.trashManifest(id), &items)
	if errors.Is(err, home.ErrNotFound) {
		err = nil
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].DeletedAt > items[j].DeletedAt })
	return items, err
}

// AddTrashLocked records an item whose payload is already in TrashDir.
func (s *Store) AddTrashLocked(id string, item TrashItem) error {
	items, err := s.Trash(id)
	if err != nil {
		return err
	}
	items = append(items, item)
	if len(items) > MaxTrashItems {
		sort.SliceStable(items, func(i, j int) bool { return items[i].DeletedAt > items[j].DeletedAt })
		for _, old := range items[MaxTrashItems:] {
			_ = os.Remove(filepath.Join(s.TrashDir(id), old.ID))
		}
		items = items[:MaxTrashItems]
	}
	return home.WriteJSON(s.trashManifest(id), items)
}

// TrashItemLocked finds one item.
func (s *Store) TrashItemLocked(id, itemID string) (TrashItem, error) {
	items, err := s.Trash(id)
	if err != nil {
		return TrashItem{}, err
	}
	for _, item := range items {
		if item.ID == itemID {
			return item, nil
		}
	}
	return TrashItem{}, fault.NotFoundf("trash item not found")
}

// RemoveTrashLocked forgets items (all when ids is empty) and their payload.
func (s *Store) RemoveTrashLocked(id string, ids []string) error {
	items, err := s.Trash(id)
	if err != nil {
		return err
	}
	kept := items[:0]
	for _, item := range items {
		if len(ids) == 0 || slices.Contains(ids, item.ID) {
			if err := os.Remove(filepath.Join(s.TrashDir(id), item.ID)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			continue
		}
		kept = append(kept, item)
	}
	return home.WriteJSON(s.trashManifest(id), kept)
}

// SweepTrashLocked drops items older than retention, then the oldest items
// beyond quota bytes. Zero retention empties the trash.
func (s *Store) SweepTrashLocked(id string, retention time.Duration, quota int64, now time.Time) error {
	items, err := s.Trash(id)
	if err != nil || len(items) == 0 {
		return err
	}
	var drop []string
	var total int64
	for _, item := range items {
		at, _ := time.Parse(time.RFC3339Nano, item.DeletedAt)
		total += item.Size
		if retention <= 0 || at.Before(now.Add(-retention)) || total > quota {
			drop = append(drop, item.ID)
		}
	}
	if len(drop) == 0 {
		return nil
	}
	return s.RemoveTrashLocked(id, drop)
}
