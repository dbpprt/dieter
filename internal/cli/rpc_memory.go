package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"

	"google.golang.org/protobuf/types/known/emptypb"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const memoryHelp = `Usage: dieter memory <action>

Actions:
  status     Show this machine's memory index and each project's memory state
  search     Recall a project's saved memories and earlier conversations
  save       Save a curated memory (lesson, decision, fact or pattern)
  forget     Delete a saved memory, or a conversation's or project's index rows
  reindex    Rebuild this machine's index of a project
  settings   Show or change the account's memory and dreaming setting
  dream      Start, list, apply, discard or undo memory dreams

Agent memory is per project: turn it on with dieter project update
--memory=true PROJECT. Each memory-enabled conversation's finished turns are
indexed on the machine that owns it; recall searches every machine of the
account that owns conversations of the project. Saved memories replicate to
every machine. A conversation's own switch is dieter card memory CARD on|off.

Dreaming reconciles a project's saved memories with an agent session
configured in dieter memory settings: a conversation labelled Memory on the
project's first board, whose agent merges, supersedes, retires and adds
memories. Inside an agent turn, search and save use the turn's own project;
forget, reindex, settings, dreams and switches are refused.
`

func (c *CLI) rpcMemory(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, memoryHelp)
		return nil
	}
	switch args[0] {
	case "status":
		return c.rpcMemoryStatus(args[1:])
	case "search", "recall":
		return c.rpcMemorySearch(args[1:])
	case "save":
		return c.rpcMemorySave(args[1:])
	case "forget":
		return c.rpcMemoryForget(args[1:])
	case "reindex":
		return c.rpcMemoryReindex(args[1:])
	case "settings":
		return c.rpcMemorySettings(args[1:])
	case "dream", "dreams":
		return c.rpcMemoryDream(args[1:])
	default:
		return fmt.Errorf("unknown memory action %q; run `dieter memory --help`", args[0])
	}
}

// memoryMutation refuses a person's memory change inside an agent turn
// before any daemon is contacted (the turn token reaches only the local
// daemon, so --machine would otherwise bypass the daemon's refusal).
func (c *CLI) memoryMutation(what string) error {
	if c.env.TurnToken != "" {
		return fmt.Errorf("agent turns cannot %s; ask the user", what)
	}
	return nil
}

func (c *CLI) rpcMemoryStatus(args []string) error {
	const usage = `Usage: dieter memory status [--project PROJECT] [--format text|json]

Show this machine's memory index (size, conversations and observations
indexed, backlog) and, per project with memory on, its saved memories and
dreaming state: the last dream and when the next one may start.
Global --machine asks another machine.
`
	set := flags("memory status")
	project := set.String("project", "", "project ID or name (default: every project with memory on)")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("memory status takes options only")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetMemoryStatus(rpcCtx, &dieterv1.GetMemoryStatusRequest{ProjectId: *project})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	fmt.Fprintf(c.Out, "Machine:\t%s (%s)\nIndex:\t%s\n", value.GetMachine(), value.GetMachineId(), byteSize(value.GetIndexBytes()))
	if value.GetLastError() != "" {
		fmt.Fprintf(c.Out, "Last error:\t%s\n", value.GetLastError())
	}
	if len(value.GetProjects()) == 0 {
		fmt.Fprintln(c.Out, "No project has memory on. Turn it on with: dieter project update --memory=true PROJECT")
		return nil
	}
	for _, project := range value.GetProjects() {
		state := "on"
		if !project.GetEnabled() {
			state = "off"
		}
		fmt.Fprintf(c.Out, "\n%s (%s): memory %s\n", project.GetName(), project.GetProjectId(), state)
		fmt.Fprintf(c.Out, "  Indexed here:\t%d conversations, %d observations (last %s, backlog %d)\n", project.GetCards(), project.GetObservations(), orDash(project.GetLastIndexedAt()), project.GetBacklog())
		fmt.Fprintf(c.Out, "  Saved memories:\t%d active\n", project.GetSaved())
		last := "never"
		if project.GetLastDreamAt() != "" {
			last = project.GetLastDreamAt() + " (" + project.GetLastDreamCardId() + ")"
		}
		fmt.Fprintf(c.Out, "  Last dream:\t%s; %d conversations since\n  Next dream:\t%s\n", last, project.GetFinishedSinceDream(), project.GetNextDream())
	}
	return nil
}

