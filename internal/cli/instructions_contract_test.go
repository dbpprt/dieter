package cli

import (
	"bytes"
	"regexp"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
)

// instructionCLI stands in for the daemon's binary in rendered instructions.
const instructionCLI = "/opt/dieter/bin/dieter"

// TestAgentInstructionsNameRealCommandsAndFlags renders every instruction an
// agent turn can receive and checks that each Dieter command in it is a
// command of this CLI whose offline help lists every flag it passes.
func TestAgentInstructionsNameRealCommandsAndFlags(t *testing.T) {
	t.Parallel()
	settings := dieterprompt.NormalizeSettings(model.Settings{})
	detail := model.CardDetail{
		Project: model.Project{ID: "p_one", Name: "Atlas", Path: "/work/atlas"},
		Board: model.Board{ID: "b_one", Name: "Delivery", Workflow: model.WorkflowReview,
			Labels: []model.Label{{ID: "label_docs", Name: "docs"}}},
		Card: model.Card{ID: "c_one", Scope: model.ConversationScopeBoard, Lane: model.LaneRunning, VaultAccess: true, MailAccess: true},
	}
	workspace := model.Workspace{Mode: model.WorkspaceModeProject, Path: "/work/atlas"}
	board, err := dieterprompt.ResolveForWorkspace(settings, detail, nil, workspace, instructionCLI)
	if err != nil {
		t.Fatal(err)
	}
	detail.Card.Scope, detail.Card.BoardID = model.ConversationScopeChat, ""
	chat, err := dieterprompt.ResolveForWorkspace(settings, detail, nil, workspace, instructionCLI)
	if err != nil {
		t.Fatal(err)
	}
	texts := []string{
		board.Instructions, chat.Instructions, dieterprompt.ChannelInstructions(instructionCLI),
		// The worker's CLI equivalents of its presentation and process tools.
		instructionCLI + " card present c_one --path PATH [--line N]", instructionCLI + " chat present c_one --url URL",
		instructionCLI + " remote exec --card c_one --detach -- COMMAND [ARG...]",
	}
	commands := 0
	for _, text := range texts {
		for _, command := range instructionCommands(text) {
			commands++
			if command == "--help" {
				continue
			}
			path, flags := commandPathAndFlags(command)
			if path == "" {
				t.Errorf("instruction names no CLI command: %q", command)
				continue
			}
			var output bytes.Buffer
			client := New(t.TempDir())
			client.Out, client.Err = &output, &output
			if err := client.Run(append(strings.Fields(path), "--help")); err != nil {
				t.Fatalf("dieter %s --help: %v", path, err)
			}
			for _, flag := range flags {
				if !regexp.MustCompile(regexp.QuoteMeta(flag) + `([^a-z-]|$)`).MatchString(output.String()) {
					t.Errorf("dieter %s --help does not list %s (instruction %q)", path, flag, command)
				}
			}
		}
	}
	if commands < 15 {
		t.Fatalf("found only %d instruction commands", commands)
	}
	// The mail block names send flags in its prose too.
	var output bytes.Buffer
	client := New(t.TempDir())
	client.Out, client.Err = &output, &output
	if err := client.Run([]string{"mail", "send", "--help"}); err != nil {
		t.Fatal(err)
	}
	block := dieterprompt.MailInstructions(instructionCLI)
	if !strings.Contains(board.Instructions, block) {
		t.Fatal("the instructions of a conversation with mail access lack the mail block")
	}
	for _, flag := range regexp.MustCompile(`--[a-z][a-z-]*`).FindAllString(block, -1) {
		if !regexp.MustCompile(regexp.QuoteMeta(flag) + `([^a-z-]|$)`).MatchString(output.String()) {
			t.Errorf("dieter mail send --help does not list %s", flag)
		}
	}
}

// instructionCommands returns the text after each mention of the CLI, up to
// the end of its sentence.
func instructionCommands(text string) []string {
	var result []string
	for _, line := range strings.Split(text, "\n") {
		for {
			index := strings.Index(line, instructionCLI+" ")
			if index < 0 {
				break
			}
			line = line[index+len(instructionCLI)+1:]
			command := line
			for _, end := range []string{". ", ").", ")", " lists every", " messages ", " shows ", " lists your"} {
				if cut := strings.Index(command, end); cut >= 0 {
					command = command[:cut]
				}
			}
			result = append(result, strings.TrimSuffix(strings.TrimSpace(command), "."))
		}
	}
	return result
}

// commandPathAndFlags splits a command into its longest documented command
// path and the flags passed before "--".
func commandPathAndFlags(command string) (string, []string) {
	paths := map[string]bool{}
	for _, path := range commandPaths() {
		paths[path] = true
	}
	fields := strings.Fields(command)
	path := ""
	for n := len(fields); n > 0; n-- {
		if candidate := strings.Join(fields[:n], " "); paths[candidate] {
			path = candidate
			fields = fields[n:]
			break
		}
	}
	var flags []string
	for _, field := range fields {
		if field == "--" {
			break
		}
		field = strings.Trim(field, "[]()|,")
		if strings.HasPrefix(field, "--") && len(field) > 2 && field != "--help" {
			flags = append(flags, strings.SplitN(field, "=", 2)[0])
		}
	}
	return path, flags
}
