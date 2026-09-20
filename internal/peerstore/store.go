// Package peerstore implements bounded, leaderless multi-value registers.
// Persistence and transport are supplied by the daemon; no wall clock decides edits.
package peerstore

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
)

const (
	MaxRecords    = 262144
	MaxActors     = 64
	MaxVersions   = 16
	MaxValueBytes = 32 << 10
	MaxStateBytes = 128 << 20
	PageSize      = 64
	MaxPageBytes  = 2 << 20
)

var ErrConflict = errors.New("peer store revision conflict; read and resolve current versions")
var ErrCapacity = errors.New("peer store capacity exceeded")

type Clock map[string]uint64
type Version struct {
	Provenance json.RawMessage `json:"provenance,omitempty"`
	Clock      Clock           `json:"clock"`
	Value      json.RawMessage `json:"value,omitempty"`
	Deleted    bool            `json:"deleted,omitempty"`
}
type Record struct {
	Kind     string    `json:"kind"`
	ID       string    `json:"id"`
	Versions []Version `json:"versions"`
}
type State struct {
	Dirty   map[string]bool   `json:"-"`
	Records map[string]Record `json:"records"`
}

func Key(kind, id string) string { return kind + "/" + id }
func ValidID(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return s != "." && s != ".."
}
func Revision(v any) string {
	b, _ := json.Marshal(v)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func (r Record) Revision() string {
	if len(r.Versions) == 0 {
		return ""
	}
	return Revision(r)
}
func dominates(a, b Clock) bool {
	for actor, n := range b {
		if a[actor] < n {
			return false
		}
	}
	return true
}
func validate(r Record) error {
	if !ValidID(r.Kind) || !ValidID(r.ID) || len(r.Versions) == 0 || len(r.Versions) > MaxVersions {
		return errors.New("invalid peer record identity or version count")
	}
	for _, v := range r.Versions {
		if len(v.Clock) == 0 || len(v.Clock) > MaxActors {
			return ErrCapacity
		}
		for a, n := range v.Clock {
			if !ValidID(a) || n == 0 {
				return errors.New("invalid peer causal clock")
			}
		}
		if len(v.Provenance) > 4096 {
			return ErrCapacity
		}
		if len(v.Value) > MaxValueBytes {
			return ErrCapacity
		}
		if v.Deleted {
			if len(v.Value) != 0 {
				return errors.New("tombstone contains a value")
			}
		} else if !json.Valid(v.Value) {
			return errors.New("peer value must be JSON")
		}
	}
	return nil
}

// Merge is a join: discard only causally dominated versions, retaining concurrent
// values and tombstones. Equal clocks with unequal contents are corruption.
func Merge(a, b Record) (Record, error) {
	if err := validate(b); err != nil {
		return Record{}, err
	}
	if len(a.Versions) > 0 {
		if err := validate(a); err != nil {
			return Record{}, err
		}
		if a.Kind != b.Kind || a.ID != b.ID {
			return Record{}, errors.New("record identity mismatch")
		}
	}
	all := append(append([]Version{}, a.Versions...), b.Versions...)
	// Normalize encoding before equality checks, including JSON string escaping.
	// Atomic JSON persistence must not turn an identical causal version into an
	// apparent equivocation when it is received again from an RPC response.
	for i := range all {
		if !all[i].Deleted {
			raw, err := canonicalValue(all[i].Value)
			if err != nil {
				return Record{}, err
			}
			all[i].Value = raw
		}
	}

	out := Record{Kind: b.Kind, ID: b.ID}
	for i, v := range all {
		keep := true
		for j, w := range all {
			if i == j || !dominates(w.Clock, v.Clock) {
				continue
			}
			if dominates(v.Clock, w.Clock) {
				if v.Deleted != w.Deleted || !bytes.Equal(v.Value, w.Value) {
					return Record{}, errors.New("equivocal peer causal version")
				}
				// Proofs can be renewed without changing the causal edit. Prefer
				// a present proof, then its canonical bytes, in either merge order.
				proofOrder := bytes.Compare(w.Provenance, v.Provenance)
				if (len(w.Provenance) > 0 && len(v.Provenance) == 0) || (len(w.Provenance) > 0 == (len(v.Provenance) > 0) && (proofOrder < 0 || proofOrder == 0 && j < i)) {
					keep = false
					break
				}
			} else {
				keep = false
				break
			}
		}
		if keep {
			out.Versions = append(out.Versions, v)
		}
	}
	if len(out.Versions) > MaxVersions {
		return Record{}, ErrCapacity
	}
	actors := Clock{}
	for _, v := range out.Versions {
		for a, n := range v.Clock {
			if n > actors[a] {
				actors[a] = n
			}
		}
	}
	if len(actors) > MaxActors {
		return Record{}, ErrCapacity
	}
	sort.Slice(out.Versions, func(i, j int) bool { return Revision(out.Versions[i]) < Revision(out.Versions[j]) })
	return out, nil
}
func Put(old Record, kind, id, actor, expected string, value []byte, deleted bool) (Record, error) {
	if len(value) > MaxValueBytes {
		return Record{}, ErrCapacity
	}
	if old.Revision() != expected {
		return Record{}, ErrConflict
	}
	if !ValidID(actor) {
		return Record{}, errors.New("invalid peer actor")
	}
	clock := Clock{}
	for _, v := range old.Versions {
		for a, n := range v.Clock {
			if n > clock[a] {
				clock[a] = n
			}
		}
	}
	if clock[actor] == ^uint64(0) {
		return Record{}, ErrCapacity
	}
	clock[actor]++
	var raw json.RawMessage
	if !deleted {
		var err error
		raw, err = canonicalValue(value)
		if err != nil {
			return Record{}, err
		}
	} else if len(value) > 0 {
		return Record{}, errors.New("delete must not contain a value")
	}
	return Merge(Record{}, Record{Kind: kind, ID: id, Versions: []Version{{Clock: clock, Value: raw, Deleted: deleted}}})
}
func (s State) Sorted() []Record {
	keys := make([]string, 0, len(s.Records))
	for k := range s.Records {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]Record, 0, len(keys))
	for _, k := range keys {
		out = append(out, s.Records[k])
	}
	return out
}
func (s State) Validate() error {
	if len(s.Records) > MaxRecords {
		return ErrCapacity
	}
	for k, r := range s.Records {
		if k != Key(r.Kind, r.ID) {
			return errors.New("invalid peer record key")
		}
		if err := validate(r); err != nil {
			return err
		}
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return err
	}
	if len(raw) > MaxStateBytes {
		return ErrCapacity
	}
	return nil
}

func canonicalValue(raw []byte) (json.RawMessage, error) {
	if !json.Valid(raw) {
		return nil, errors.New("peer value must be JSON")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	result, err := json.Marshal(value)
	if len(result) > MaxValueBytes {
		return nil, ErrCapacity
	}
	return result, err
}