func (c *CLI) rpcMemorySearch(args []string) error {
	const usage = `Usage: dieter memory search [--project PROJECT] [--limit N] [--file PATH ...] [--kind KIND ...] [--local] [--format text|json] QUERY...

Recall a project's saved memories and the earlier conversations that best
match QUERY: their card, machine, title, matching passages and final answer.
Conversations on other machines of the account are searched too, unless
--local; machines that do not answer are listed. Results are earlier work that
may be out of date; read a conversation with dieter --machine MACHINE card
transcript CARD.

Options:
  --project PROJECT   Project ID or name (inside an agent turn: the turn's own)
  --limit N           Conversations to return (1-10, default 6)
  --file PATH         Only conversations that touched PATH; repeat
  --kind KIND         Only saved memories of this kind (lesson, decision, fact,
                      pattern); repeat
  --local             Search only this machine's index
  --format text|json  Output format
`
	set := flags("memory search")
	project := set.String("project", "", "project ID or name")
	limit := set.Int("limit", 0, "conversations to return")
	var files, kinds repeatedStrings
	set.Var(&files, "file", "only conversations that touched this file")
	set.Var(&kinds, "kind", "only saved memories of this kind")
	local := set.Bool("local", false, "search only this machine")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	query := strings.TrimSpace(strings.Join(set.Args(), " "))
	if query == "" {
		return errors.New("a QUERY is required")
	}
	if *project == "" && c.env.TurnToken == "" {
		return errors.New("--project is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SearchMemory(rpcCtx, &dieterv1.SearchMemoryRequest{
		ProjectId: *project, Query: query, Limit: int32(*limit), Files: files, Kinds: kinds, LocalOnly: *local,
	})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writeMemorySearch(c.Out, value)
	return nil
}

func writeMemorySearch(out io.Writer, value *dieterv1.MemorySearchResult) {
	if len(value.GetMemories()) == 0 && len(value.GetHits()) == 0 {
		fmt.Fprintln(out, "Nothing in memory matches.")
	}
	if len(value.GetMemories()) > 0 {
		fmt.Fprintln(out, "Saved memories:")
		for _, memory := range value.GetMemories() {
			flags := memory.GetKind()
			if memory.GetVerified() {
				flags += ", verified"
			}
			fmt.Fprintf(out, "  %s [%s, confidence %.2f] %s\n", memory.GetId(), flags, memory.GetConfidence(), oneLine(memory.GetContent()))
			if len(memory.GetSources()) > 0 {
				fmt.Fprintf(out, "    sources: %s\n", strings.Join(memory.GetSources(), ", "))
			}
		}
	}
	if len(value.GetHits()) > 0 {
		if len(value.GetMemories()) > 0 {
			fmt.Fprintln(out)
		}
		fmt.Fprintln(out, "Conversations:")
		for index, hit := range value.GetHits() {
			machine := hit.GetMachine()
			if machine == "" {
				machine = hit.GetMachineId()
			}
			fmt.Fprintf(out, "%d. %s on %s: %s (%s, %s, last active %s)\n", index+1, hit.GetCardId(), machine, hit.GetTitle(), orDash(hit.GetLane()), orDash(hit.GetHarness()), orDash(hit.GetLastActivityAt()))
			for _, snippet := range hit.GetSnippets() {
				fmt.Fprintf(out, "   > %s\n", oneLine(snippet))
			}
			if answer := hit.GetFinalAnswer(); answer != "" {
				fmt.Fprintf(out, "   Answer: %s\n", oneLine(answer))
			}
		}
	}
	if len(value.GetUnreachable()) > 0 {
		fmt.Fprintf(out, "\nNot reachable: %s (their conversations are missing from this answer)\n", strings.Join(value.GetUnreachable(), ", "))
	}
	if value.GetTruncated() {
		fmt.Fprintf(out, "(%d results left out to stay within the response budget)\n", value.GetExcluded())
	}
}

