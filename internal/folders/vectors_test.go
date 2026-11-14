package folders

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

type vectors struct {
	Actors []struct {
		Member string `json:"member"`
		Actor  string `json:"actor"`
	} `json:"actors"`
	Compare []struct {
		A, B   Version
		Expect string
	} `json:"compare"`
	Merge []struct {
		A, B, Expect Version
	} `json:"merge"`
	Bump []struct {
		Version Version `json:"version"`
		Actor   string  `json:"actor"`
		Expect  Version `json:"expect"`
	} `json:"bump"`
	Decide []struct {
		Name   string `json:"name"`
		Mode   Mode   `json:"mode"`
		Local  *Entry `json:"local"`
		Remote Entry  `json:"remote"`
		Expect struct {
			Action       Action `json:"action"`
			Result       *Entry `json:"result"`
			Conflict     bool   `json:"conflict"`
			ConflictCopy string `json:"conflictCopy"`
		} `json:"expect"`
	} `json:"decide"`
	ConflictNames []struct {
		Path     string `json:"path"`
		Author   string `json:"author"`
		Modified int64  `json:"modified"`
		Expect   string `json:"expect"`
	} `json:"conflictNames"`
	ValidatePath []struct {
		Path  string `json:"path"`
		Valid bool   `json:"valid"`
	} `json:"validatePath"`
	Rules []struct {
		Rules    []string `json:"rules"`
		Path     string   `json:"path"`
		Included bool     `json:"included"`
	} `json:"rules"`
	InvalidRules [][]string `json:"invalidRules"`
	Guard        []struct {
		Policy    Guard `json:"policy"`
		Deletions int   `json:"deletions"`
		Total     int   `json:"total"`
		Trips     bool  `json:"trips"`
	} `json:"guard"`
	Portable []struct {
		Path     string `json:"path"`
		Portable bool   `json:"portable"`
	} `json:"portable"`
	FoldKeys []struct {
		Path   string `json:"path"`
		Expect string `json:"expect"`
	} `json:"foldKeys"`
	Ordered struct {
		Entries []Entry  `json:"entries"`
		Expect  []string `json:"expect"`
	} `json:"ordered"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "tests", "fixtures", "folders", "vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func sameVersion(a, b Version) bool { return len(a) == len(b) && (len(a) == 0 || slices.Equal(a, b)) }

func sameEntry(a, b Entry) bool {
	return a.Path == b.Path && a.Kind == b.Kind && a.Size == b.Size && a.Modified == b.Modified &&
		a.Executable == b.Executable && a.SHA256 == b.SHA256 && a.Sequence == b.Sequence &&
		a.AuthorID == b.AuthorID && a.AuthorName == b.AuthorName && sameVersion(a.Version, b.Version)
}

func TestGoldenVectors(t *testing.T) {
	v := loadVectors(t)
	for _, c := range v.Actors {
		if got := ActorOf(c.Member); got != c.Actor {
			t.Errorf("ActorOf(%q) = %s, want %s", c.Member, got, c.Actor)
		}
	}
	for _, c := range v.Compare {
		if got := Compare(c.A, c.B).String(); got != c.Expect {
			t.Errorf("Compare(%v, %v) = %s, want %s", c.A, c.B, got, c.Expect)
		}
	}
	for _, c := range v.Merge {
		if got := Merge(c.A, c.B); !sameVersion(got, c.Expect) {
			t.Errorf("Merge(%v, %v) = %v, want %v", c.A, c.B, got, c.Expect)
		}
	}
	for _, c := range v.Bump {
		if got := c.Version.Bump(c.Actor); !sameVersion(got, c.Expect) {
			t.Errorf("Bump(%v, %s) = %v, want %v", c.Version, c.Actor, got, c.Expect)
		}
	}
	for _, c := range v.Decide {
		if c.Local != nil {
			if err := c.Local.Validate(); err != nil {
				t.Errorf("%s: invalid local: %v", c.Name, err)
			}
		}
		if err := c.Remote.Validate(); err != nil {
			t.Errorf("%s: invalid remote: %v", c.Name, err)
		}
		got := Decide(c.Local, c.Remote, c.Mode)
		if got.Action != c.Expect.Action || got.Conflict != c.Expect.Conflict || got.ConflictCopy != c.Expect.ConflictCopy {
			t.Errorf("%s: got %s conflict=%v copy=%q, want %s conflict=%v copy=%q", c.Name, got.Action, got.Conflict, got.ConflictCopy, c.Expect.Action, c.Expect.Conflict, c.Expect.ConflictCopy)
		}
		if c.Expect.Result != nil && !sameEntry(got.Result, *c.Expect.Result) {
			t.Errorf("%s: result %+v, want %+v", c.Name, got.Result, *c.Expect.Result)
		}
	}
	for _, c := range v.ConflictNames {
		if got := ConflictName(c.Path, c.Author, c.Modified); got != c.Expect {
			t.Errorf("ConflictName(%q) = %q, want %q", c.Path, got, c.Expect)
		}
	}
	for _, c := range v.ValidatePath {
		if err := ValidatePath(c.Path); (err == nil) != c.Valid {
			t.Errorf("ValidatePath(%q) = %v, want valid=%v", c.Path, err, c.Valid)
		}
	}
	for _, c := range v.Rules {
		values := c.Rules
		if len(values) == 1 && values[0] == "DEFAULT" {
			values = DefaultRules
		}
		rules, err := ParseRules(values)
		if err != nil {
			t.Fatalf("ParseRules(%v): %v", values, err)
		}
		if got := Included(c.Path, rules); got != c.Included {
			t.Errorf("Included(%q, %v) = %v, want %v", c.Path, c.Rules, got, c.Included)
		}
	}
	for _, values := range v.InvalidRules {
		if _, err := ParseRules(values); err == nil {
			t.Errorf("ParseRules(%v) accepted an invalid rule", values)
		}
	}
	for _, c := range v.Guard {
		if got := GuardTrips(c.Policy, c.Deletions, c.Total); got != c.Trips {
			t.Errorf("GuardTrips(%s, %d, %d) = %v, want %v", c.Policy, c.Deletions, c.Total, got, c.Trips)
		}
	}
	for _, c := range v.Portable {
		if got := Portable(c.Path); got != c.Portable {
			t.Errorf("Portable(%q) = %v", c.Path, got)
		}
	}
	for _, c := range v.FoldKeys {
		if got := FoldKey(c.Path); got != c.Expect {
			t.Errorf("FoldKey(%q) = %q, want %q", c.Path, got, c.Expect)
		}
	}
	var order []string
	for _, e := range Ordered(v.Ordered.Entries) {
		order = append(order, e.Path)
	}
	if !slices.Equal(order, v.Ordered.Expect) {
		t.Errorf("Ordered = %v, want %v", order, v.Ordered.Expect)
	}
}

func FuzzValidateEntry(f *testing.F) {
	f.Add("a/b.txt", "file", int64(3), "1111111111111111111111111111111111111111111111111111111111111111")
	f.Add("../x", "directory", int64(0), "")
	f.Fuzz(func(t *testing.T, p, kind string, size int64, sha string) {
		e := Entry{Path: p, Kind: Kind(kind), Size: size, SHA256: sha, Version: Version{{Actor: "aaaaaaaaaaaaaaaa", Value: 1}}}
		if e.Validate() == nil {
			if ValidatePath(e.Path) != nil || e.Size < 0 {
				t.Fatalf("accepted %+v", e)
			}
		}
	})
}
