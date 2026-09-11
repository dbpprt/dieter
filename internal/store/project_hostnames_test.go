package store

import (
	"reflect"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestProjectHostnamesAreValidatedAndPersistedAtomically(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowDirect)
	values := []string{" APP.Example.com. ", "localhost:04018", "app.example.com", "APP.Example.com.:443", "[0:0:0:0:0:0:0:1]:4018"}
	updated, err := s.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, &values)
	if err != nil || !reflect.DeepEqual(updated.Hostnames, []string{"[::1]:4018", "app.example.com", "app.example.com:443", "localhost:4018"}) {
		t.Fatalf("update=%+v err=%v", updated, err)
	}
	for _, invalid := range []string{
		"https://example.com", "example.com/path", "*.example.com", "", "bad..example", "-bad.example",
		"localhost:", "localhost:0", "localhost:65536", "localhost:-1", "localhost:+80", "localhost:http",
		"localhost: 80", "localhost:80/path", "localhost:80?query", "localhost:80#fragment", "localhost:80:90",
		"[::1]:", "[::1]:0", "[::1]:65536", "[::1]:https", "[example.com]:80", "[127.0.0.1]:80", "[::1", "::1]",
		"[fe80::1%en0]:4018", "user@localhost:4018", "[::zz]:4018",
	} {
		name := "must not be written"
		bad := []string{"valid.example:4018", invalid}
		if _, err := s.UpdateProjectWithHostnames(project.ID, &name, nil, nil, nil, &bad); err == nil {
			t.Fatalf("accepted %q", invalid)
		}
		persisted, err := s.ResolveProject(project.ID)
		if err != nil || persisted.Name != project.Name || !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
			t.Fatalf("invalid mutation %q leaked: %+v err=%v", invalid, persisted, err)
		}
	}
	persisted, err := s.ResolveProject(project.ID)
	if err != nil || persisted.Name != project.Name || !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
		t.Fatalf("invalid mutation leaked: %+v err=%v", persisted, err)
	}
	preserved, err := s.UpdateProject(project.ID, nil, nil, nil)
	if err != nil || !reflect.DeepEqual(preserved.Hostnames, updated.Hostnames) {
		t.Fatalf("lost mappings: %+v %v", preserved, err)
	}
	empty := []string{}
	if _, err := s.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, &empty); err != nil {
		t.Fatal(err)
	}
	cleared, _ := s.ResolveProject(project.ID)
	if len(cleared.Hostnames) != 0 {
		t.Fatalf("not cleared: %+v", cleared.Hostnames)
	}
}

func TestBoardHostnamesAppendAndClear(t *testing.T) {
	s, _, board := setup(t, model.WorkflowDirect)
	_, err := s.UpdateBoardHostnames(board.ID, []string{"ONE.example", "localhost:4018"}, false)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.UpdateBoardHostnames(board.ID, []string{"two.example:65535", "one.example", "LOCALHOST:04018", "[::1]:4018"}, true)
	if err != nil || !reflect.DeepEqual(updated.Hostnames, []string{"[::1]:4018", "localhost:4018", "one.example", "two.example:65535"}) {
		t.Fatalf("%+v %v", updated, err)
	}
	for _, appendValues := range []bool{false, true} {
		if _, err := s.UpdateBoardHostnames(board.ID, []string{"valid.example:1", "localhost:65536"}, appendValues); err == nil {
			t.Fatal("accepted invalid port")
		}
		persisted, _ := s.ResolveBoard("", board.ID)
		if !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
			t.Fatal("invalid update changed mappings")
		}
	}
	cleared, err := s.UpdateBoardHostnames(board.ID, nil, false)
	if err != nil || len(cleared.Hostnames) != 0 {
		t.Fatalf("%+v %v", cleared, err)
	}
}

func TestProjectHostnameMappingsPreservePortsAndCanonicalizeAddresses(t *testing.T) {
	values := []string{
		" EXAMPLE.COM. ", "example.com", "EXAMPLE.COM.:00080", "example.com:80", "example.com:443",
		"localhost:1", "localhost:65535", "127.0.0.1", "127.0.0.1:04018",
		"2001:0DB8:0:0:0:0:0:1", "[2001:db8::1]", "[2001:0DB8::1]:04018", "::1", "::1:4018",
	}
	want := []string{
		"127.0.0.1", "127.0.0.1:4018", "2001:db8::1", "::1", "::1:4018", "[2001:db8::1]:4018",
		"example.com", "example.com:443", "example.com:80", "localhost:1", "localhost:65535",
	}
	got, err := normalizeProjectHostnames(values)
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("normalized=%v want=%v err=%v", got, want, err)
	}
	// A bare IPv6 address's final digits are address bytes, never an inferred port.
	if got, err := normalizeProjectHostnames([]string{"::1:4018", "[::1]:4018"}); err != nil || !reflect.DeepEqual(got, []string{"::1:4018", "[::1]:4018"}) {
		t.Fatalf("IPv6 address and port conflated: %v %v", got, err)
	}
	if _, err := normalizeProjectHostnames([]string{strings.Repeat("a", 64) + ".example:4018"}); err == nil {
		t.Fatal("accepted overlong DNS label with a port")
	}
	if _, err := normalizeProjectHostnames(make([]string, 65)); err == nil {
		t.Fatal("accepted more than 64 mappings")
	}
}
