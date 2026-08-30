package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

const settingsHelp = `Usage: dieter settings <action>

Actions:
  show                         Show parallel-session admission settings
  options                      List valid projects, boards, and harnesses
  update [options]             Replace admission settings

Update accepts --global N, repeated --harness ID=N, repeated --board ID=N,
or --file FILE containing the Settings JSON object emitted by "show".
`

func (c *CLI) rpcSettings(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, settingsHelp)
		return nil
	}
	switch args[0] {
	case "show", "get":
		const usage = "Usage: dieter settings show\n"
		if wantsHelp(args[1:]) {
			fmt.Fprint(c.Out, usage)
			return nil
		}
		if len(args) != 1 {
			return errors.New("settings show does not accept arguments")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		value, err := client.GetSettings(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "options":
		const usage = "Usage: dieter settings options\n"
		if wantsHelp(args[1:]) {
			fmt.Fprint(c.Out, usage)
			return nil
		}
		if len(args) != 1 {
			return errors.New("settings options does not accept arguments")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		value, err := client.GetSettingsOptions(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "update", "set":
		return c.rpcSettingsUpdate(args[1:])
	default:
		return fmt.Errorf("unknown settings action %q; run `dieter settings --help`", args[0])
	}
}

type limitFlags map[string]int32

func (values *limitFlags) String() string { return "ID=N" }

func (values *limitFlags) Set(raw string) error {
	key, value, found := strings.Cut(raw, "=")
	if !found || strings.TrimSpace(key) == "" {
		return errors.New("limits must be ID=N")
	}
	parsed, err := strconv.ParseInt(value, 10, 32)
	if err != nil || parsed < 0 {
		return fmt.Errorf("invalid non-negative limit %q", value)
	}
	if *values == nil {
		*values = map[string]int32{}
	}
	(*values)[strings.TrimSpace(key)] = int32(parsed)
	return nil
}

func (c *CLI) rpcSettingsUpdate(args []string) error {
	const usage = "Usage: dieter settings update [--global N] [--harness ID=N ...] [--board ID=N ...] [--file FILE]\n"
	set := flags("settings update")
	global := set.Int("global", -1, "global parallel-session limit")
	file := set.String("file", "", "Settings JSON file or - for stdin")
	harnessLimits, boardLimits := limitFlags{}, limitFlags{}
	set.Var(&harnessLimits, "harness", "harness limit ID=N; repeatable")
	set.Var(&boardLimits, "board", "board limit ID=N; repeatable")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("settings update does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetSettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if strings.TrimSpace(*file) != "" {
		var raw []byte
		if *file == "-" {
			raw, err = io.ReadAll(io.LimitReader(c.In, (4<<20)+1))
			if err == nil && len(raw) > 4<<20 {
				err = errors.New("settings JSON exceeds 4 MiB")
			}
		} else {
			raw, err = os.ReadFile(*file)
		}
		if err != nil {
			return err
		}
		var decoded struct {
			GlobalParallelLimit int32            `json:"globalParallelLimit"`
			AgentParallelLimits map[string]int32 `json:"agentParallelLimits"`
			BoardParallelLimits map[string]int32 `json:"boardParallelLimits"`
		}
		if err := json.Unmarshal(raw, &decoded); err != nil {
			return fmt.Errorf("decode settings JSON: %w", err)
		}
		value.GlobalParallelLimit = decoded.GlobalParallelLimit
		value.AgentParallelLimits = decoded.AgentParallelLimits
		value.BoardParallelLimits = decoded.BoardParallelLimits
	}
	if *global >= 0 {
		value.GlobalParallelLimit = int32(*global)
	}
	if len(harnessLimits) > 0 {
		value.AgentParallelLimits = map[string]int32(harnessLimits)
	}
	if len(boardLimits) > 0 {
		value.BoardParallelLimits = map[string]int32(boardLimits)
	}
	updated, err := client.UpdateSettings(rpcCtx, &dieterv1.UpdateSettingsRequest{Settings: value})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

const promptHelp = `Usage: dieter prompt <action>

Actions:
  show                         Show global prompt and skill templates
  update [options]             Update global templates
  project [options] PROJECT    Set or inherit a project prompt template
  board [options] BOARD        Set or inherit a board prompt template
  preview [options]            Render the effective prompt for a scope
`

func (c *CLI) rpcPrompt(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, promptHelp)
		return nil
	}
	switch args[0] {
	case "show", "get":
		const usage = "Usage: dieter prompt show\n"
		if wantsHelp(args[1:]) {
			fmt.Fprint(c.Out, usage)
			return nil
		}
		if len(args) != 1 {
			return errors.New("prompt show does not accept arguments")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		value, err := client.GetPromptSettings(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "update", "set":
		return c.rpcPromptUpdate(args[1:])
	case "project", "board":
		return c.rpcPromptScope(args[0], args[1:])
	case "preview":
		return c.rpcPromptPreview(args[1:])
	default:
		return fmt.Errorf("unknown prompt action %q; run `dieter prompt --help`", args[0])
	}
}

func promptText(c *CLI, inline, path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return inline, nil
	}
	return textValue("", path, c.In)
}

func (c *CLI) rpcPromptUpdate(args []string) error {
	const usage = "Usage: dieter prompt update [--template TEXT|--template-file FILE] [--board-skill TEXT|--board-skill-file FILE] [--chat-skill TEXT|--chat-skill-file FILE]\n"
	set := flags("prompt update")
	template := set.String("template", "", "global prompt template")
	templateFile := set.String("template-file", "", "global prompt template file or -")
	boardSkill := set.String("board-skill", "", "board skill template")
	boardSkillFile := set.String("board-skill-file", "", "board skill template file")
	chatSkill := set.String("chat-skill", "", "chat skill template")
	chatSkillFile := set.String("chat-skill-file", "", "chat skill template file")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("prompt update does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	current, err := client.GetPromptSettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	set.Visit(func(item *flag.Flag) { seen[item.Name] = true })
	if seen["template"] || seen["template-file"] {
		current.PromptTemplate, err = promptText(c, *template, *templateFile)
		if err != nil {
			return err
		}
	}
	if seen["board-skill"] || seen["board-skill-file"] {
		current.BoardSkillTemplate, err = promptText(c, *boardSkill, *boardSkillFile)
		if err != nil {
			return err
		}
	}
	if seen["chat-skill"] || seen["chat-skill-file"] {
		current.ChatSkillTemplate, err = promptText(c, *chatSkill, *chatSkillFile)
		if err != nil {
			return err
		}
	}
	value, err := client.UpdatePromptSettings(rpcCtx, &dieterv1.UpdatePromptSettingsRequest{PromptTemplate: current.GetPromptTemplate(), BoardSkillTemplate: current.GetBoardSkillTemplate(), ChatSkillTemplate: current.GetChatSkillTemplate()})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcPromptScope(scope string, args []string) error {
	usage := fmt.Sprintf("Usage: dieter prompt %s [--inherit|--template TEXT|--template-file FILE] %s\n", scope, strings.ToUpper(scope))
	set := flags("prompt " + scope)
	inherit := set.Bool("inherit", false, "inherit the parent template")
	template := set.String("template", "", "scoped prompt template")
	templateFile := set.String("template-file", "", "scoped prompt template file or -")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return fmt.Errorf("exactly one %s is required", strings.ToUpper(scope))
	}
	value, err := promptText(c, *template, *templateFile)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	state, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
	if err != nil {
		return err
	}
	if scope == "project" {
		project, err := resolveProtoProject(state, set.Arg(0))
		if err != nil {
			return err
		}
		updated, err := client.SetProjectPromptTemplate(rpcCtx, &dieterv1.SetScopedPromptTemplateRequest{ScopeId: project.GetId(), Inherit: *inherit, PromptTemplate: value})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, updated)
	}
	board, err := resolveProtoBoard(state, "", set.Arg(0))
	if err != nil {
		return err
	}
	updated, err := client.SetBoardPromptTemplate(rpcCtx, &dieterv1.SetScopedPromptTemplateRequest{ScopeId: board.GetId(), Inherit: *inherit, PromptTemplate: value})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

func (c *CLI) rpcPromptPreview(args []string) error {
	const usage = "Usage: dieter prompt preview [--project PROJECT] [--board BOARD] [--card CARD] [--labels ID,ID] [--scope board|chat]\n"
	set := flags("prompt preview")
	project := set.String("project", "", "project ID")
	board := set.String("board", "", "board ID")
	card := set.String("card", "", "card or chat ID")
	labels := set.String("labels", "", "comma-separated label IDs")
	scope := set.String("scope", "", "board or chat")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("prompt preview does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.PreviewPrompt(rpcCtx, &dieterv1.PreviewPromptRequest{ProjectId: *project, BoardId: *board, CardId: *card, LabelIds: splitCSV(*labels), Scope: *scope})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}
