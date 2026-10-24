// Package linuxfs evaluates per-session copy-on-write views of a checkout on
// Linux: an overlayfs, mounted by bubblewrap in an unprivileged user+mount
// namespace at the checkout's own path over a frozen lower, whose upper
// directory is the session's exact change set.
package linuxfs

import (
	"time"

	"dieter.spike/workspaces/core"
)

// Overlay is one session view. Lower is the frozen base (a read-only btrfs
// snapshot or a copy), Upper receives every write, Work is the overlayfs
// work directory (same filesystem and btrfs subvolume as Upper) and Mount is
// where the merged view appears inside the namespace: the checkout's path.
// No two of the four paths may contain one another.
type Overlay struct {
	Lower, Upper, Work, Mount string
}

// UpperEntry is one entry of an overlay upper directory. Deleted marks a
// whiteout: the path and any lower subtree below it are gone. Opaque marks a
// directory that hides every lower child. Entry is the state of a
// non-deleted entry, with the scanner's conventions (sha256 content hash,
// permission bits, 0 mode for symlinks, xattr hash without overlay,
// security and trusted names).
type UpperEntry struct {
	Path    string
	Deleted bool
	Opaque  bool
	Entry   core.Entry
}

// UpperStats summarizes one ReadUpper pass.
type UpperStats struct {
	Entries                       int // entries in the returned map
	Files, Dirs, Symlinks, Others int
	Whiteouts, Opaque             int
	// Redirects and Metacopy count overlay features this reader does not
	// interpret; both stay 0 with userxattr (unprivileged) mounts.
	Redirects, Metacopy int
	// GitInternal counts upper paths at or below the root .git; they are
	// excluded from the map and from change sets.
	GitInternal int
	Bytes       int64 // regular-file bytes hashed
	Elapsed     time.Duration
}

// CopyUpStats explains a Changes result.
type CopyUpStats struct {
	Upper UpperStats
	// Identical counts upper files and symlinks whose state equals the lower
	// entry: copy-ups without a net change (touch, identical rewrite, open
	// for writing, chmod back). They are not reported as changes.
	Identical      int
	IdenticalPaths []string // up to 20, sorted
	// HiddenLower counts lower entries below whiteouts, opaque directories or
	// directories replaced by a non-directory.
	HiddenLower int
	Elapsed     time.Duration // ReadUpper plus diff
}
