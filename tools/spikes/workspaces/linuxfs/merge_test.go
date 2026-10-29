package linuxfs

import (
	"maps"
	"testing"

	"dieter.spike/workspaces/core"
)

func file(h string) core.Entry { return core.Entry{Type: core.File, Mode: 0o644, Size: 1, Hash: h} }

var dirEntry = core.Entry{Type: core.Dir, Mode: 0o755}

func kinds(cs core.ChangeSet) map[string]core.ChangeKind {
	out := map[string]core.ChangeKind{}
	for p, c := range cs {
		out[p] = c.Kind
	}
	return out
}

func syntheticLower() core.Tree {
	return core.Tree{
		"a": file("a"), "f": file("f"), "l": {Type: core.Symlink, Size: 1, Target: "a"},
		"d": dirEntry, "d/x": file("x"), "d/y": file("y"), "d/s": dirEntry, "d/s/z": file("z"),
		"o": dirEntry, "o/1": file("1"),
	}
}

func up(p string, e core.Entry) UpperEntry { return UpperEntry{Path: p, Entry: e} }

func TestDiffUpperSynthetic(t *testing.T) {
	lower := syntheticLower()
	cases := []struct {
		name      string
		upper     map[string]UpperEntry
		want      map[string]core.ChangeKind
		identical int
	}{
		{
			name: "mixed",
			upper: map[string]UpperEntry{
				"a": up("a", file("a2")), "d": up("d", dirEntry), "d/x": {Path: "d/x", Deleted: true},
				"o": {Path: "o", Opaque: true, Entry: dirEntry}, "o/2": up("o/2", file("2")),
				"f": {Path: "f", Opaque: true, Entry: dirEntry}, "l": up("l", lower["l"]), "n": up("n", file("n")),
			},
			want: map[string]core.ChangeKind{
				"a": core.Modified, "d/x": core.Deleted, "o/1": core.Deleted, "o/2": core.Added,
				"f": core.TypeChanged, "n": core.Added,
			},
			identical: 1,
		},
		{
			name:  "dir whiteout",
			upper: map[string]UpperEntry{"d": {Path: "d", Deleted: true}},
			want:  map[string]core.ChangeKind{"d/x": core.Deleted, "d/y": core.Deleted, "d/s/z": core.Deleted},
		},
		{
			name:  "file over dir",
			upper: map[string]UpperEntry{"d": up("d", file("d"))},
			want: map[string]core.ChangeKind{"d": core.TypeChanged, "d/x": core.Deleted, "d/y": core.Deleted,
				"d/s/z": core.Deleted},
		},
		{
			name: "nested dir under opaque",
			upper: map[string]UpperEntry{"d": {Path: "d", Opaque: true, Entry: dirEntry},
				"d/s": up("d/s", dirEntry), "d/s/q": up("d/s/q", file("q"))},
			want: map[string]core.ChangeKind{"d/x": core.Deleted, "d/y": core.Deleted, "d/s/z": core.Deleted,
				"d/s/q": core.Added},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cs, st := diffUpper(lower, c.upper)
			if got := kinds(cs); !maps.Equal(got, c.want) {
				t.Fatalf("changes = %v, want %v", got, c.want)
			}
			if st.Identical != c.identical {
				t.Fatalf("identical = %d, want %d", st.Identical, c.identical)
			}
			eff := Overlay{}.Effective(lower, c.upper)
			if got := kinds(core.DiffTrees(lower, eff)); !maps.Equal(got, c.want) {
				t.Fatalf("effective diff = %v, want %v", got, c.want)
			}
		})
	}
}

func TestChangesBetweenSynthetic(t *testing.T) {
	lower := syntheticLower()
	prev := map[string]UpperEntry{"a": up("a", file("a2")), "n": up("n", file("n"))}
	cur := map[string]UpperEntry{
		"a": up("a", file("a")), // reverted to the lower content
		"d": {Path: "d", Deleted: true},
		"m": up("m", file("m")),
	}
	want := map[string]core.ChangeKind{
		"a": core.Modified, "n": core.Deleted, "m": core.Added,
		"d/x": core.Deleted, "d/y": core.Deleted, "d/s/z": core.Deleted,
	}
	if got := kinds(ChangesBetween(prev, cur, lower)); !maps.Equal(got, want) {
		t.Fatalf("between = %v, want %v", got, want)
	}
	// Truth: diff of the two effective views.
	o := Overlay{}
	truth := kinds(core.DiffTrees(o.Effective(lower, prev), o.Effective(lower, cur)))
	if !maps.Equal(truth, want) {
		t.Fatalf("effective diff = %v, want %v", truth, want)
	}
	if got := ChangesBetween(cur, cur, lower); len(got) != 0 {
		t.Fatalf("no-op between = %v", kinds(got))
	}
}
