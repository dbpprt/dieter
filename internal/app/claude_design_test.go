package app

import (
	"context"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestClaudeCodeTurnsFollowTheMachineClaudeDesignAccess(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := &fakeRunner{}
	service.Runner = runner
	run := func(provider string) bool {
		t.Helper()
		before := runner.count()
		card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Design " + provider, Prompt: "Sketch", Provider: provider})
		if err != nil {
			t.Fatal(err)
		}
		waitFor(t, func() bool {
			value, err := service.Store.ResolveCard(card.ID)
			return err == nil && value.Runtime == "idle" && runner.count() == before+1 && !hasActiveTurn(service, project.ID)
		})
		return runner.request(before).ClaudeDesignEnabled
	}
	if run("claude-code") {
		t.Fatal("Claude Design was enabled before the operator allowed it")
	}
	if _, err := service.Store.SetClaudeDesignAccess(true); err != nil {
		t.Fatal(err)
	}
	if !run("claude-code") {
		t.Fatal("Claude Code turn ignored the machine's Claude Design access")
	}
	if run("codex") {
		t.Fatal("a non-Claude harness received Claude Design access")
	}
	if _, err := service.Store.SetClaudeDesignAccess(false); err != nil {
		t.Fatal(err)
	}
	if run("claude-code") {
		t.Fatal("revoked Claude Design access still reached the next turn")
	}
}
