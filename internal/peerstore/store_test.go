package peerstore

import (
	"errors"
	"testing"
)

func edit(t *testing.T, r Record, actor, value string) Record {
	t.Helper()
	v, e := Put(r, "project-settings", "project", actor, r.Revision(), []byte(value), false)
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func join(t *testing.T, a, b Record) Record {
	t.Helper()
	v, e := Merge(a, b)
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func TestConvergenceAndExplicitConflictResolution(t *testing.T) {
	seed := edit(t, Record{}, "a", `{"name":"initial"}`)
	a := edit(t, seed, "a", `{"name":"offline A"}`)
	b := edit(t, seed, "b", `{"name":"offline B"}`)
	c := edit(t, seed, "c", `{"prompt":"offline C"}`)
	ab := join(t, a, b)
	if len(ab.Versions) != 2 {
		t.Fatal(ab)
	}
	if ab.Revision() != join(t, b, a).Revision() {
		t.Fatal("join is not commutative")
	}
	left := join(t, ab, c)
	right := join(t, a, join(t, b, c))
	if left.Revision() != right.Revision() {
		t.Fatal("join is not associative")
	}
	if join(t, left, left).Revision() != left.Revision() {
		t.Fatal("duplicate delivery changed state")
	}
	if _, e := Put(left, "project-settings", "project", "a", seed.Revision(), []byte(`{}`), false); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	resolved := edit(t, left, "b", `{"name":"reviewed resolution"}`)
	if len(join(t, resolved, left).Versions) != 1 {
		t.Fatal("old snapshot resurrected resolved values")
	}
}
func TestConcurrentDeleteCannotEraseUnseenWrite(t *testing.T) {
	seed := edit(t, Record{}, "a", `{}`)
	deleted, e := Put(seed, "project-settings", "project", "a", seed.Revision(), nil, true)
	if e != nil {
		t.Fatal(e)
	}
	other := edit(t, seed, "b", `{"name":"keep"}`)
	merged := join(t, deleted, other)
	if len(merged.Versions) != 2 {
		t.Fatal(merged)
	}
	resolved, e := Put(merged, "project-settings", "project", "b", merged.Revision(), nil, true)
	if e != nil {
		t.Fatal(e)
	}
	if r := join(t, resolved, other); len(r.Versions) != 1 || !r.Versions[0].Deleted {
		t.Fatal(r)
	}
}
func TestRejectEquivocationAndNonportableSettings(t *testing.T) {
	a := edit(t, Record{}, "a", `{"name":"A"}`)
	b := edit(t, Record{}, "a", `{"name":"B"}`)
	if _, e := Merge(a, b); e == nil {
		t.Fatal("equal clock with different value accepted")
	}
	for _, value := range []string{`{"path":"/private"}`, `{"credentials":"secret"}`, `{"hostnames":["https://user:pass@host"]}`, `null`, `{"name":null}`} {
		r := edit(t, Record{}, "a", value)
		if ValidateSettings(r) == nil {
			t.Fatalf("accepted %s", value)
		}
	}
}
func TestCapacityFailsWithoutDroppingConflict(t *testing.T) {
	var r Record
	for n := 0; n < MaxVersions; n++ {
		r = join(t, r, edit(t, Record{}, string(rune('a'+n)), `{}`))
	}
	_, e := Merge(r, edit(t, Record{}, "z", `{}`))
	if !errors.Is(e, ErrCapacity) {
		t.Fatal(e)
	}
}

func TestPeerJSONEncodingDoesNotCreateFalseEquivocation(t *testing.T) {
	a := edit(t, Record{}, "actor", `{"prompt":"<tag>","name":"test"}`)
	b := Record{Kind: a.Kind, ID: a.ID, Versions: []Version{{Clock: a.Versions[0].Clock, Value: []byte(`{ "name": "test", "prompt": "\u003ctag\u003e" }`)}}}
	merged := join(t, a, b)
	if len(merged.Versions) != 1 || merged.Revision() != a.Revision() {
		t.Fatal(merged)
	}
}
