//go:build !windows

package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestBackgroundProcessesBindConversationAndShareExecutionLifecycle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Path: testRepository(t), Name: "Background"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Owner", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	other, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Other", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	s := New(data, nil)
	t.Cleanup(func() { s.executions.Shutdown(context.Background()) })
	call := func(cardID, operation string, arguments any) (json.RawMessage, error) {
		body, _ := json.Marshal(arguments)
		return s.backgroundProcess(ctx, cardID, harness.ProcessCall{ID: "test-call", Operation: operation, Arguments: body})
	}
	args := map[string]any{"argv": []string{"/bin/sh", "-c", "printf ready; printf problem >&2; exec sleep 30"}, "name": "Preview", "idempotencyKey": "preview-fixture"}
	raw, err := call(card.ID, "start", args)
	if err != nil {
		t.Fatal(err)
	}
	var started dieterv1.Execution
	if err = protojson.Unmarshal(raw, &started); err != nil {
		t.Fatal(err)
	}
	if started.CardId != card.ID || started.ProjectId != project.ID || started.Status != "running" || started.Id == "" {
		t.Fatalf("start=%s", raw)
	}
	repeated, err := call(card.ID, "start", args)
	if err != nil {
		t.Fatal(err)
	}
	var repeatedValue dieterv1.Execution
	_ = protojson.Unmarshal(repeated, &repeatedValue)
	if repeatedValue.Id != started.Id {
		t.Fatal("idempotent admission created a second process")
	}
	api := &grpcAPI{server: s}
	listed, err := api.ListExecutions(ctx, &dieterv1.ListExecutionsRequest{CardId: card.ID})
	if err != nil || len(listed.GetExecutions()) != 1 || listed.Executions[0].Id != started.Id {
		t.Fatalf("native/CLI list=%v err=%v", listed, err)
	}
	for _, operation := range []string{"read", "stop"} {
		if _, err := call(other.ID, operation, map[string]any{"executionId": started.Id}); err == nil {
			t.Fatalf("%s crossed conversation ownership", operation)
		}
	}
	for _, invalid := range []map[string]any{
		{"argv": []string{"/bin/pwd"}, "workingDirectory": t.TempDir()},
		{"argv": []string{"/bin/pwd"}, "cardId": other.ID},
	} {
		if _, err := call(card.ID, "start", invalid); err == nil {
			t.Fatalf("accepted invalid input=%v", invalid)
		}
	}
	var page json.RawMessage
	for {
		page, err = call(card.ID, "read", map[string]any{"executionId": started.Id})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(page), "ready") && strings.Contains(string(page), "problem") {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("output did not arrive")
		case <-time.After(10 * time.Millisecond):
		}
	}
	if !strings.Contains(string(page), `"stdout"`) || !strings.Contains(string(page), `"stderr"`) {
		t.Fatalf("separate streams missing: %s", page)
	}
	stopped, err := call(card.ID, "stop", map[string]any{"executionId": started.Id})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(stopped), started.Id) {
		t.Fatalf("stop=%s", stopped)
	}
	for {
		retained, err := api.GetExecution(ctx, &dieterv1.ExecutionRef{ExecutionId: started.Id})
		if err != nil {
			t.Fatal(err)
		}
		if retained.Status == "canceled" {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("explicit stop did not terminate the process")
		case <-time.After(10 * time.Millisecond):
		}
	}
}
