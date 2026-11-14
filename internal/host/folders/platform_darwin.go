package folders

import "context"

// macOS file systems are case-insensitive by default.
const caseInsensitive = true

// Files received from other devices are quarantined by default on macOS.
const quarantineDefault = true

// watch reports no events on macOS: fsnotify's kqueue backend needs one
// descriptor per file, so members are walked every Options.Walk instead.
func (e *Engine) watch(context.Context, string) (<-chan struct{}, bool) { return nil, false }
