package folders

import (
	"fmt"
	"path"
	"strings"
	"time"
	"unicode/utf8"
)

// Action is what a member does with a remote entry.
type Action string

const (
	// ActionNone leaves the local entry as it is.
	ActionNone Action = "none"
	// ActionApply makes the local copy match Result (download, mkdir or
	// delete) and records Result. With ConflictCopy set, the local content
	// moves there first: it lost a conflict.
	ActionApply Action = "apply"
	// ActionMerge records Result, whose content the member already has.
	ActionMerge Action = "merge"
	// ActionOutOfSync: a send-only member does not apply a newer remote entry.
	ActionOutOfSync Action = "out-of-sync"
)

// Decision is the outcome of reconciling a local entry with a remote one.
type Decision struct {
	Action Action `json:"action"`
	// Result is the entry to record for apply and merge.
	Result Entry `json:"result"`
	// Conflict reports concurrent versions with different content.
	Conflict bool `json:"conflict,omitempty"`
	// ConflictCopy is where this member keeps its losing local content.
	ConflictCopy string `json:"conflictCopy,omitempty"`
}

// Decide reconciles a member's local entry (nil when it has none) with a
// remote entry for the same path, for a member in mode.
//
// When versions are concurrent and contents differ, only the member whose
// local content loses acts: it keeps that content as a conflict copy and
// records the winner under a merged version. The winner's holder changes
// nothing, so the loser's holder always sees the conflict. A modification
// beats a deletion and a directory beats a file.
func Decide(local *Entry, remote Entry, mode Mode) Decision {
	if local == nil {
		if mode == ModeSendOnly {
			if remote.Kind == KindDeleted {
				return Decision{Action: ActionNone}
			}
			return Decision{Action: ActionOutOfSync}
		}
		return Decision{Action: ActionApply, Result: remote}
	}
	switch Compare(local.Version, remote.Version) {
	case Equal, After:
		return Decision{Action: ActionNone}
	case Before:
		if mode == ModeSendOnly {
			return Decision{Action: ActionOutOfSync}
		}
		return Decision{Action: ActionApply, Result: remote}
	}
	merged := Merge(local.Version, remote.Version)
	if SameContent(*local, remote) {
		result := *local
		if Wins(remote, *local) {
			result = remote
		}
		result.Path, result.Version = local.Path, merged
		return Decision{Action: ActionMerge, Result: result}
	}
	if mode == ModeSendOnly {
		return Decision{Action: ActionOutOfSync, Conflict: true}
	}
	winner := remote
	winner.Version = merged
	apply := Decision{Action: ActionApply, Result: winner, Conflict: true}
	switch {
	case local.Kind == KindDeleted:
		return apply
	case remote.Kind == KindDeleted:
		return Decision{Action: ActionNone, Conflict: true}
	case local.Kind == KindDirectory && remote.Kind == KindFile:
		return Decision{Action: ActionNone, Conflict: true}
	case local.Kind == KindFile && remote.Kind == KindDirectory:
		apply.ConflictCopy = ConflictName(local.Path, local.AuthorName, local.Modified)
		return apply
	case Wins(*local, remote):
		return Decision{Action: ActionNone, Conflict: true}
	}
	apply.ConflictCopy = ConflictName(local.Path, local.AuthorName, local.Modified)
	return apply
}

// ConflictName is where the losing version of p, made by author at modified
// (Unix nanoseconds), is kept: "stem (conflict, AUTHOR, YYYY-MM-DD HH.MM.SS).ext".
// Every member derives the same name from the same entry.
func ConflictName(p, author string, modified int64) string {
	dir, base := path.Split(p)
	ext := path.Ext(base)
	if ext == base || len(ext) > 16 {
		ext = ""
	}
	stem := strings.TrimSuffix(base, ext)
	suffix := fmt.Sprintf(" (conflict, %s, %s)%s", SanitizeName(author), time.Unix(0, modified).UTC().Format("2006-01-02 15.04.05"), ext)
	for len(stem)+len(suffix) > MaxComponentBytes && stem != "" {
		_, size := utf8.DecodeLastRuneInString(stem)
		stem = stem[:len(stem)-size]
	}
	return dir + stem + suffix
}

// SanitizeName makes a device name safe inside a file name: separators and
// control characters become '-', and it is at most 40 bytes. Empty is
// "unknown".
func SanitizeName(name string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(name) {
		switch {
		case r < 0x20 || r == 0x7f || strings.ContainsRune(`/\:*?"<>|`, r):
			r = '-'
		case r == utf8.RuneError:
			continue
		}
		if b.Len()+utf8.RuneLen(r) > 40 {
			break
		}
		b.WriteRune(r)
	}
	out := strings.TrimSpace(b.String())
	if out == "" {
		return "unknown"
	}
	return NormalizePath(out)
}
