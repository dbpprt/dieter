package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"strings"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

const projectHelp = `Usage: dieter project <action>

Actions:
  create PATH       Create and register a Git working tree on the target daemon
  open PATH         Register an existing Git working tree on the target daemon
  directories PATH  Browse daemon-host directories and Git repositories
  list              List active projects; use --removed for archived projects
  show PROJECT      Show project metadata
  update PROJECT    Update project path, name, summary, or prompt
  workspace PROJECT Update Git base and validation commands
  remove PROJECT    Archive a project
  restore PROJECT   Restore an archived project
`

func (c *CLI) rpcProject(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, projectHelp)
		return nil
	}
	switch args[0] {
	case "create":
		return c.rpcProjectCreate(args[1:], "create")
	case "open", "add":
		return c.rpcProjectCreate(args[1:], "open")
	case "directories", "dirs":
		return c.rpcProjectDirectories(args[1:])
	case "list", "ls":
		return c.rpcProjectList(args[1:])
	case "show":
		return c.rpcProjectShow(args[1:])
	case "update":
		return c.rpcProjectUpdate(args[1:])
	case "workspace":
		return c.rpcProjectWorkspace(args[1:])
	case "remove", "archive":
		return c.rpcProjectArchive(args[1:], true)
	case "restore", "unarchive":
		return c.rpcProjectArchive(args[1:], false)
	default:
		return fmt.Errorf("unknown project action %q; run `dieter project --help`", args[0])
	}
}

func readRPCValidationCommands(path string) ([]*dieterv1.ValidationCommand, error) {
	values, err := readValidationCommands(path)
	if err != nil {
		return nil, err
	}
	result := make([]*dieterv1.ValidationCommand, 0, len(values))
	for _, value := range values {
		result = append(result, &dieterv1.ValidationCommand{
			Name: value.Name, Executable: value.Executable, Arguments: append([]string(nil), value.Arguments...),
			WorkingDirectory: value.WorkingDirectory, Environment: cloneStringMap(value.Environment), TimeoutSeconds: int32(value.TimeoutSeconds),
		})
	}
	return result, nil
}

func (c *CLI) rpcProjectCreate(args []string, mode string) error {
	usage := fmt.Sprintf(`Usage: dieter project %s [options] PATH

Options:
  --name NAME                 Project display name
  --summary TEXT              Project summary
  --prompt TEXT               Project instructions
  --prompt-file FILE          Read project instructions from FILE or -
  --board-name NAME           Initial board name (default Main)
  --workflow direct|review    Initial board workflow
  --base-remote REMOTE        Git base remote
  --base-branch BRANCH        Git base branch
  --validation-file FILE      Validation command JSON
  --format json|id            Output format
`, mode)
	set := flags("project " + mode)
	name := set.String("name", "", "project name")
	summary := set.String("summary", "", "project summary")
	prompt := set.String("prompt", "", "project instructions")
	promptFile := set.String("prompt-file", "", "project instructions file")
	boardName := set.String("board-name", "Main", "initial board name")
	workflow := set.String("workflow", "review", "initial board workflow")
	baseRemote := set.String("base-remote", "", "Git base remote")
	baseBranch := set.String("base-branch", "", "Git base branch")
	validationFile := set.String("validation-file", "", "validation command JSON")
	format := set.String("format", "json", "json or id")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one daemon-host PATH is required")
	}
	promptValue, err := textValue(*prompt, *promptFile, c.In)
	if err != nil {
		return err
	}
	validation, err := readRPCValidationCommands(*validationFile)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	response, err := client.CreateProject(rpcCtx, &dieterv1.CreateProjectRequest{
		Mode: mode, Path: set.Arg(0), Name: *name, Summary: *summary, Prompt: promptValue,
		BoardName: *boardName, Workflow: *workflow, BaseRemote: *baseRemote, BaseBranch: *baseBranch,
		ValidationCommands: validation,
	})
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, response.GetProject().GetId())
		return nil
	}
	return protoJSONOut(c.Out, response)
}