func (c *CLI) rpcMemorySave(args []string) error {
	const usage = `Usage: dieter memory save [--project PROJECT] [--kind KIND] [--file PATH ...] [--source CARD ...] [--ttl DAYS] [--replaces ID] [--format text|json] TEXT...

Save one curated memory of a project, shared with future conversations on
every machine. Kinds: lesson (a rule learned the hard way), decision (what
was decided and why), fact, pattern. Saving an identical lesson again
reinforces it; a near-identical memory, or the one named by --replaces, is
superseded. Inside an agent turn the memory belongs to the turn's project and
names its conversation as the source.

Options:
  --project PROJECT   Project ID or name (inside an agent turn: the turn's own)
  --kind KIND         lesson, decision, fact (default) or pattern
  --file PATH         A file the memory is about; repeat (at most 20)
  --source CARD       A conversation the memory comes from; repeat (at most 8)
  --ttl DAYS          Forget it after DAYS days (default: keep)
  --replaces ID       Supersede this saved memory
  --format text|json  Output format
`
	set := flags("memory save")
	project := set.String("project", "", "project ID or name")
	kind := set.String("kind", "", "lesson, decision, fact or pattern")
	var files, sources repeatedStrings
	set.Var(&files, "file", "a file the memory is about")
	set.Var(&sources, "source", "a conversation the memory comes from")
	ttl := set.Int("ttl", 0, "days to keep it")
	replaces := set.String("replaces", "", "saved memory ID to supersede")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	content := strings.TrimSpace(strings.Join(set.Args(), " "))
	if content == "" {
		return errors.New("the memory TEXT is required")
	}
	if *project == "" && c.env.TurnToken == "" {
		return errors.New("--project is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SaveMemory(rpcCtx, &dieterv1.SaveMemoryRequest{
		ProjectId: *project, Content: content, Kind: *kind, Files: files, Sources: sources, TtlDays: int32(*ttl), ReplacesId: *replaces,
	})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	switch {
	case value.GetReinforced():
		fmt.Fprintf(c.Out, "Reinforced lesson %s (confidence %.2f)\n", value.GetMemory().GetId(), value.GetMemory().GetConfidence())
	case value.GetSupersededId() != "":
		fmt.Fprintf(c.Out, "Saved %s; it supersedes %s\n", value.GetMemory().GetId(), value.GetSupersededId())
	default:
		fmt.Fprintf(c.Out, "Saved %s\n", value.GetMemory().GetId())
	}
	if similar := value.GetSimilarTo(); similar != nil {
		fmt.Fprintf(c.Out, "A close memory exists: %s %s\nIf yours replaces it, save again with --replaces %s.\n", similar.GetId(), oneLine(similar.GetContent()), similar.GetId())
	}
	return nil
}

