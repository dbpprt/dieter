package linuxfs

import (
	"sort"
	"strings"

	"dieter.spike/workspaces/core"
)

// hidesLower reports whether an upper entry hides the lower subtree below
// its path: whiteouts, opaque directories and non-directories do.
func hidesLower(u UpperEntry) bool {
	return u.Deleted || u.Opaque || u.Entry.Type != core.Dir
}

func parentOf(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[:i]
	}
	return ""
}

// resolve returns the merged state of p: the upper entry when there is one,
// otherwise the lower entry unless an upper ancestor hides it.
func resolve(p string, upper map[string]UpperEntry, lower core.Tree) (core.Entry, bool) {
	if u, ok := upper[p]; ok {
		if u.Deleted {
			return core.Entry{}, false
		}
		return u.Entry, true
	}
	for a := parentOf(p); a != ""; a = parentOf(a) {
		if u, ok := upper[a]; ok && hidesLower(u) {
			return core.Entry{}, false
		}
	}
	e, ok := lower[p]
	return e, ok
}

// hidingPrefixes returns the lower directories whose contents the upper
// hides.
func hidingPrefixes(upper map[string]UpperEntry, lower core.Tree) map[string]bool {
	out := map[string]bool{}
	for p, u := range upper {
		if !hidesLower(u) {
			continue
		}
		if l, ok := lower[p]; ok && l.Type == core.Dir {
			out[p] = true
		}
	}
	return out
}

func underAny(p string, set map[string]bool) bool {
	for a := parentOf(p); a != ""; a = parentOf(a) {
		if set[a] {
			return true
		}
	}
	return false
}

// lowerBelow returns the lower paths strictly below any directory in set.
func lowerBelow(lower core.Tree, set map[string]bool) []string {
	if len(set) == 0 {
		return nil
	}
	var out []string
	for q := range lower {
		if underAny(q, set) {
			out = append(out, q)
		}
	}
	return out
}

// Effective computes the merged view of lower and upper without mounting.
func (Overlay) Effective(lower core.Tree, upper map[string]UpperEntry) core.Tree {
	hide := hidingPrefixes(upper, lower)
	out := make(core.Tree, len(lower)+len(upper))
	for p, e := range lower {
		if _, ok := upper[p]; ok {
			continue
		}
		if len(hide) > 0 && underAny(p, hide) {
			continue
		}
		out[p] = e
	}
	for p, u := range upper {
		if !u.Deleted {
			out[p] = u.Entry
		}
	}
	return out
}

// diffUpper is the cumulative change set of an upper over its lower. Only
// touched paths are compared: upper entries and lower entries below hiding
// upper entries.
func diffUpper(lower core.Tree, upper map[string]UpperEntry) (core.ChangeSet, CopyUpStats) {
	var st CopyUpStats
	below := lowerBelow(lower, hidingPrefixes(upper, lower))
	st.HiddenLower = len(below)
	before := make(core.Tree, len(upper)+len(below))
	after := make(core.Tree, len(upper)+len(below))
	add := func(p string) {
		if e, ok := lower[p]; ok {
			before[p] = e
		}
		if e, ok := resolve(p, upper, lower); ok {
			after[p] = e
		}
	}
	for p, u := range upper {
		add(p)
		if u.Deleted || u.Entry.Type == core.Dir {
			continue
		}
		if l, ok := lower[p]; ok && l == u.Entry {
			st.Identical++
			st.IdenticalPaths = append(st.IdenticalPaths, p)
		}
	}
	for _, q := range below {
		add(q)
	}
	sort.Strings(st.IdenticalPaths)
	if len(st.IdenticalPaths) > 20 {
		st.IdenticalPaths = st.IdenticalPaths[:20]
	}
	return core.DiffTrees(before, after), st
}

// ChangesBetween is the change set between two snapshots of the same upper
// (for example before and after one turn): the merged states of every path
// either snapshot touched, diffed. Paths whose upper entry did not change
// but whose content returned to the lower state are reported, as they
// changed during the turn.
func ChangesBetween(prev, cur map[string]UpperEntry, lower core.Tree) core.ChangeSet {
	touched := make(map[string]struct{}, len(prev)+len(cur))
	for p := range prev {
		touched[p] = struct{}{}
	}
	for p := range cur {
		touched[p] = struct{}{}
	}
	hp, hc := hidingPrefixes(prev, lower), hidingPrefixes(cur, lower)
	flipped := map[string]bool{}
	for p := range hp {
		if !hc[p] {
			flipped[p] = true
		}
	}
	for p := range hc {
		if !hp[p] {
			flipped[p] = true
		}
	}
	for _, q := range lowerBelow(lower, flipped) {
		touched[q] = struct{}{}
	}
	before := make(core.Tree, len(touched))
	after := make(core.Tree, len(touched))
	for p := range touched {
		if e, ok := resolve(p, prev, lower); ok {
			before[p] = e
		}
		if e, ok := resolve(p, cur, lower); ok {
			after[p] = e
		}
	}
	return core.DiffTrees(before, after)
}
