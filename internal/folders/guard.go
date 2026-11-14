package folders

import (
	"cmp"
	"slices"
	"strings"
)

// Guard is a folder's deletion guard policy.
type Guard string

const (
	GuardDefault Guard = "default"
	GuardStrict  Guard = "strict"
	GuardOff     Guard = "off"
)

// GuardTrips reports whether deleting deletions of total entries in one batch
// needs a person's confirmation. Default: more than 100 files or more than 30%
// of the folder, with at least 10. Strict: more than 10 or more than 10%, with
// at least 3.
func GuardTrips(policy Guard, deletions, total int) bool {
	floor, files, percent := 10, 100, 30
	switch policy {
	case GuardOff:
		return false
	case GuardStrict:
		floor, files, percent = 3, 10, 10
	}
	if deletions < floor {
		return false
	}
	return deletions > files || deletions*100 > percent*total
}

// FoldKey identifies paths that collide on a case-insensitive file system.
func FoldKey(p string) string { return strings.ToLower(NormalizePath(p)) }

// Portable reports whether every component of p can be stored on a FAT or
// exFAT file system (Android shared storage on SD cards).
func Portable(p string) bool {
	for _, part := range strings.Split(p, "/") {
		if strings.ContainsAny(part, `\:*?"<>|`) || strings.HasSuffix(part, ".") || strings.HasSuffix(part, " ") {
			return false
		}
	}
	return true
}

// Ordered sorts actions into the order a member performs them: directories
// to create (shallow first), then deletions (deep first), then files by
// ascending size. Paths break ties.
func Ordered(entries []Entry) []Entry {
	out := slices.Clone(entries)
	rank := func(e Entry) int {
		switch e.Kind {
		case KindDirectory:
			return 0
		case KindDeleted:
			return 1
		}
		return 2
	}
	slices.SortStableFunc(out, func(a, b Entry) int {
		if c := cmp.Compare(rank(a), rank(b)); c != 0 {
			return c
		}
		switch a.Kind {
		case KindDirectory:
			if c := cmp.Compare(Depth(a.Path), Depth(b.Path)); c != 0 {
				return c
			}
		case KindDeleted:
			if c := cmp.Compare(Depth(b.Path), Depth(a.Path)); c != 0 {
				return c
			}
		default:
			if c := cmp.Compare(a.Size, b.Size); c != 0 {
				return c
			}
		}
		return strings.Compare(a.Path, b.Path)
	})
	return out
}
