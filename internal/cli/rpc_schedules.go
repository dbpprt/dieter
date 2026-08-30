package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"strings"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const scheduleHelp = `Usage: dieter schedule <action>

Actions:
  create                 Create a recurring project schedule
  list                   List schedules
  show SCHEDULE          Show a schedule and recent occurrences
  preview                Preview cron occurrence times
  update SCHEDULE        Replace a schedule definition
  run SCHEDULE           Dispatch one manual occurrence
  pause SCHEDULE         Disable automatic occurrences
  resume SCHEDULE        Enable automatic occurrences
  runs SCHEDULE          List authoritative occurrence history
  delete SCHEDULE        Delete the definition; cards and history remain
`

func (c *CLI) rpcSchedule(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, scheduleHelp)
		return nil
	}
	switch args[0] {
	case "create", "add":
		return c.rpcScheduleEdit(args[1:], nil)
	case "list", "ls":
		return c.rpcScheduleList(args[1:])
	case "show":
		return c.rpcScheduleShow(args[1:])
	case "preview":
		return c.rpcSchedulePreview(args[1:])
	case "update", "edit":
		return c.rpcScheduleUpdate(args[1:])
	case "run":
		return c.rpcScheduleRefAction("run", args[1:])
	case "pause", "resume":
		return c.rpcScheduleRefAction(args[0], args[1:])
	case "runs":
		return c.rpcScheduleRuns(args[1:])
	case "delete", "remove", "rm":
		return c.rpcScheduleRefAction("delete", args[1:])
	default:
		return fmt.Errorf("unknown schedule action %q; run `dieter schedule --help`", args[0])
	}
}

