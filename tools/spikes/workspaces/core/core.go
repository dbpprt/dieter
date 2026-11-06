// Package core holds the types every spike component shares: tree states,
// change sets, scenario steps and the harness driver contract.
package core

import (
	"context"
	"sort"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
)

// EntryType is the kind of a filesystem entry.
type EntryType string

const (
	File    EntryType = "file"
	Dir     EntryType = "dir"
	Symlink EntryType = "symlink"
	Other   EntryType = "other"
)

// Entry is one path's observable state.
type Entry struct {
	Type   EntryType `json:"type"`
	Mode   uint32    `json:"mode"`             // permission bits only (0o7777)
	Size   int64     `json:"size"`             // bytes for files and symlinks
	Hash   string    `json:"hash,omitempty"`   // sha256 hex of file content
	Target string    `json:"target,omitempty"` // symlink target
	Xattrs string    `json:"xattrs,omitempty"` // sha256 of sorted name=value pairs; "" when none
}

// Tree maps NFC-normalized slash-separated relative paths to entries. Trees
// never contain the ".git" subtree; git state is compared separately.
type Tree map[string]Entry

// ChangeKind classifies a change to one path.
type ChangeKind string

const (
	Added        ChangeKind = "added"
	Deleted      ChangeKind = "deleted"
	Modified     ChangeKind = "modified"
	ModeChanged  ChangeKind = "mode"
	TypeChanged  ChangeKind = "type"
	XattrChanged ChangeKind = "xattr"
	Changed      ChangeKind = "changed" // a reporter that knows a path changed but not how
)

// Change is one changed path. Ignored is set when git ignores the path.
type Change struct {
	Path    string     `json:"path"`
	Kind    ChangeKind `json:"kind"`
	Ignored bool       `json:"ignored,omitempty"`
}

// ChangeSet maps a normalized path to its change.
type ChangeSet map[string]Change

// NormPath turns an OS path fragment into the canonical comparison key.
func NormPath(p string) string {
	p = strings.TrimPrefix(strings.ReplaceAll(p, "\\", "/"), "./")
	return norm.NFC.String(strings.TrimSuffix(p, "/"))
}

// Add records a change, keeping the most specific kind when a path is
// reported twice.
func (c ChangeSet) Add(path string, kind ChangeKind, ignored bool) {
	path = NormPath(path)
	if path == "" {
		return
	}
	if old, ok := c[path]; ok && old.Kind != Changed && kind == Changed {
		return
	}
	c[path] = Change{Path: path, Kind: kind, Ignored: ignored}
}

