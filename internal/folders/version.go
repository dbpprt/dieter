// Package folders holds the pure rules of synced folders: version vectors,
// index entries and their validation, reconciliation, conflict copy names,
// the deletion guard, rules and the order of work. It performs no I/O. The
// Kotlin core implements the same rules (apps/kotlin/core/.../folders); both
// are checked against tests/fixtures/folders/vectors.json.
package folders

import (
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// MaxCounters bounds a version vector: the actors that ever changed one entry.
const MaxCounters = 64

// Counter is one actor's count in a version vector.
type Counter struct {
	Actor string `json:"actor"`
	Value uint64 `json:"value"`
}

// Version is a version vector sorted by actor, without zero counters.
type Version []Counter

// Ordering is how two versions relate.
type Ordering int

const (
	Equal Ordering = iota
	// Before: the first version is dominated by the second.
	Before
	// After: the first version dominates the second.
	After
	Concurrent
)

func (o Ordering) String() string {
	return [...]string{"equal", "before", "after", "concurrent"}[o]
}

// ActorOf is the actor of a member ID: the first 8 bytes of its SHA-256 as
// 16 lowercase hex characters.
func ActorOf(memberID string) string {
	sum := sha256.Sum256([]byte(memberID))
	return hex.EncodeToString(sum[:8])
}

func validActor(actor string) bool {
	if len(actor) != 16 {
		return false
	}
	for _, c := range actor {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// Validate checks bounds, order and actor encoding.
func (v Version) Validate() error {
	if len(v) > MaxCounters {
		return fault.New(fault.ResourceExhausted, "version has too many actors")
	}
	for index, counter := range v {
		if !validActor(counter.Actor) || counter.Value == 0 {
			return fault.Invalidf("invalid version counter")
		}
		if index > 0 && v[index-1].Actor >= counter.Actor {
			return fault.Invalidf("version counters must be sorted and unique")
		}
	}
	return nil
}

// Get is actor's count.
func (v Version) Get(actor string) uint64 {
	index, found := slices.BinarySearchFunc(v, actor, func(c Counter, actor string) int { return strings.Compare(c.Actor, actor) })
	if !found {
		return 0
	}
	return v[index].Value
}

// Bump returns a copy of v with actor's count incremented.
func (v Version) Bump(actor string) Version {
	out := slices.Clone(v)
	index, found := slices.BinarySearchFunc(out, actor, func(c Counter, actor string) int { return strings.Compare(c.Actor, actor) })
	if found {
		out[index].Value++
		return out
	}
	return slices.Insert(out, index, Counter{Actor: actor, Value: 1})
}

// Merge is the element-wise maximum of a and b.
func Merge(a, b Version) Version {
	out := make(Version, 0, max(len(a), len(b)))
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case j == len(b) || i < len(a) && a[i].Actor < b[j].Actor:
			out = append(out, a[i])
			i++
		case i == len(a) || b[j].Actor < a[i].Actor:
			out = append(out, b[j])
			j++
		default:
			out = append(out, Counter{Actor: a[i].Actor, Value: max(a[i].Value, b[j].Value)})
			i++
			j++
		}
	}
	return out
}

// Compare relates a to b.
func Compare(a, b Version) Ordering {
	less, greater := false, false
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case j == len(b) || i < len(a) && a[i].Actor < b[j].Actor:
			greater = true
			i++
		case i == len(a) || b[j].Actor < a[i].Actor:
			less = true
			j++
		default:
			if a[i].Value > b[j].Value {
				greater = true
			} else if a[i].Value < b[j].Value {
				less = true
			}
			i++
			j++
		}
	}
	switch {
	case less && greater:
		return Concurrent
	case less:
		return Before
	case greater:
		return After
	}
	return Equal
}