func resolveProtoSchedule(items []*dieterv1.Schedule, reference string) (*dieterv1.Schedule, error) {
	var matches []*dieterv1.Schedule
	for _, item := range items {
		if item.GetId() == reference || strings.EqualFold(item.GetName(), reference) {
			matches = append(matches, item)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("schedule %q was not found on the target daemon", reference)
	}
	if len(matches) > 1 {
		return nil, fmt.Errorf("schedule name %q is ambiguous; use its exact ID", reference)
	}
	return matches[0], nil
}

func (c *CLI) resolveSchedule(rpcCtx context.Context, client dieterv1.DieterServiceClient, reference string) (*dieterv1.Schedule, error) {
	value, err := client.ListSchedules(rpcCtx, &dieterv1.ListSchedulesRequest{})
	if err != nil {
		return nil, err
	}
	return resolveProtoSchedule(value.GetSchedules(), reference)
}

func (c *CLI) rpcScheduleList(args []string) error {
	const usage = "Usage: dieter schedule list [--project PROJECT] [--format table|json|jsonl|ids]\n"
	set := flags("schedule list")
	projectRef := set.String("project", "", "project ID or unique name")
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("schedule list does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID := ""
	if strings.TrimSpace(*projectRef) != "" {
		state, readErr := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
		if readErr != nil {
			return readErr
		}
		project, resolveErr := resolveProtoProject(state, *projectRef)
		if resolveErr != nil {
			return resolveErr
		}
		projectID = project.GetId()
	}
	value, err := client.ListSchedules(rpcCtx, &dieterv1.ListSchedulesRequest{ProjectId: projectID})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	if *format == "table" {
		fmt.Fprintln(writer, "ID\tSTATE\tNEXT RUN\tNAME")
	}
	for _, item := range value.GetSchedules() {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		default:
			state := "paused"
			if item.GetEnabled() {
				state = "enabled"
			}
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", item.GetId(), state, item.GetNextRunAt(), item.GetName())
		}
	}
	return writer.Flush()
}

func (c *CLI) rpcScheduleShow(args []string) error {
	const usage = "Usage: dieter schedule show [--runs N] SCHEDULE\n"
	set := flags("schedule show")
	runLimit := set.Int("runs", 10, "recent occurrence count")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one SCHEDULE is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	item, err := c.resolveSchedule(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	runs, err := client.ListScheduleRuns(rpcCtx, &dieterv1.ListScheduleRunsRequest{ScheduleId: item.GetId(), Limit: int32(*runLimit)})
	if err != nil {
		return err
	}
	return jsonOut(c.Out, map[string]any{"schedule": item, "runs": runs.GetRuns()})
}

func (c *CLI) rpcSchedulePreview(args []string) error {
	const usage = "Usage: dieter schedule preview --cron EXPRESSION [--timezone AREA/LOCATION] [--count N]\n"
	set := flags("schedule preview")
	expression := set.String("cron", "", "five-field cron expression")
	timezone := set.String("timezone", "UTC", "IANA timezone")
	count := set.Int("count", 5, "number of future times")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*expression) == "" {
		return errors.New("--cron is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.PreviewSchedule(rpcCtx, &dieterv1.PreviewScheduleRequest{Cron: *expression, Timezone: *timezone, Count: int32(*count)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScheduleUpdate(args []string) error {
	if wantsHelp(args) {
		return c.rpcScheduleEdit(args, &dieterv1.Schedule{})
	}
	if len(args) == 0 {
		return errors.New("SCHEDULE is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	current, err := c.resolveSchedule(rpcCtx, client, args[len(args)-1])
	if err != nil {
		return err
	}
	return c.rpcScheduleEdit(args, current)
}

func (c *CLI) rpcScheduleEdit(args []string, current *dieterv1.Schedule) error {
	updating := current != nil
	actionName := "create"
	if updating {
		actionName = "update"
	}
	usage := fmt.Sprintf(`Usage: dieter schedule %s --project PROJECT --board BOARD --name NAME --cron EXPRESSION --title TITLE --prompt TEXT [options]%s

Options:
  --timezone AREA/LOCATION           IANA timezone (default UTC)
  --action draft|run                 Create a draft or immediately run it
  --workspace project|worktree       Conversation workspace selection
  --labels ID,ID                     Board-label IDs
  --provider HARNESS --model MODEL --effort EFFORT
  --provider-option KEY=VALUE        Repeatable harness option
  --enabled=true|false
  --open-card skip_if_open|always
  --busy queue|skip
`, actionName, map[bool]string{true: " SCHEDULE"}[updating])
	defaults := &dieterv1.Schedule{Enabled: true, Cron: "0 9 * * 1-5", Timezone: "UTC", Action: "draft", OpenCardPolicy: "skip_if_open", MisfirePolicy: "latest", BusyPolicy: "queue", WorkspaceMode: "worktree"}
	if current != nil && current.GetId() != "" {
		defaults = current
	}
	set := flags("schedule " + actionName)
	project := set.String("project", defaults.GetProjectId(), "project ID or unique name")
	board := set.String("board", defaults.GetBoardId(), "board ID or unique name")
	name := set.String("name", defaults.GetName(), "schedule name")
	description := set.String("description", defaults.GetDescription(), "schedule description")
	expression := set.String("cron", defaults.GetCron(), "five-field cron")
	timezone := set.String("timezone", defaults.GetTimezone(), "IANA timezone")
	action := set.String("action", defaults.GetAction(), "draft or run")
	workspaceMode := set.String("workspace", defaults.GetWorkspaceMode(), "project or worktree")
	title := set.String("title", defaults.GetTitleTemplate(), "card title template")
	prompt := set.String("prompt", defaults.GetPromptTemplate(), "card prompt template")
	promptFile := set.String("prompt-file", "", "prompt template file or -")
	provider := set.String("provider", defaults.GetProvider(), "harness provider")
	modelName := set.String("model", defaults.GetModel(), "model")
	effort := set.String("effort", defaults.GetEffort(), "reasoning effort")
	labels := set.String("labels", strings.Join(defaults.GetLabelIds(), ","), "label IDs")
	enabled := set.Bool("enabled", defaults.GetEnabled(), "enabled")
	openCard := set.String("open-card", defaults.GetOpenCardPolicy(), "open-card policy")
	busy := set.String("busy", defaults.GetBusyPolicy(), "busy policy")
	providerOptions := parameterFlags{}
	for key, value := range defaults.GetProviderOptions() {
		providerOptions[key] = value
	}
	set.Var(&providerOptions, "provider-option", "provider option KEY=VALUE; repeatable")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if updating && defaults.GetId() == "" {
		return nil
	}
	if (!updating && set.NArg() != 0) || (updating && (set.NArg() != 1 || set.Arg(0) != defaults.GetId())) {
		return errors.New("unexpected positional arguments")
	}
	promptInline := *prompt
	if *promptFile != "" {
		explicit := false
		set.Visit(func(item *flag.Flag) { explicit = explicit || item.Name == "prompt" })
		if !explicit {
			promptInline = ""
		}
	}
	promptValue, err := textValue(promptInline, *promptFile, c.In)
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
	projectValue, err := resolveProtoProject(state, *project)
	if err != nil {
		return err
	}
	boardValue, err := resolveProtoBoard(state, projectValue.GetId(), *board)
	if err != nil {
		return err
	}
	draft := &dieterv1.ScheduleDraft{ProjectId: projectValue.GetId(), BoardId: boardValue.GetId(), Name: *name, Description: *description, Cron: *expression, Timezone: *timezone, Enabled: *enabled, Action: *action, TitleTemplate: *title, PromptTemplate: promptValue, Provider: *provider, Model: *modelName, Effort: *effort, LabelIds: splitCSV(*labels), OpenCardPolicy: *openCard, MisfirePolicy: "latest", BusyPolicy: *busy, ProviderOptions: map[string]string(providerOptions), WorkspaceMode: *workspaceMode}
	request := &dieterv1.SaveScheduleRequest{Schedule: draft}
	var value *dieterv1.Schedule
	if updating {
		request.ScheduleId = defaults.GetId()
		value, err = client.UpdateSchedule(rpcCtx, request)
	} else {
		value, err = client.CreateSchedule(rpcCtx, request)
	}
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScheduleRefAction(action string, args []string) error {
	usage := fmt.Sprintf("Usage: dieter schedule %s SCHEDULE\n", action)
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one SCHEDULE is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	item, err := c.resolveSchedule(rpcCtx, client, args[0])
	if err != nil {
		return err
	}
	switch action {
	case "run":
		value, err := client.RunSchedule(rpcCtx, &dieterv1.ScheduleRef{ScheduleId: item.GetId()})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "pause", "resume":
		value, err := client.SetScheduleEnabled(rpcCtx, &dieterv1.SetScheduleEnabledRequest{ScheduleId: item.GetId(), Enabled: action == "resume"})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "delete":
		_, err := client.DeleteSchedule(rpcCtx, &dieterv1.ScheduleRef{ScheduleId: item.GetId()})
		return err
	default:
		return fmt.Errorf("unsupported schedule action %q", action)
	}
}

func (c *CLI) rpcScheduleRuns(args []string) error {
	const usage = "Usage: dieter schedule runs [--limit N] SCHEDULE\n"
	set := flags("schedule runs")
	limit := set.Int("limit", 0, "maximum occurrences; zero means daemon default/all")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one SCHEDULE is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	item, err := c.resolveSchedule(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	value, err := client.ListScheduleRuns(rpcCtx, &dieterv1.ListScheduleRunsRequest{ScheduleId: item.GetId(), Limit: int32(*limit)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}
