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
	t.Parallel()
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
	if !strings.Contains(resolved.Skill, "dieter card context c_one") || !strings.Contains(resolved.Skill, "--lane review") {
		t.Fatalf("Board skill was not rendered: %q", resolved.Skill)
	}
}

func TestContextTemplateRequiresInjectionAnchors(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
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
	t.Parallel()
	detail := promptDetail()
	detail.Project.PromptTemplate = "Working tree: {{project.path}}\nRegistered: {{project.registered_path}}\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	workspace := model.Workspace{
		Mode: model.WorkspaceModeWorktree, Path: "/dieter/worktrees/c_one", Branch: "dieter/c-one",
		BaseBranch: "main", BaseRemote: "private", BaseSHA: "abc123", RemotePublishMode: model.RemotePublishPullRequest,
	}
	resolved, err := ResolveForWorkspace(NormalizeSettings(model.Settings{}), detail, detail.Card.LabelIDs, workspace, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		"Working tree: /dieter/worktrees/c_one",
		"Registered: /work/atlas",
		workspaceBoundaryHeader,
		"Authoritative working tree: /dieter/worktrees/c_one",
		"Assigned branch: dieter/c-one",
		"Base branch: main",
		"Configured base remote: private",
		"Remote publish mode: pull_request",
		"registered checkout is outside this conversation's workspace",
	} {
		if !strings.Contains(resolved.Instructions, expected) {
			t.Fatalf("instructions missing %q: %s", expected, resolved.Instructions)
		}
	}
}

func TestBindWorkspaceUpgradesPersistedInstructionsOnce(t *testing.T) {
	t.Parallel()
	workspace := model.Workspace{Mode: model.WorkspaceModeWorktree, Path: "/worktree", Branch: "topic"}
	bound := BindWorkspace("Working tree: /main", "/main", workspace)
	boundAgain := BindWorkspace(bound, "/main", workspace)
	if bound != boundAgain || strings.Count(bound, workspaceBoundaryHeader) != 1 || !strings.Contains(bound, "Ignore any earlier instruction") {
		t.Fatalf("bound instructions=%q", boundAgain)
	}
}

func TestDefaultInstructionsRunTheDaemonsCLI(t *testing.T) {
	t.Parallel()
	detail := promptDetail()
	detail.Card.VaultAccess, detail.Card.MailAccess = true, true
	workspace := model.Workspace{Mode: model.WorkspaceModeProject, Path: "/work/atlas"}
	cli := CLIWord("/opt/homebrew/var/dieter/service/bin/dieter")
	resolved, err := ResolveForWorkspace(NormalizeSettings(model.Settings{}), detail, detail.Card.LabelIDs, workspace, cli)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		"This conversation is card c_one on board Delivery.",
		cli + " --help lists every command",
		cli + " card context c_one",
		cli + " card move c_one --lane review",
		cli + " card create --project p_one --board b_one --workspace project --title",
		"Board labels: Android (android), Security (security).",
		cli + " card labels c_one --set",
		cli + " vault exec ITEM --env NAME=password",
		"## Mail to the user",
		cli + ` mail send --subject "Nightly audit: 3 critical" --body-file report.md`,
	} {
		if !strings.Contains(resolved.Instructions, expected) {
			t.Fatalf("instructions missing %q:\n%s", expected, resolved.Instructions)
		}
	}
	// Every command names the daemon's binary; the harness runtime explains
	// its own tools, so the templates do not repeat them.
	for _, unexpected := range []string{"`dieter ", " dieter card", " dieter vault", " dieter mail", "present_content", "start_background_process"} {
		if strings.Contains(resolved.Instructions, unexpected) {
			t.Fatalf("instructions contain %q:\n%s", unexpected, resolved.Instructions)
		}
	}
	detail.Card.Scope, detail.Card.BoardID, detail.Card.VaultAccess, detail.Card.MailAccess = model.ConversationScopeChat, "", false, false
	chat, err := ResolveForWorkspace(NormalizeSettings(model.Settings{}), detail, nil, workspace, cli)
	if err != nil {
		t.Fatal(err)
	}
	// A conversation without mail access never learns how to send mail.
	for _, unexpected := range []string{"mail send", "Dieter Mail", "vault exec"} {
		if strings.Contains(chat.Instructions, unexpected) {
			t.Fatalf("instructions without access contain %q:\n%s", unexpected, chat.Instructions)
		}
	}
	if !strings.Contains(chat.Skill, "standalone chat c_one") || !strings.Contains(chat.Skill, cli+" chat --help") || strings.Contains(chat.Skill, "card move") {
		t.Fatalf("chat skill = %q", chat.Skill)
	}
}

func TestCLIWordQuotesOnlyWhenNeeded(t *testing.T) {
	t.Parallel()
	for path, want := range map[string]string{
		"":                           "dieter",
		"/usr/local/bin/dieter":      "/usr/local/bin/dieter",
		"/Users/a b/bin/dieter":      "'/Users/a b/bin/dieter'",
		"/opt/dieter's/bin/dieter":   `'/opt/dieter'\''s/bin/dieter'`,
		"/home/me/.local/bin/dieter": "/home/me/.local/bin/dieter",
	} {
		if got := CLIWord(path); got != want {
			t.Fatalf("CLIWord(%q) = %q, want %q", path, got, want)
		}
	}
}
