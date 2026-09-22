package store

import (
	"path/filepath"
	"sync"

	"github.com/fsnotify/fsnotify"
)

// Notifications are hints, never cursors. Each subscriber has one coalescing
// slot and always rereads durable state. One filesystem watch per Store catches
// commits by harness workers/other processes, including atomic file replacement.
// Watchers also retain a slow recovery poll for overflow, failed setup or a
// writer killed before committing its pending mutation.
type changeNotifications struct {
	mu        sync.Mutex
	listeners map[chan struct{}]struct{}
	watcher   *fsnotify.Watcher
}

func (s *Store) SubscribeChanges() (<-chan struct{}, func()) {
	n := &s.notifications
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.listeners == nil {
		n.listeners = make(map[chan struct{}]struct{})
	}
	ch := make(chan struct{}, 1)
	n.listeners[ch] = struct{}{}
	if n.watcher == nil {
		if watcher, err := fsnotify.NewWatcher(); err == nil {
			if err = watcher.Add(s.syncDir()); err == nil {
				n.watcher = watcher
				go func() {
					for {
						select {
						case event, ok := <-watcher.Events:
							if !ok {
								return
							}
							name := filepath.Base(event.Name)
							if name == "highwater" || name == "epoch" {
								s.notifyChanges()
							}
						case _, ok := <-watcher.Errors:
							if !ok {
								return
							}
							s.notifyChanges()
						}
					}
				}()
			} else {
				_ = watcher.Close()
			}
		}
	}
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			n.mu.Lock()
			delete(n.listeners, ch)
			var watcher *fsnotify.Watcher
			if len(n.listeners) == 0 {
				watcher, n.watcher = n.watcher, nil
			}
			n.mu.Unlock()
			if watcher != nil {
				_ = watcher.Close()
			}
		})
	}
}

func (s *Store) notifyChanges() {
	n := &s.notifications
	n.mu.Lock()
	defer n.mu.Unlock()
	for ch := range n.listeners {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (s *Store) closeNotifications() {
	n := &s.notifications
	n.mu.Lock()
	watcher := n.watcher
	n.watcher = nil
	n.mu.Unlock()
	if watcher != nil {
		_ = watcher.Close()
	}
}