func (c *CLI) rpcProjectDirectories(args []string) error {
	const usage = "Usage: dieter project directories [PATH]\n"
	set := flags("project directories")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() > 1 {
		return errors.New("at most one PATH is accepted")
	}
	path := ""
	if set.NArg() == 1 {
		path = set.Arg(0)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ListDirectories(rpcCtx, &dieterv1.ListDirectoriesRequest{Path: path})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func resolveProtoProject(state *dieterv1.State, reference string) (*dieterv1.Project, error) {
	var matches []*dieterv1.Project
	for _, item := range state.GetProjects() {
		if item.GetId() == reference || strings.EqualFold(item.GetName(), reference) {
			matches = append(matches, item)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("project %q was not found on the target daemon", reference)
	}
	if len(matches) > 1 {
		return nil, fmt.Errorf("project name %q is ambiguous; use its exact ID", reference)
	}
	return matches[0], nil
}

func (c *CLI) projectState(ctx context.Context, reference string) (*dieterv1.Project, *dieterv1.State, error) {
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, nil, err
	}
	state, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
	if err != nil {
		return nil, nil, err
	}
	project, err := resolveProtoProject(state, reference)
	return project, state, err
}

func (c *CLI) rpcProjectList(args []string) error {
	const usage = "Usage: dieter project list [--removed] [--format table|json|jsonl|ids]\n"
	set := flags("project list")
	removed := set.Bool("removed", false, "show archived projects")
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var items []*dieterv1.Project
	if *removed {
		value, err := client.ListArchivedProjects(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		items = value.GetProjects()
	} else {
		value, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
		if err != nil {
			return err
		}
		items = value.GetProjects()
	}
	if *format == "json" {
		return protoJSONOut(c.Out, &dieterv1.ProjectsResponse{Projects: items})
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	for _, item := range items {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		default:
			fmt.Fprintf(writer, "%s\t%s\t%d boards\t%s\n", item.GetId(), item.GetName(), item.GetBoardCount(), item.GetPath())
		}
	}
	return writer.Flush()
}

func (c *CLI) rpcProjectShow(args []string) error {
	const usage = "Usage: dieter project show PROJECT\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one PROJECT is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	project, _, err := c.projectState(ctx, args[0])
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, project)
}

func (c *CLI) rpcProjectUpdate(args []string) error {
	const usage = "Usage: dieter project update [--path PATH] [--name NAME] [--summary TEXT] [--prompt TEXT|--prompt-file FILE] PROJECT\n"
	set := flags("project update")
	path, name, summary, prompt := &optional{}, &optional{}, &optional{}, &optional{}
	set.Var(path, "path", "new canonical Git working-tree path on the daemon host")
	set.Var(name, "name", "project name")
	set.Var(summary, "summary", "project summary")
	set.Var(prompt, "prompt", "project instructions")
	promptFile := set.String("prompt-file", "", "project instructions file")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PROJECT is required")
	}
	var promptValue *string
	if *promptFile != "" {
		value, err := textValue("", *promptFile, c.In)
		if err != nil {
			return err
		}
		promptValue = &value
	} else {
		promptValue = prompt.ptr()
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	project, _, err := c.projectState(ctx, set.Arg(0))
	if err != nil {
		return err
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.UpdateProject(rpcCtx, &dieterv1.UpdateProjectRequest{
		ProjectId: project.GetId(), Name: name.ptr(), Summary: summary.ptr(), Prompt: promptValue, Path: path.ptr(),
	})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcProjectWorkspace(args []string) error {
	const usage = "Usage: dieter project workspace [--base-remote REMOTE] [--base-branch BRANCH] [--validation-file FILE] PROJECT\n"
	set := flags("project workspace")
	remote := set.String("base-remote", "", "Git base remote")
	branch := set.String("base-branch", "", "Git base branch")
	validationFile := set.String("validation-file", "", "validation command JSON")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PROJECT is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	project, _, err := c.projectState(ctx, set.Arg(0))
	if err != nil {
		return err
	}
	if *remote == "" {
		*remote = project.GetBaseRemote()
	}
	if *branch == "" {
		*branch = project.GetBaseBranch()
	}
	validation := project.GetValidationCommands()
	if *validationFile != "" {
		validation, err = readRPCValidationCommands(*validationFile)
		if err != nil {
			return err
		}
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.UpdateProjectWorkspaceSettings(rpcCtx, &dieterv1.UpdateProjectWorkspaceSettingsRequest{
		ProjectId: project.GetId(), BaseRemote: *remote, BaseBranch: *branch, ValidationCommands: validation,
	})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcProjectArchive(args []string, archived bool) error {
	action := "remove"
	if !archived {
		action = "restore"
	}
	usage := fmt.Sprintf("Usage: dieter project %s PROJECT\n", action)
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one PROJECT is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID := args[0]
	if archived {
		project, _, err := c.projectState(ctx, args[0])
		if err != nil {
			return err
		}
		projectID = project.GetId()
	} else {
		archivedProjects, err := client.ListArchivedProjects(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		project, err := resolveProtoProject(&dieterv1.State{Projects: archivedProjects.GetProjects()}, args[0])
		if err != nil {
			return err
		}
		projectID = project.GetId()
	}
	value, err := client.ArchiveProject(rpcCtx, &dieterv1.ArchiveProjectRequest{ProjectId: projectID, Archived: archived})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

const boardHelp = `Usage: dieter board <action>

Actions:
  create              Create a fixed direct or review workflow board
  list                List boards
  show BOARD           Show one board
  rename BOARD         Rename a board
  retention BOARD      Configure automatic Done-card archiving
  label add            Create a board label
  label list           List board labels
  label update LABEL   Update label name, color, or instructions
  label remove LABEL   Delete a board label
`

func (c *CLI) rpcBoard(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, boardHelp)
		return nil
	}
	switch args[0] {
	case "create":
		return c.rpcBoardCreate(args[1:])
	case "list", "ls":
		return c.rpcBoardList(args[1:])
	case "show":
		return c.rpcBoardShow(args[1:])
	case "rename":
		return c.rpcBoardRename(args[1:])
	case "retention":
		return c.rpcBoardRetention(args[1:])
	case "label", "labels":
		return c.rpcBoardLabel(args[1:])
	default:
		return fmt.Errorf("unknown board action %q; run `dieter board --help`", args[0])
	}
}

func resolveProtoBoard(state *dieterv1.State, projectID, reference string) (*dieterv1.Board, error) {
	var matches []*dieterv1.Board
	for _, item := range state.GetBoards() {
		if projectID != "" && item.GetProjectId() != projectID {
			continue
		}
		if item.GetId() == reference || strings.EqualFold(item.GetName(), reference) {
			matches = append(matches, item)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("board %q was not found on the target daemon", reference)
	}
	if len(matches) > 1 {
		return nil, fmt.Errorf("board name %q is ambiguous; use its exact ID", reference)
	}
	return matches[0], nil
}

func (c *CLI) boardState(ctx context.Context, reference string) (*dieterv1.Board, *dieterv1.State, error) {
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, nil, err
	}
	state, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
	if err != nil {
		return nil, nil, err
	}
	board, err := resolveProtoBoard(state, "", reference)
	return board, state, err
}

func (c *CLI) rpcBoardCreate(args []string) error {
	const usage = "Usage: dieter board create --project PROJECT --name NAME [--workflow direct|review] [--description TEXT] [--archive-done POLICY]\n"
	set := flags("board create")
	project := set.String("project", "", "project ID or name")
	name := set.String("name", "", "board name")
	workflow := set.String("workflow", "review", "direct or review")
	description := set.String("description", "", "board description")
	archiveDone := set.String("archive-done", "never", "Done-card archive policy")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if strings.TrimSpace(*project) == "" || strings.TrimSpace(*name) == "" {
		return errors.New("--project and --name are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	projectValue, _, err := c.projectState(ctx, *project)
	if err != nil {
		return err
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.CreateBoard(rpcCtx, &dieterv1.CreateBoardRequest{
		ProjectId: projectValue.GetId(), Name: *name, Workflow: *workflow,
		Description: *description, DoneArchivePolicy: *archiveDone,
	})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcBoardList(args []string) error {
	const usage = "Usage: dieter board list [--project PROJECT] [--format table|json|jsonl|ids]\n"
	set := flags("board list")
	project := set.String("project", "", "project ID or name")
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
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
	projectID := ""
	if strings.TrimSpace(*project) != "" {
		value, err := resolveProtoProject(state, *project)
		if err != nil {
			return err
		}
		projectID = value.GetId()
	}
	var items []*dieterv1.Board
	for _, item := range state.GetBoards() {
		if projectID == "" || item.GetProjectId() == projectID {
			items = append(items, item)
		}
	}
	if *format == "json" {
		return jsonOut(c.Out, items)
	}
	for _, item := range items {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		default:
			fmt.Fprintf(c.Out, "%s\t%s\t%s\n", item.GetId(), item.GetName(), item.GetWorkflow())
		}
	}
	return nil
}

func (c *CLI) rpcBoardShow(args []string) error {
	const usage = "Usage: dieter board show BOARD\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one BOARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	board, _, err := c.boardState(ctx, args[0])
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, board)
}

func (c *CLI) rpcBoardRename(args []string) error {
	const usage = "Usage: dieter board rename --name NAME BOARD\n"
	set := flags("board rename")
	name := set.String("name", "", "new board name")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*name) == "" {
		return errors.New("BOARD and --name are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	board, _, err := c.boardState(ctx, set.Arg(0))
	if err != nil {
		return err
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.RenameBoard(rpcCtx, &dieterv1.RenameBoardRequest{BoardId: board.GetId(), Name: *name})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcBoardRetention(args []string) error {
	const usage = "Usage: dieter board retention --archive-done POLICY BOARD\n\nPOLICY: never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days.\n"
	set := flags("board retention")
	policy := set.String("archive-done", "", "Done-card archive policy")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*policy) == "" {
		return errors.New("BOARD and --archive-done are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	board, _, err := c.boardState(ctx, set.Arg(0))
	if err != nil {
		return err
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SetBoardArchivePolicy(rpcCtx, &dieterv1.SetBoardArchivePolicyRequest{BoardId: board.GetId(), DoneArchivePolicy: *policy})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcBoardLabel(args []string) error {
	const usage = `Usage: dieter board label <action> [options]

Actions:
  add --board BOARD --name NAME [--color COLOR] [--instructions TEXT]
  list --board BOARD
  update --board BOARD [--name NAME] [--color COLOR] [--instructions TEXT] LABEL
  remove --board BOARD LABEL
`
	if groupHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	action := args[0]
	set := flags("board label " + action)
	boardRef := set.String("board", "", "board ID or name")
	name := set.String("name", "", "label name")
	color := set.String("color", "#6558df", "label color")
	instructions := set.String("instructions", "", "label instructions")
	help, err := parse(set, args[1:], usage, c.Out)
	if help || err != nil {
		return err
	}
	if strings.TrimSpace(*boardRef) == "" {
		return errors.New("--board is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	board, _, err := c.boardState(ctx, *boardRef)
	if err != nil {
		return err
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	switch action {
	case "list", "ls":
		if set.NArg() != 0 {
			return errors.New("label list does not accept a LABEL")
		}
		return jsonOut(c.Out, board.GetLabels())
	case "add", "create":
		if set.NArg() != 0 || strings.TrimSpace(*name) == "" {
			return errors.New("--name is required")
		}
		value, err := client.CreateBoardLabel(rpcCtx, &dieterv1.CreateBoardLabelRequest{BoardId: board.GetId(), Name: *name, Color: *color, Instructions: *instructions})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "update", "edit":
		if set.NArg() != 1 {
			return errors.New("exactly one LABEL is required")
		}
		var label *dieterv1.Label
		for _, item := range board.GetLabels() {
			if item.GetId() == set.Arg(0) || strings.EqualFold(item.GetName(), set.Arg(0)) {
				label = item
				break
			}
		}
		if label == nil {
			return fmt.Errorf("label %q was not found", set.Arg(0))
		}
		visited := map[string]bool{}
		set.Visit(func(flagValue *flag.Flag) { visited[flagValue.Name] = true })
		if !visited["name"] {
			*name = label.GetName()
		}
		if !visited["color"] {
			*color = label.GetColor()
		}
		if !visited["instructions"] {
			*instructions = label.GetInstructions()
		}
		value, err := client.UpdateBoardLabel(rpcCtx, &dieterv1.UpdateBoardLabelRequest{BoardId: board.GetId(), LabelId: label.GetId(), Name: *name, Color: *color, Instructions: *instructions})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "remove", "delete", "rm":
		if set.NArg() != 1 {
			return errors.New("exactly one LABEL is required")
		}
		labelID := ""
		for _, item := range board.GetLabels() {
			if item.GetId() == set.Arg(0) || strings.EqualFold(item.GetName(), set.Arg(0)) {
				if labelID != "" {
					return fmt.Errorf("label name %q is ambiguous; use its exact ID", set.Arg(0))
				}
				labelID = item.GetId()
			}
		}
		if labelID == "" {
			return fmt.Errorf("label %q was not found", set.Arg(0))
		}
		value, err := client.DeleteBoardLabel(rpcCtx, &dieterv1.DeleteBoardLabelRequest{BoardId: board.GetId(), LabelId: labelID})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	default:
		return fmt.Errorf("unknown board label action %q", action)
	}
}
