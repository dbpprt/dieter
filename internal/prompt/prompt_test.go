package prompt

import (
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func promptDetail() model.CardDetail {
	return model.CardDetail{
		Project: model.Project{ID: "p_one", Name: "Atlas", Path: "/work/atlas", Prompt: "Respect the architecture."},
		Board: model.Board{ID: "b_one", Name: "Delivery", Workflow: model.WorkflowReview, Labels: []model.Label{
			{ID: "android", Name: "Android", Instructions: "Run emulator tests."},
			{ID: "security", Name: "Security", Instructions: "Threat-model the change."},
		}},
		Card: model.Card{ID: "c_one", Scope: model.ConversationScopeBoard, Lane: model.LaneRunning, LabelIDs: []string{"security", "android"}},
	}
}

func TestResolveUsesBoardProjectGlobalPrecedenceAndBoardLabelOrder(t *testing.T) {
	detail := promptDetail()
	detail.Project.PromptTemplate = "Project\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	detail.Board.PromptTemplate = "Board\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	resolved, err := Resolve(NormalizeSettings(model.Settings{}), detail, detail.Card.LabelIDs)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Source != "board" || !strings.HasPrefix(resolved.Context, "Board") {
		t.Fatalf("resolution=%#v", resolved)
	}
	android := strings.Index(resolved.Context, "## Android")
	security := strings.Index(resolved.Context, "## Security")
	if android < 0 || security < 0 || android > security {
		t.Fatalf("labels were not rendered in board order: %q", resolved.Context)
	}
	if !strings.Contains(resolved.Skill, "dieter card comment c_one") || !strings.Contains(resolved.Skill, "--lane review") {
		t.Fatalf("Board skill was not rendered: %q", resolved.Skill)
	}
}

func TestContextTemplateRequiresInjectionAnchors(t *testing.T) {
	for _, value := range []string{
		"{{project.instructions_block}}",
		"{{labels.instructions_block}}",
		"{{project.instructions_block}} {{labels.instructions_block}} {{unknown}}",
	} {
		if ValidateContextTemplate(value) == nil {
			t.Fatalf("expected invalid template: %q", value)
		}
	}
}

func TestStandaloneChatUsesProjectOverrideWithoutBoardLabels(t *testing.T) {
	detail := promptDetail()
	detail.Card.Scope, detail.Card.BoardID = model.ConversationScopeChat, ""
	detail.Project.PromptTemplate = "Chat context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	resolved, err := Resolve(NormalizeSettings(model.Settings{}), detail, nil)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Source != "project" || strings.Contains(resolved.Instructions, "Run emulator tests") || !strings.Contains(resolved.Skill, "standalone chat") {
		t.Fatalf("resolution=%#v", resolved)
	}
}

func TestResolveForWorkspaceMakesAssignedWorktreeAuthoritative(t *testing.T) {
	detail := promptDetail()
	detail.Project.PromptTemplate = "Working tree: {{project.path}}\nRegistered: {{project.registered_path}}\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	workspace := model.Workspace{
		Mode: model.WorkspaceModeWorktree, Path: "/dieter/worktrees/c_one", Branch: "dieter/c-one",
		BaseBranch: "main", BaseSHA: "abc123",
	}
	resolved, err := ResolveForWorkspace(NormalizeSettings(model.Settings{}), detail, detail.Card.LabelIDs, workspace)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		"Working tree: /dieter/worktrees/c_one",
		"Registered: /work/atlas",
		workspaceBoundaryHeader,
		"Authoritative working tree: /dieter/worktrees/c_one",
		"Assigned branch: dieter/c-one",
		"registered checkout is outside this conversation's workspace",
	} {
		if !strings.Contains(resolved.Instructions, expected) {
			t.Fatalf("instructions missing %q: %s", expected, resolved.Instructions)
		}
	}
}

func TestBindWorkspaceUpgradesPersistedInstructionsOnce(t *testing.T) {
	workspace := model.Workspace{Mode: model.WorkspaceModeWorktree, Path: "/worktree", Branch: "topic"}
	bound := BindWorkspace("Working tree: /main", "/main", workspace)
	boundAgain := BindWorkspace(bound, "/main", workspace)
	if bound != boundAgain || strings.Count(bound, workspaceBoundaryHeader) != 1 || !strings.Contains(bound, "Ignore any earlier instruction") {
		t.Fatalf("bound instructions=%q", boundAgain)
	}
}