// Paths returns the sorted paths.
func (c ChangeSet) Paths() []string {
	out := make([]string, 0, len(c))
	for p := range c {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// DiffTrees returns the changes from before to after. Directories are not
// reported (git does not track them); files, symlinks and other entries are.
func DiffTrees(before, after Tree) ChangeSet {
	out := ChangeSet{}
	for p, a := range after {
		b, ok := before[p]
		if a.Type == Dir {
			if ok && b.Type != Dir {
				out[p] = Change{Path: p, Kind: TypeChanged}
			}
			continue
		}
		switch {
		case !ok:
			out[p] = Change{Path: p, Kind: Added}
		case b.Type != a.Type:
			out[p] = Change{Path: p, Kind: TypeChanged}
		case b.Hash != a.Hash || b.Target != a.Target || (a.Type != File && b.Size != a.Size):
			out[p] = Change{Path: p, Kind: Modified}
		case b.Mode != a.Mode:
			out[p] = Change{Path: p, Kind: ModeChanged}
		case b.Xattrs != a.Xattrs:
			out[p] = Change{Path: p, Kind: XattrChanged}
		}
	}
	for p, b := range before {
		if _, ok := after[p]; !ok && b.Type != Dir {
			out[p] = Change{Path: p, Kind: Deleted}
		}
	}
	return out
}

// Score compares a reported change set with the truth on paths. Kind
// mismatches on a matched path are counted separately.
type Score struct {
	TP, FP, FN, KindMismatch int
	Missed, Extra            []string
}

// Compare scores got against truth, restricted to changes for which scope
// returns true (nil means everything). Scope is applied to truth entries and
// to reported entries alike.
func Compare(truth, got ChangeSet, scope func(Change) bool) Score {
	in := func(c Change) bool { return scope == nil || scope(c) }
	var s Score
	for p, t := range truth {
		if !in(t) {
			continue
		}
		g, ok := got[p]
		if !ok {
			s.FN++
			s.Missed = append(s.Missed, p)
			continue
		}
		s.TP++
		if g.Kind != Changed && g.Kind != t.Kind {
			s.KindMismatch++
		}
	}
	for p, g := range got {
		if _, ok := truth[p]; ok {
			continue
		}
		if !in(g) {
			continue
		}
		s.FP++
		s.Extra = append(s.Extra, p)
	}
	sort.Strings(s.Missed)
	sort.Strings(s.Extra)
	return s
}

// Step is one scripted action in a scenario. Tool "edit" must be performed
// with the harness's native file tool; "shell" with its shell tool.
type Step struct {
	Tool    string `json:"tool"`              // "edit" or "shell"
	Path    string `json:"path,omitempty"`    // edit: file path relative to the working directory
	Old     string `json:"old,omitempty"`     // edit: exact text to replace ("" with Create)
	New     string `json:"new,omitempty"`     // edit: replacement text
	Create  bool   `json:"create,omitempty"`  // edit: create the file with Content
	Content string `json:"content,omitempty"` // edit: full content for Create
	Command string `json:"command,omitempty"` // shell: exact command line for sh -c
}

// Launcher describes how a driver starts its harness process: the working
// directory, an optional wrapper argv prefix (for example bwrap ... --) and
// extra environment.
type Launcher struct {
	Dir  string
	Wrap []string
	Env  []string
}

// TurnInput is one turn for a driver.
type TurnInput struct {
	Prompt  string
	Steps   []Step
	LogPath string // driver appends raw harness events as JSONL here
}

// TurnResult is what a harness said it changed in one turn.
type TurnResult struct {
	Reported ChangeSet      `json:"reported"`
	Detail   map[string]any `json:"detail,omitempty"` // driver-specific counters (tool calls, bashEditDiff, turn diff paths…)
	Duration time.Duration  `json:"duration"`
	Error    string         `json:"error,omitempty"`
}

// Driver runs turns of one conversation. A new Driver is a new session; each
// Turn continues the same session.
type Driver interface {
	Name() string
	Turn(ctx context.Context, in TurnInput) (TurnResult, error)
	Close() error
}

// RenderPrompt turns scripted steps into an exact instruction for an agent.
func RenderPrompt(steps []Step) string {
	var b strings.Builder
	b.WriteString("This is an automated filesystem test. Perform exactly the numbered steps below, in order, in the current working directory. ")
	b.WriteString("Use the tool named for each step: \"file-edit tool\" means your native file editing/writing tool (never the shell), \"shell\" means run the given command verbatim with your shell tool. ")
	b.WriteString("Do not run any other commands, do not inspect, verify, format or fix anything, and do not commit unless a step says so. When done, reply with the single word DONE.\n\n")
	for i, s := range steps {
		b.WriteString(itoa(i + 1))
		b.WriteString(". ")
		switch {
		case s.Tool == "edit" && s.Create:
			b.WriteString("file-edit tool: create the file `" + s.Path + "` with exactly this content (between the markers, excluding them):\n<<<CONTENT\n" + s.Content + "\nCONTENT>>>\n")
		case s.Tool == "edit":
			b.WriteString("file-edit tool: in `" + s.Path + "`, replace the exact text `" + s.Old + "` with `" + s.New + "` (first occurrence only).\n")
		default:
			b.WriteString("shell: run exactly:\n```sh\n" + s.Command + "\n```\n")
		}
	}
	return b.String()
}

func itoa(n int) string {
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}
