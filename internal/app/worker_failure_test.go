package app

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestWorkerFailurePersistsTerminalCapabilities(t *testing.T) {
	for _, failure := range []struct {
		name, script, message string
	}{
		{"truncated checkpoint", `process.stdout.write('{"type":"session","state":');`, "decode harness worker output: unexpected end of JSON input"},
		{"worker crash", `process.stderr.write('fixture worker crashed'); process.exitCode = 1;`, "fixture worker crashed"},
	} {
		t.Run(failure.name, func(t *testing.T) {
			service, _, project, board := appSetup(t)
			runtimeDir := t.TempDir()
			// The production Go subprocess decoder, service lifecycle and store all
			// run here; only the provider worker is a disposable local fixture.
			script := `process.stdin.once('data', raw => {
  const request = JSON.parse(raw);
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  send({type:'chunk', chunk:{type:'start', messageId:request.responseMessageId}});
  for (const status of ['completed', 'running', 'pending', 'failed', 'aborted']) {
    send({type:'capability', capability:{id:'subagents', operation:'upsert', subagent:{
      id:status, provider:request.harness, messageId:request.responseMessageId, status,
      recentOutput:['saved research'], updatedAt:'2026-01-01T00:00:00Z'
    }}});
  }
  send({type:'capability', capability:{id:'task-plan', operation:'replace', plan:{
    id:'plan', provider:request.harness, messageId:request.responseMessageId, state:'active',
    phases:[{tasks:[{content:'Research',status:'completed'},{content:'Synthesize',status:'in_progress'}]}]
  }}});
  ` + failure.script + `
});`
			if err := os.WriteFile(filepath.Join(runtimeDir, "runner.mjs"), []byte(script), 0600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("DIETER_HARNESS_RUNTIME_DIR", runtimeDir)
			service.Runner = harness.NewSubprocessRunner(t.TempDir())
			card, err := service.CreateCard(context.Background(), CardInput{
				Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
				Title: "Worker failure", Prompt: "Research", Provider: "claude-code", Model: "opus", DeferStart: true,
			})
			if err != nil {
				t.Fatal(err)
			}
			updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			var turnError error
			go func() {
				defer close(done)
				for update := range updates {
					if update.Err != nil {
						turnError = update.Err
					}
				}
			}()
			select {
			case <-done:
			case <-time.After(20 * time.Second):
				t.Fatal("worker failure did not terminate its turn")
			}
			if turnError == nil || !strings.Contains(turnError.Error(), failure.message) {
				t.Fatalf("turn error=%v", turnError)
			}
			// Reopen the store to verify what native clients receive after a restart,
			// not merely the in-memory objects used by the failed worker.
			reopened := store.New(service.Store.Root)
			conversation, err := reopened.Conversation(card.ID)
			if err != nil {
				t.Fatal(err)
			}
			if conversation.Status != "failed" || conversation.ActiveTurn != nil || len(conversation.Subagents) != 5 {
				t.Fatalf("failed conversation=%+v", conversation)
			}
			for _, agent := range conversation.Subagents {
				want := agent.ID
				if want == "running" || want == "pending" {
					want = "failed"
					if agent.EndedAt == "" || agent.Activity != "Failed" {
						t.Fatalf("unfinished agent=%+v", agent)
					}
				}
				if agent.Status != want || len(agent.RecentOutput) != 1 || agent.RecentOutput[0] != "saved research" {
					t.Fatalf("agent=%+v want status %q with retained output", agent, want)
				}
			}
			if len(conversation.TaskPlans) != 1 || conversation.TaskPlans[0].State != "failed" {
				t.Fatalf("plans=%+v", conversation.TaskPlans)
			}
			tasks := conversation.TaskPlans[0].Phases[0].Tasks
			if tasks[0].Status != "completed" || tasks[1].Status != "abandoned" {
				t.Fatalf("tasks=%+v", tasks)
			}
			stored, err := reopened.ResolveCard(card.ID)
			if err != nil || stored.Runtime != "failed" {
				t.Fatalf("card runtime=%q err=%v", stored.Runtime, err)
			}
		})
	}
}