func (c *CLI) rpcMemoryForget(args []string) error {
	const usage = `Usage: dieter memory forget --project PROJECT (--memory ID | --card CARD | --all)

Delete a saved memory on every machine (--memory), or this machine's index
rows of a conversation (--card) or of the whole project (--all). Index rows
come back when the conversation is indexed again (dieter memory reindex);
turn a conversation's memory off with dieter card memory CARD off.
Agent turns cannot forget.
`
	set := flags("memory forget")
	project := set.String("project", "", "project ID or name")
	memoryID := set.String("memory", "", "saved memory ID")
	cardID := set.String("card", "", "conversation ID")
	all := set.Bool("all", false, "all of the project's index rows on this machine")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if err = c.memoryMutation("forget memory"); err != nil {
		return err
	}
	if set.NArg() != 0 || (*memoryID == "" && *cardID == "" && !*all) {
		return errors.New("--memory, --card or --all is required")
	}
	if *project == "" && *cardID == "" {
		return errors.New("--project is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	if _, err = client.ForgetMemory(rpcCtx, &dieterv1.ForgetMemoryRequest{ProjectId: *project, MemoryId: *memoryID, CardId: *cardID, All: *all}); err != nil {
		return err
	}
	fmt.Fprintln(c.Out, "Forgotten.")
	return nil
}

func (c *CLI) rpcMemoryReindex(args []string) error {
	const usage = `Usage: dieter memory reindex --project PROJECT

Rebuild this machine's index of a project from its conversations' stored
transcripts. Saved memories are not affected. Agent turns cannot reindex.
Global --machine reindexes another machine.
`
	set := flags("memory reindex")
	project := set.String("project", "", "project ID or name")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if err = c.memoryMutation("reindex memory"); err != nil {
		return err
	}
	if set.NArg() != 0 || *project == "" {
		return errors.New("--project is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ReindexMemory(rpcCtx, &dieterv1.ReindexMemoryRequest{ProjectId: *project})
	if err != nil {
		return err
	}
	for _, status := range value.GetProjects() {
		fmt.Fprintf(c.Out, "Reindexed %s: %d conversations, %d observations\n", status.GetName(), status.GetCards(), status.GetObservations())
	}
	return nil
}

func (c *CLI) rpcMemorySettings(args []string) error {
	if len(args) > 0 && args[0] == "show" {
		return c.rpcMemorySettingsShow(args[1:])
	}
	// Options without an action (--format, --help) belong to show.
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		return c.rpcMemorySettingsShow(args)
	}
	if args[0] == "update" {
		return c.rpcMemorySettingsUpdate(args[1:])
	}
	return fmt.Errorf("unknown memory settings action %q; use show or update", args[0])
}

func (c *CLI) rpcMemorySettingsShow(args []string) error {
	const usage = `Usage: dieter memory settings [show] [--format text|json]

Print the account's memory and dreaming setting (dieter memory settings
update changes it). Until someone saves one, the defaults are shown and
"configured" is false.
`
	set := flags("memory settings show")
	format := set.String("format", "text", "text or json")
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
	value, err := client.GetMemorySettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writeMemorySettings(c.Out, value)
	return nil
}

func (c *CLI) rpcMemorySettingsUpdate(args []string) error {
	const usage = `Usage: dieter memory settings update [options]

Change the account's memory and dreaming setting. Options you leave out keep
their current value.

Options:
  --dreaming on|off          Reconcile memory-enabled projects' saved memories
                             with dreams (default off)
  --harness HARNESS          Catalog harness the dreams run on; Strix is refused
  --model MODEL              Model of that harness
  --effort EFFORT            Reasoning effort (empty: the model's default)
  --account ID|LABEL         Provider account for Claude Code and Codex dreams;
                             "" uses the provider's default
  --run-on MACHINE           Machine (daemon ID) that runs dreams; "" picks, per
                             project, the machine with most of its conversations
  --min-hours N              Hours between a project's dreams (1-168, default 24)
  --min-tasks N              Conversations that must finish first (1-100,
                             default 5)
  --window HH:MM-HH:MM       Local time window for dreams ("" any time;
                             default 02:00-06:00)
  --apply auto|review        auto applies a validated dream at once (undo
                             restores); review stages it until applied
  --max-changes N            Changes per dream (1-100, default 40)
  --max-retire-percent N     Share of active memories a dream may retire or
                             supersede (1-100, default 25)
  --instructions TEXT        Extra instructions for every dream (4 KiB)
  --instructions-file FILE   Read them from FILE or -
  --format text|json         Output format

Agent turns cannot change the setting.
`
	set := flags("memory settings update")
	dreaming := set.String("dreaming", "", "on or off")
	harnessName := set.String("harness", "", "catalog harness")
	modelName := set.String("model", "", "model")
	effort := set.String("effort", "", "reasoning effort")
	account := set.String("account", "", "provider account ID or label")
	runOn := set.String("run-on", "", "machine that runs dreams")
	minHours := set.Int("min-hours", 0, "hours between dreams")
	minTasks := set.Int("min-tasks", 0, "conversations that must finish first")
	window := set.String("window", "", "local time window")
	apply := set.String("apply", "", "auto or review")
	maxChanges := set.Int("max-changes", 0, "changes per dream")
	maxRetire := set.Int("max-retire-percent", 0, "share of memories a dream may retire")
	instructions := set.String("instructions", "", "extra instructions")
	instructionsFile := set.String("instructions-file", "", "extra instructions file")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if err = c.memoryMutation("change the memory setting"); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("memory settings update takes options only")
	}
	given := map[string]bool{}
	set.Visit(func(f *flag.Flag) { given[f.Name] = true })
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	current, err := client.GetMemorySettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	next := &dieterv1.MemorySettings{
		Dreaming: current.GetDreaming(), Harness: current.GetHarness(), Model: current.GetModel(), Effort: current.GetEffort(),
		AccountId: current.GetAccountId(), RunOn: current.GetRunOn(), MinHours: current.GetMinHours(), MinNewTasks: current.GetMinNewTasks(),
		Window: current.GetWindow(), Apply: current.GetApply(), MaxOperations: current.GetMaxOperations(),
		MaxRetirePercent: current.GetMaxRetirePercent(), Instructions: current.GetInstructions(),
	}
	if given["dreaming"] {
		switch *dreaming {
		case "on":
			next.Dreaming = true
		case "off":
			next.Dreaming = false
		default:
			return errors.New("--dreaming must be on or off")
		}
	}
	if given["harness"] {
		next.Harness = *harnessName
		if !given["model"] {
			next.Model, next.Effort = "", ""
		}
	}
	if given["model"] {
		next.Model = *modelName
	}
	if given["effort"] {
		next.Effort = *effort
	}
	if given["account"] {
		if next.AccountId, err = providerAccountID(rpcCtx, client, *account); err != nil {
			return err
		}
	}
	if given["run-on"] {
		next.RunOn = *runOn
	}
	if given["min-hours"] {
		next.MinHours = int32(*minHours)
	}
	if given["min-tasks"] {
		next.MinNewTasks = int32(*minTasks)
	}
	if given["window"] {
		next.Window = *window
	}
	if given["apply"] {
		next.Apply = *apply
	}
	if given["max-changes"] {
		next.MaxOperations = int32(*maxChanges)
	}
	if given["max-retire-percent"] {
		next.MaxRetirePercent = int32(*maxRetire)
	}
	if given["instructions"] || given["instructions-file"] {
		if next.Instructions, err = textValue(*instructions, *instructionsFile, c.In); err != nil {
			return err
		}
	}
	value, err := client.UpdateMemorySettings(rpcCtx, &dieterv1.UpdateMemorySettingsRequest{Settings: next, ExpectedRevision: current.GetRevision()})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writeMemorySettings(c.Out, value)
	return nil
}

func writeMemorySettings(out io.Writer, value *dieterv1.MemorySettings) {
	state := "off"
	if value.GetDreaming() {
		state = "on"
	}
	model := value.GetModel()
	if value.GetEffort() != "" {
		model += " (" + value.GetEffort() + ")"
	}
	account := value.GetAccountId()
	if account == "" {
		account = "provider default"
	}
	runOn := value.GetRunOn()
	if runOn == "" {
		runOn = "per project, the machine with most of its conversations"
	}
	window := value.GetWindow()
	if window == "" {
		window = "any time"
	}
	fmt.Fprintf(out, "Dreaming:\t%s\nHarness:\t%s\nModel:\t%s\nAccount:\t%s\nRuns on:\t%s\n", state, value.GetHarness(), model, account, runOn)
	fmt.Fprintf(out, "Gates:\t%d hours apart, after %d finished conversations, %s\n", value.GetMinHours(), value.GetMinNewTasks(), window)
	fmt.Fprintf(out, "Apply:\t%s\nLimits:\t%d changes, retire at most %d%%\n", value.GetApply(), value.GetMaxOperations(), value.GetMaxRetirePercent())
	if text := value.GetInstructions(); text != "" {
		fmt.Fprintf(out, "Instructions:\t%s\n", strings.ReplaceAll(text, "\n", "\n\t"))
	}
	if !value.GetConfigured() {
		fmt.Fprintln(out, "(defaults: no memory setting saved yet)")
	}
}

const memoryDreamHelp = `Usage: dieter memory dream <action>

Actions:
  start PROJECT   Start a dream of PROJECT now (dreaming need not be on)
  list PROJECT    List PROJECT's dreams on this machine, newest first
  apply CARD      Apply a dream's staged changes (apply mode review)
  discard CARD    Discard a dream's staged changes
  undo CARD       Restore the saved memories an applied dream changed

A dream is a conversation labelled Memory on the project's first board, on
the harness, model and account of dieter memory settings. Its agent reads the
saved memories and the conversations since the last dream and changes the
memories with one validated batch. Global --machine selects the machine that
ran the dream. Agent turns cannot start, apply, discard or undo dreams.
`

func (c *CLI) rpcMemoryDream(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, memoryDreamHelp)
		return nil
	}
	action, rest := args[0], args[1:]
	switch action {
	case "start", "list":
		usage := fmt.Sprintf("Usage: dieter memory dream %s [--format text|json] PROJECT\n\n%s\n", action, map[string]string{
			"start": "Start a dream of PROJECT now, regardless of the dreaming schedule, unless one is\nrunning or awaiting review. Agent turns cannot start dreams.",
			"list":  "List PROJECT's dreams on this machine, newest first.",
		}[action])
		set := flags("memory dream " + action)
		format := set.String("format", "text", "text or json")
		help, err := parse(set, rest, usage, c.Out)
		if help || err != nil {
			return err
		}
		if action == "start" {
			if err = c.memoryMutation("start a dream"); err != nil {
				return err
			}
		}
		if set.NArg() != 1 {
			return errors.New("exactly one PROJECT is required")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		if action == "start" {
			dream, err := client.StartMemoryDream(rpcCtx, &dieterv1.StartMemoryDreamRequest{ProjectId: set.Arg(0)})
			if err != nil {
				return err
			}
			if *format == "json" {
				return protoJSONOut(c.Out, dream)
			}
			if dream.GetStatus() == "failed" {
				return fmt.Errorf("dream %s could not start: %s", dream.GetCardId(), dream.GetError())
			}
			fmt.Fprintf(c.Out, "Dream %s is running. Follow it with: dieter card transcript %s\n", dream.GetCardId(), dream.GetCardId())
			return nil
		}
		value, err := client.ListMemoryDreams(rpcCtx, &dieterv1.ListMemoryDreamsRequest{ProjectId: set.Arg(0)})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, value)
		}
		if len(value.GetDreams()) == 0 {
			fmt.Fprintln(c.Out, "No dreams on this machine.")
			return nil
		}
		for _, dream := range value.GetDreams() {
			fmt.Fprintf(c.Out, "%s\t%s\t%s\t%s\n", dream.GetCardId(), dream.GetStatus(), dream.GetStartedAt(), dreamCounts(dream))
		}
		return nil
	case "apply", "discard", "undo":
		usage := fmt.Sprintf("Usage: dieter memory dream %s [--format text|json] CARD\n\n%s Agent turns cannot %s dreams.\nGlobal --machine selects the machine that ran the dream.\n", action, map[string]string{
			"apply":   "Apply a dream's staged changes after reviewing them (apply mode review); the batch is validated again against the memories as they are now.",
			"discard": "Discard a dream's staged changes.",
			"undo":    "Restore every saved memory an applied dream changed to its prior version and delete the memories it created.",
		}[action], action)
		set := flags("memory dream " + action)
		format := set.String("format", "text", "text or json")
		help, err := parse(set, rest, usage, c.Out)
		if help || err != nil {
			return err
		}
		if err = c.memoryMutation(action + " a dream"); err != nil {
			return err
		}
		if set.NArg() != 1 {
			return errors.New("exactly one CARD is required")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		ref := &dieterv1.MemoryDreamRef{CardId: set.Arg(0)}
		var dream *dieterv1.MemoryDream
		switch action {
		case "apply":
			dream, err = client.ApplyMemoryDream(rpcCtx, ref)
		case "discard":
			dream, err = client.DiscardMemoryDream(rpcCtx, ref)
		default:
			dream, err = client.UndoMemoryDream(rpcCtx, ref)
		}
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, dream)
		}
		fmt.Fprintf(c.Out, "Dream %s is %s: %s\n", dream.GetCardId(), dream.GetStatus(), dreamCounts(dream))
		return nil
	}
	return fmt.Errorf("unknown memory dream action %q; run `dieter memory dream --help`", action)
}

