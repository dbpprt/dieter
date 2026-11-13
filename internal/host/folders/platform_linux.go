package folders

import (
	"context"
	"errors"
	"io/fs"
	"path/filepath"
	"strings"
	"time"

	core "github.com/dbpprt/dieter/internal/folders"
	"github.com/fsnotify/fsnotify"
	"golang.org/x/sys/unix"
)

const caseInsensitive = false

const quarantineDefault = false

// watchDebounce coalesces a burst of file system events into one scan.
const watchDebounce = 2 * time.Second

// watch watches a member's directories with inotify and signals after a
// quiet period. When the watch limit is reached it gives up and the member
// is walked every Options.Walk instead.
func (e *Engine) watch(ctx context.Context, folderID string) (<-chan struct{}, bool) {
	member, err := e.folders().Member(folderID)
	if err != nil || !member.Watch {
		return nil, false
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, false
	}
	add := func(root string) error {
		return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if !entry.IsDir() {
				return nil
			}
			if name := entry.Name(); path != member.Path && (name == ".git" || strings.HasPrefix(name, core.TemporaryPrefix)) {
				return filepath.SkipDir
			}
			return watcher.Add(path)
		})
	}
	if err := add(member.Path); err != nil {
		_ = watcher.Close()
		if errors.Is(err, unix.ENOSPC) {
			e.log.Info("inotify watch limit reached; walking the folder instead", "folder", folderID)
		}
		return nil, false
	}
	out := make(chan struct{}, 1)
	go func() {
		defer watcher.Close()
		timer := time.NewTimer(time.Hour)
		timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				if event.Has(fsnotify.Create) {
					if info, err := filepath.Glob(event.Name); err == nil && len(info) == 1 {
						_ = add(event.Name)
					}
				}
				timer.Reset(watchDebounce)
			case <-watcher.Errors:
				timer.Reset(watchDebounce)
			case <-timer.C:
				select {
				case out <- struct{}{}:
				default:
				}
			}
		}
	}()
	return out, true
}
