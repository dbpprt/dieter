package kanban_test

import (
	"reflect"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestProjectHostnamesAreValidatedAndPersistedAtomically(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowDirect)
	values := []string{" APP.Example.com. ", "localhost:04018", "app.example.com", "APP.Example.com.:443", "[0:0:0:0:0:0:0:1]:4018"}
	updated, err := s.Kanban.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, &values)
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
		if _, err := s.Kanban.UpdateProjectWithHostnames(project.ID, &name, nil, nil, nil, &bad); err == nil {
			t.Fatalf("accepted %q", invalid)
		}
		persisted, err := s.Kanban.ResolveProject(project.ID)
		if err != nil || persisted.Name != project.Name || !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
			t.Fatalf("invalid mutation %q leaked: %+v err=%v", invalid, persisted, err)
		}
	}
	persisted, err := s.Kanban.ResolveProject(project.ID)
	if err != nil || persisted.Name != project.Name || !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
		t.Fatalf("invalid mutation leaked: %+v err=%v", persisted, err)
	}
	preserved, err := s.Kanban.UpdateProject(project.ID, nil, nil, nil)
	if err != nil || !reflect.DeepEqual(preserved.Hostnames, updated.Hostnames) {
		t.Fatalf("lost mappings: %+v %v", preserved, err)
	}
	empty := []string{}
	if _, err := s.Kanban.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, &empty); err != nil {
		t.Fatal(err)
	}
	cleared, _ := s.Kanban.ResolveProject(project.ID)
	if len(cleared.Hostnames) != 0 {
		t.Fatalf("not cleared: %+v", cleared.Hostnames)
	}
}

func TestBoardHostnamesAppendAndClear(t *testing.T) {
	t.Parallel()
	s, _, board := testkit.BoardStore(t, model.WorkflowDirect)
	_, err := s.Kanban.UpdateBoardHostnames(board.ID, []string{"ONE.example", "localhost:4018"}, false)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.Kanban.UpdateBoardHostnames(board.ID, []string{"two.example:65535", "one.example", "LOCALHOST:04018", "[::1]:4018"}, true)
	if err != nil || !reflect.DeepEqual(updated.Hostnames, []string{"[::1]:4018", "localhost:4018", "one.example", "two.example:65535"}) {
		t.Fatalf("%+v %v", updated, err)
	}
	for _, appendValues := range []bool{false, true} {
		if _, err := s.Kanban.UpdateBoardHostnames(board.ID, []string{"valid.example:1", "localhost:65536"}, appendValues); err == nil {
			t.Fatal("accepted invalid port")
		}
		persisted, _ := s.Kanban.ResolveBoard("", board.ID)
		if !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
			t.Fatal("invalid update changed mappings")
		}
	}
	cleared, err := s.Kanban.UpdateBoardHostnames(board.ID, nil, false)
	if err != nil || len(cleared.Hostnames) != 0 {
		t.Fatalf("%+v %v", cleared, err)
	}
}