func dreamCounts(dream *dieterv1.MemoryDream) string {
	text := fmt.Sprintf("+%d added, %d merged, %d superseded, %d retired, %d verified", dream.GetAdded(), dream.GetMerged(), dream.GetSuperseded(), dream.GetRetired(), dream.GetVerified())
	if dream.GetError() != "" {
		text += " (" + dream.GetError() + ")"
	}
	return text
}

func (c *CLI) rpcCardMemory(args []string) error {
	const usage = `Usage: dieter card memory CARD on|off

Switch the conversation's agent memory on or off. From its next turn, while
its project has memory on, its finished turns are (or are not) indexed and its
agent gets (or loses) memory_recall and memory_save. Turning it off keeps
what was indexed; dieter memory forget --card CARD removes it.
Agent turns cannot switch it.
Global --machine selects the owning daemon through authenticated direct/relay routes.
`
	set := flags("card memory")
	help, err := parse(set, args, c.scoped(usage), c.Out)
	if help || err != nil {
		return err
	}
	if err = c.memoryMutation("switch memory"); err != nil {
		return err
	}
	if set.NArg() != 2 || (set.Arg(1) != "on" && set.Arg(1) != "off") {
		return errors.New("CARD and on or off are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	card, err := client.SetCardMemory(rpcCtx, &dieterv1.SetCardMemoryRequest{CardId: set.Arg(0), Enabled: set.Arg(1) == "on"})
	if err != nil {
		return err
	}
	state := "off"
	if card.GetMemory() {
		state = "on"
	}
	fmt.Fprintf(c.Out, "Memory %s for %s\n", state, card.GetId())
	return nil
}

func oneLine(text string) string { return strings.Join(strings.Fields(text), " ") }

func byteSize(value int64) string {
	switch {
	case value >= 1<<30:
		return fmt.Sprintf("%.1f GiB", float64(value)/(1<<30))
	case value >= 1<<20:
		return fmt.Sprintf("%.1f MiB", float64(value)/(1<<20))
	case value >= 1<<10:
		return fmt.Sprintf("%.1f KiB", float64(value)/(1<<10))
	}
	return fmt.Sprintf("%d B", value)
}
