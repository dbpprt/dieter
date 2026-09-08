package store

import (
	"github.com/dbpprt/dieter/internal/model"
	"reflect"
	"testing"
)

func TestProjectHostnamesAreValidatedAndPersistedAtomically(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowDirect)
	values := []string{" APP.Example.com. ", "localhost", "app.example.com"}
	updated, err := s.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, &values)
	if err != nil || !reflect.DeepEqual(updated.Hostnames, []string{"app.example.com", "localhost"}) {
		t.Fatalf("update=%+v err=%v", updated, err)
	}
	for _, invalid := range []string{"https://example.com", "example.com/path", "example.com:8080", "*.example.com", "", "bad..example", "-bad.example"} {
		name := "must not be written"
		bad := []string{invalid}
		if _, err := s.UpdateProjectWithHostnames(project.ID, &name, nil, nil, nil, &bad); err == nil {
			t.Fatalf("accepted %q", invalid)
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
	_, err := s.UpdateBoardHostnames(board.ID, []string{"ONE.example"}, false)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.UpdateBoardHostnames(board.ID, []string{"two.example", "one.example"}, true)
	if err != nil || !reflect.DeepEqual(updated.Hostnames, []string{"one.example", "two.example"}) {
		t.Fatalf("%+v %v", updated, err)
	}
	if _, err := s.UpdateBoardHostnames(board.ID, []string{"bad/path"}, false); err == nil {
		t.Fatal("accepted invalid hostname")
	}
	persisted, _ := s.ResolveBoard("", board.ID)
	if !reflect.DeepEqual(persisted.Hostnames, updated.Hostnames) {
		t.Fatal("invalid update changed mappings")
	}
	cleared, err := s.UpdateBoardHostnames(board.ID, nil, false)
	if err != nil || len(cleared.Hostnames) != 0 {
		t.Fatalf("%+v %v", cleared, err)
	}
}
