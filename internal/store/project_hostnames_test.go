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
