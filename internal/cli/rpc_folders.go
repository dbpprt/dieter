package cli

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/encoding/protojson"
)

const folderHelp = `Usage: dieter folder <action> [options]

Synced folders: named directories that Dieter keeps the same on several of
your machines and phones. A folder's definition (name, rules, trash, deletion
guard, linked project) is shared by the account; each machine that keeps a
copy is a member with a directory of its own. Daemons sync with each other;
phones sync with one daemon. Use --machine to act on another machine's
membership.

  list       List the account's folders and their members
  show       Show one folder with its members
  create     Create a folder (it has no members yet)
  update     Change a folder's name, rules, trash, deletion guard or project
  archive    Stop syncing a folder everywhere; files stay
  attach     Keep a copy of a folder in a directory of the target machine
  member     Change the target machine's mode, limits and watching
  pause      Pause syncing on the target machine
  resume     Resume syncing on the target machine
  detach     Stop syncing on the target machine; files stay
  status     Show the target machine's progress, conflicts and problems
  rescan     Scan the target machine's copy now
  deletions  Apply or undo deletions the deletion guard holds
  trash      List, restore or purge old versions the target machine kept
  index      Print a page of the target machine's index (protocol)
  blocks     Print the block hashes of a large file (protocol)
  apply      Create a directory or record a deletion (protocol)
  client     Register or unregister a phone member (protocol)

Agent turns can read status, rescan, restore from the trash and transfer
files, but cannot create, attach, change or detach folders, register
members, confirm deletions or purge the trash.
`

func (c *CLI) rpcFolder(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, folderHelp)
		return nil
	}
	actions := map[string]func([]string) error{
		"list": c.folderList, "ls": c.folderList, "show": c.folderShow, "create": c.folderCreate, "update": c.folderUpdate,
		"archive": c.folderArchive, "attach": c.folderAttach, "member": c.folderMember, "pause": c.folderPause(true),
		"resume": c.folderPause(false), "detach": c.folderDetach, "status": c.folderStatus, "rescan": c.folderRescan,
		"deletions": c.folderDeletions, "trash": c.folderTrash, "index": c.folderIndex, "blocks": c.folderBlocks,
		"apply": c.folderApply, "client": c.folderClient,
	}
	action, ok := actions[args[0]]
	if !ok {
		return fmt.Errorf("unknown folder action %q; run `dieter folder --help`", args[0])
	}
	return action(args[1:])
}

// folderMutation refuses changes inside an agent turn before any daemon is
// contacted: the turn token reaches only the local daemon, so --machine
// would otherwise bypass the daemon's refusal.
func (c *CLI) folderMutation() error {
	if c.env.TurnToken != "" {
		return errors.New("agent turns cannot change synced folders; ask the user")
	}
	return nil
}

func folderModeFlag(value string) (dieterv1.FolderMode, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "two-way", "":
		return dieterv1.FolderMode_FOLDER_MODE_TWO_WAY, nil
	case "send-only", "upload-only":
		return dieterv1.FolderMode_FOLDER_MODE_SEND_ONLY, nil
	case "receive-only", "download-only":
		return dieterv1.FolderMode_FOLDER_MODE_RECEIVE_ONLY, nil
	}
	return 0, errors.New("--mode is two-way, send-only or receive-only")
}

func folderModeLabel(mode dieterv1.FolderMode) string {
	switch mode {
	case dieterv1.FolderMode_FOLDER_MODE_SEND_ONLY:
		return "send-only"
	case dieterv1.FolderMode_FOLDER_MODE_RECEIVE_ONLY:
		return "receive-only"
	}
	return "two-way"
}

func folderStateLabel(state dieterv1.FolderState) string {
	label := strings.ToLower(strings.TrimPrefix(state.String(), "FOLDER_STATE_"))
	if label == "unspecified" {
		return "unknown"
	}
	return label
}

func folderGuardFlag(value string) (dieterv1.FolderDeleteGuard, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "default":
		return dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_DEFAULT, nil
	case "strict":
		return dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_STRICT, nil
	case "off":
		return dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_OFF, nil
	}
	return 0, errors.New("--delete-guard is default, strict or off")
}

func folderGuardLabel(guard dieterv1.FolderDeleteGuard) string {
	switch guard {
	case dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_STRICT:
		return "strict"
	case dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_OFF:
		return "off"
	}
	return "default"
}

// trashDaysFlag parses 7, 30, 90 or off.
func trashDaysFlag(value string) (int32, error) {
	switch strings.TrimSpace(value) {
	case "off", "0":
		return -1, nil
	case "7", "30", "90":
		days, _ := strconv.Atoi(value)
		return int32(days), nil
	}
	return 0, errors.New("--trash-days is 7, 30, 90 or off")
}

type ruleList []string

func (r *ruleList) String() string     { return strings.Join(*r, ",") }
func (r *ruleList) Set(v string) error { *r = append(*r, v); return nil }

func (c *CLI) folderList(args []string) error {
	const usage = `Usage: dieter folder list [--archived] [--format text|json]

List the account's synced folders with their members. Daemon members show
their state; phones show when they last synced.
`
	set := flags("folder list")
	archived := set.Bool("archived", false, "include archived folders")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	list, err := client.ListFolders(rpcCtx, &dieterv1.ListFoldersRequest{IncludeArchived: *archived})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, list)
	}
	if len(list.GetFolders()) == 0 {
		_, err := fmt.Fprintln(c.Out, "No synced folders. Create one with `dieter folder create NAME`.")
		return err
	}
	w := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tID\tMEMBERS\tSTATE")
	for _, folder := range list.GetFolders() {
		state := "no members"
		var members []string
		for _, member := range folder.GetMembers() {
			members = append(members, member.GetName())
			if member.GetKind() == dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_DAEMON {
				if state == "no members" || member.GetState() != dieterv1.FolderState_FOLDER_STATE_IDLE {
					state = folderStateLabel(member.GetState())
				}
			}
		}
		if folder.GetArchived() {
			state = "archived"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", folder.GetName(), folder.GetId(), strings.Join(members, ", "), state)
	}
	return w.Flush()
}

func (c *CLI) findFolder(ref string) (*dieterv1.Folder, error) {
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, err
	}
	list, err := client.ListFolders(rpcCtx, &dieterv1.ListFoldersRequest{IncludeArchived: true})
	if err != nil {
		return nil, err
	}
	var found []*dieterv1.Folder
	for _, folder := range list.GetFolders() {
		if folder.GetId() == ref || folder.GetName() == ref {
			found = append(found, folder)
		}
	}
	switch len(found) {
	case 0:
		return nil, fmt.Errorf("folder %q not found", ref)
	case 1:
		return found[0], nil
	}
	return nil, fmt.Errorf("several folders are named %q; use the folder ID", ref)
}

func (c *CLI) printFolder(folder *dieterv1.Folder) error {
	w := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintf(w, "Folder:\t%s (%s)\n", folder.GetName(), folder.GetId())
	if folder.GetArchived() {
		fmt.Fprintf(w, "State:\tarchived\n")
	}
	trash := "off"
	if folder.GetTrashDays() > 0 {
		trash = fmt.Sprintf("%d days", folder.GetTrashDays())
	}
	fmt.Fprintf(w, "Trash:\t%s\n", trash)
	fmt.Fprintf(w, "Deletion guard:\t%s\n", folderGuardLabel(folder.GetDeleteGuard()))
	if folder.GetProjectId() != "" {
		fmt.Fprintf(w, "Linked project:\t%s\n", folder.GetProjectId())
	}
	fmt.Fprintf(w, "Rules:\t%s\n", strings.Join(folder.GetRules(), " "))
	if len(folder.GetConflictFields()) > 0 {
		fmt.Fprintf(w, "Concurrent edits:\t%s\n", strings.Join(folder.GetConflictFields(), ", "))
	}
	if err := w.Flush(); err != nil {
		return err
	}
	if len(folder.GetMembers()) == 0 {
		_, err := fmt.Fprintln(c.Out, "\nNo members yet. Add a machine with `dieter [--machine NAME] folder attach FOLDER PATH`.")
		return err
	}
	fmt.Fprintln(c.Out)
	w = tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "MEMBER\tKIND\tMODE\tSTATE\tLAST SYNC\tPATH")
	for _, member := range folder.GetMembers() {
		kind := "daemon"
		state := folderStateLabel(member.GetState())
		if member.GetKind() == dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_CLIENT {
			kind, state = "phone", "via "+member.GetHomeDaemonId()
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", member.GetName(), kind, folderModeLabel(member.GetMode()), state, dash(member.GetLastSyncAt()), member.GetPath())
	}
	return w.Flush()
}

func dash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func (c *CLI) folderShow(args []string) error {
	const usage = `Usage: dieter folder show FOLDER [--format text|json]

Show a folder's definition and members. FOLDER is an ID or a unique name.
Only the target machine reports its own directory.
`
	set := flags("folder show")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	folder, err := c.findFolder(set.Arg(0))
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, folder)
	}
	return c.printFolder(folder)
}

func (c *CLI) folderCreate(args []string) error {
	const usage = `Usage: dieter folder create NAME [options]

Create a synced folder. It has no members until a machine attaches it.

Options:
  --rule RULE             Add a rule: -PATTERN excludes, +PATTERN includes;
                          repeatable, the last match wins. '*' also matches '/'.
                          An excluded directory excludes everything inside it.
  --no-default-rules      Start without the default rules (.DS_Store,
                          Thumbs.db, editor swap and temporary files)
  --project PROJECT_ID    Link a project: its agents learn the folder's path
  --trash-days 7|30|90|off  How long members keep old versions (default 30)
  --delete-guard default|strict|off
                          Hold mass deletions for confirmation (default:
                          more than 100 files or 30% of the folder)
  --format text|json|id   Output format (default text)
`
	set := flags("folder create")
	var rules ruleList
	set.Var(&rules, "rule", "rule")
	noDefaults := set.Bool("no-default-rules", false, "no default rules")
	project := set.String("project", "", "linked project ID")
	trash := set.String("trash-days", "30", "7, 30, 90 or off")
	guard := set.String("delete-guard", "default", "default, strict or off")
	format := set.String("format", "text", "text, json or id")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("NAME required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	days, err := trashDaysFlag(*trash)
	if err != nil {
		return err
	}
	deleteGuard, err := folderGuardFlag(*guard)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	folder, err := client.CreateFolder(rpcCtx, &dieterv1.CreateFolderRequest{Name: set.Arg(0), Rules: rules, NoDefaultRules: *noDefaults, ProjectId: *project, TrashDays: days, DeleteGuard: deleteGuard})
	if err != nil {
		return err
	}
	switch *format {
	case "json":
		return protoJSONOut(c.Out, folder)
	case "id":
		_, err = fmt.Fprintln(c.Out, folder.GetId())
		return err
	}
	_, err = fmt.Fprintf(c.Out, "Created %s (%s). Add a machine with `dieter folder attach %s PATH`.\n", folder.GetName(), folder.GetId(), folder.GetId())
	return err
}

func (c *CLI) folderUpdate(args []string) error {
	const usage = `Usage: dieter folder update FOLDER [options]

Change a folder's shared definition. Every member applies it.

Options:
  --name NAME             Rename the folder
  --rule RULE             Replace the rules with these (repeatable); see create
  --clear-rules           Remove every rule
  --project PROJECT_ID    Link a project
  --unlink-project        Remove the project link
  --trash-days 7|30|90|off
  --delete-guard default|strict|off
  --format text|json      Output format (default text)
`
	set := flags("folder update")
	name := set.String("name", "", "new name")
	var rules ruleList
	set.Var(&rules, "rule", "rule")
	clearRules := set.Bool("clear-rules", false, "remove every rule")
	project := set.String("project", "", "linked project ID")
	unlink := set.Bool("unlink-project", false, "remove the project link")
	trash := set.String("trash-days", "", "7, 30, 90 or off")
	guard := set.String("delete-guard", "", "default, strict or off")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	request := &dieterv1.UpdateFolderRequest{FolderId: set.Arg(0)}
	changed := false
	if *name != "" {
		request.Name, changed = name, true
	}
	if len(rules) > 0 || *clearRules {
		if len(rules) > 0 && *clearRules {
			return errors.New("use either --rule or --clear-rules")
		}
		request.SetRules, request.Rules, changed = true, rules, true
	}
	if *project != "" && *unlink {
		return errors.New("use either --project or --unlink-project")
	}
	if *project != "" {
		request.ProjectId, changed = project, true
	}
	if *unlink {
		empty := ""
		request.ProjectId, changed = &empty, true
	}
	if *trash != "" {
		days, err := trashDaysFlag(*trash)
		if err != nil {
			return err
		}
		request.TrashDays, changed = &days, true
	}
	if *guard != "" {
		value, err := folderGuardFlag(*guard)
		if err != nil {
			return err
		}
		request.DeleteGuard, changed = &value, true
	}
	if !changed {
		return errors.New("nothing to change\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	folder, err := client.UpdateFolder(rpcCtx, request)
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, folder)
	}
	return c.printFolder(folder)
}

func (c *CLI) folderArchive(args []string) error {
	const usage = `Usage: dieter folder archive FOLDER

Stop syncing a folder on every member. Files stay where they are.
`
	set := flags("folder archive")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	folder, err := client.ArchiveFolder(rpcCtx, &dieterv1.FolderRef{FolderId: set.Arg(0)})
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(c.Out, "Archived %s; its members stopped syncing.\n", folder.GetName())
	return err
}

func (c *CLI) folderAttach(args []string) error {
	const usage = `Usage: dieter folder attach FOLDER PATH [options]

Keep a copy of FOLDER in PATH, an absolute directory on the target machine
(created when missing). Dieter refuses system directories, your home
directory itself, Dieter's own storage, registered checkouts and the
directories of other synced folders.

Options:
  --mode two-way|send-only|receive-only   Direction (default two-way)
  --join merge|adopt      When PATH already has files that differ from the
                          folder: merge keeps both versions (conflict copies),
                          adopt moves the local versions to the trash first
                          (default merge)
  --dryrun                Print the join plan without changing anything
  --format text|json      Output format (default text)
`
	set := flags("folder attach")
	mode := set.String("mode", "two-way", "direction")
	join := set.String("join", "merge", "merge or adopt")
	dry := set.Bool("dryrun", false, "plan only")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 2 {
		return errors.New("FOLDER and PATH required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	folderMode, err := folderModeFlag(*mode)
	if err != nil {
		return err
	}
	request := &dieterv1.AttachFolderRequest{FolderId: set.Arg(0), Path: set.Arg(1), Mode: folderMode, DryRun: *dry}
	switch *join {
	case "merge":
		request.Join = dieterv1.FolderJoin_FOLDER_JOIN_MERGE
	case "adopt":
		request.Join = dieterv1.FolderJoin_FOLDER_JOIN_ADOPT
	default:
		return errors.New("--join is merge or adopt")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	result, err := client.AttachFolder(rpcCtx, request)
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, result)
	}
	if result.GetDryRun() {
		fmt.Fprintf(c.Out, "Plan for %s: %d identical, %d new, %d conflicts, %d to trash\n", result.GetMember().GetPath(), result.GetAdopt(), result.GetNewFiles(), result.GetConflicts(), result.GetTrash())
		for _, entry := range result.GetPlan() {
			fmt.Fprintf(c.Out, "%-8s %s\n", entry.GetAction(), entry.GetPath())
		}
		return nil
	}
	_, err = fmt.Fprintf(c.Out, "Attached %s at %s (%s).\n", set.Arg(0), result.GetMember().GetPath(), folderModeLabel(result.GetMember().GetMode()))
	return err
}

func (c *CLI) printMember(member *dieterv1.FolderMember) error {
	w := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintf(w, "Path:\t%s\n", member.GetPath())
	fmt.Fprintf(w, "Mode:\t%s\n", folderModeLabel(member.GetMode()))
	state := folderStateLabel(member.GetState())
	if member.GetStateDetail() != "" {
		state += ": " + member.GetStateDetail()
	}
	fmt.Fprintf(w, "State:\t%s\n", state)
	fmt.Fprintf(w, "Watch:\t%v (rescan every %ds)\n", member.GetWatch(), member.GetRescanSeconds())
	bandwidth := "unlimited"
	if member.GetBandwidthLimit() > 0 {
		bandwidth = fmt.Sprintf("%d B/s", member.GetBandwidthLimit())
	}
	fmt.Fprintf(w, "Transfers:\t%d at a time, %s\n", member.GetConcurrency(), bandwidth)
	fmt.Fprintf(w, "Quarantine:\t%v\n", member.GetQuarantine())
	return w.Flush()
}

func (c *CLI) folderMember(args []string) error {
	const usage = `Usage: dieter folder member FOLDER [options]

Show or change the target machine's membership of FOLDER.

Options:
  --mode two-way|send-only|receive-only
  --rescan SECONDS        Full walk interval while watching (60..604800)
  --bandwidth-limit BYTES_PER_SECOND   0 is unlimited
  --concurrency N         Files transferred at a time (1..8)
  --quarantine true|false Mark received files as downloaded (macOS)
  --watch true|false      Watch the directory for changes
  --format text|json      Output format (default text)
`
	set := flags("folder member")
	mode := set.String("mode", "", "direction")
	rescan := set.Int("rescan", 0, "seconds")
	bandwidth := set.Int64("bandwidth-limit", -1, "bytes per second")
	concurrency := set.Int("concurrency", 0, "1..8")
	quarantine := set.String("quarantine", "", "true or false")
	watch := set.String("watch", "", "true or false")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	request := &dieterv1.UpdateFolderMemberRequest{FolderId: set.Arg(0)}
	changed := false
	if *mode != "" {
		value, err := folderModeFlag(*mode)
		if err != nil {
			return err
		}
		request.Mode, changed = &value, true
	}
	if *rescan != 0 {
		value := int32(*rescan)
		request.RescanSeconds, changed = &value, true
	}
	if *bandwidth >= 0 {
		request.BandwidthLimit, changed = bandwidth, true
	}
	if *concurrency != 0 {
		value := int32(*concurrency)
		request.Concurrency, changed = &value, true
	}
	for _, option := range []struct {
		value  string
		target **bool
	}{{*quarantine, &request.Quarantine}, {*watch, &request.Watch}} {
		if option.value == "" {
			continue
		}
		parsed, err := strconv.ParseBool(option.value)
		if err != nil {
			return errors.New("--quarantine and --watch take true or false")
		}
		*option.target, changed = &parsed, true
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var member *dieterv1.FolderMember
	if changed {
		if err := c.folderMutation(); err != nil {
			return err
		}
		member, err = client.UpdateFolderMember(rpcCtx, request)
	} else {
		var status *dieterv1.FolderStatus
		status, err = client.GetFolderStatus(rpcCtx, &dieterv1.FolderRef{FolderId: set.Arg(0)})
		member = status.GetMember()
	}
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, member)
	}
	return c.printMember(member)
}

func (c *CLI) folderPause(pause bool) func([]string) error {
	return func(args []string) error {
		name, verb := "pause", "Paused"
		if !pause {
			name, verb = "resume", "Resumed"
		}
		usage := "Usage: dieter folder " + name + " FOLDER\n\n" + verb + " syncing FOLDER on the target machine.\n"
		set := flags("folder " + name)
		if help, err := parse(set, args, usage, c.Out); help || err != nil {
			return err
		}
		if set.NArg() != 1 {
			return errors.New("FOLDER required\n\n" + usage)
		}
		if err := c.folderMutation(); err != nil {
			return err
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		if _, err := client.UpdateFolderMember(rpcCtx, &dieterv1.UpdateFolderMemberRequest{FolderId: set.Arg(0), Paused: &pause}); err != nil {
			return err
		}
		_, err = fmt.Fprintf(c.Out, "%s %s.\n", verb, set.Arg(0))
		return err
	}
}

func (c *CLI) folderDetach(args []string) error {
	const usage = `Usage: dieter folder detach FOLDER

Stop syncing FOLDER on the target machine. Its files stay on disk; the
machine's index and trash of the folder are removed.
`
	set := flags("folder detach")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	if _, err := client.DetachFolder(rpcCtx, &dieterv1.FolderRef{FolderId: set.Arg(0)}); err != nil {
		return err
	}
	_, err = fmt.Fprintf(c.Out, "Detached %s; its files stay on disk.\n", set.Arg(0))
	return err
}

func (c *CLI) printStatus(status *dieterv1.FolderStatus) error {
	member := status.GetMember()
	w := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	state := folderStateLabel(member.GetState())
	if member.GetStateDetail() != "" {
		state += ": " + member.GetStateDetail()
	}
	fmt.Fprintf(w, "Path:\t%s (%s)\n", member.GetPath(), folderModeLabel(member.GetMode()))
	fmt.Fprintf(w, "State:\t%s\n", state)
	fmt.Fprintf(w, "Contents:\t%d entries, %d files, %d bytes\n", status.GetEntries(), status.GetFiles(), status.GetBytes())
	fmt.Fprintf(w, "Index:\t%s at %d\n", status.GetIndexId(), status.GetSequence())
	fmt.Fprintf(w, "Last scan:\t%s\n", dash(status.GetLastScanAt()))
	fmt.Fprintf(w, "Last sync:\t%s\n", dash(member.GetLastSyncAt()))
	if member.GetNeedFiles() > 0 {
		fmt.Fprintf(w, "Needs:\t%d files, %d bytes\n", member.GetNeedFiles(), member.GetNeedBytes())
	}
	if err := w.Flush(); err != nil {
		return err
	}
	section := func(title string, lines []string) {
		if len(lines) == 0 {
			return
		}
		fmt.Fprintf(c.Out, "\n%s:\n", title)
		for _, line := range lines {
			fmt.Fprintf(c.Out, "  %s\n", line)
		}
	}
	if pending := status.GetPendingDeletions(); pending != nil {
		lines := append([]string{fmt.Sprintf("%d deletions (%s) wait: `dieter folder deletions FOLDER --apply` or `--restore`", pending.GetCount(), pending.GetSource())}, pending.GetSample()...)
		section("Held deletions", lines)
	}
	section("Conflict copies", status.GetConflicts())
	var peers, problems, unsyncable []string
	for _, peer := range status.GetPeers() {
		line := fmt.Sprintf("%s: last sync %s", peer.GetName(), dash(peer.GetLastSyncAt()))
		if peer.GetError() != "" {
			line += " — " + peer.GetError()
		}
		peers = append(peers, line)
	}
	for _, problem := range status.GetErrors() {
		problems = append(problems, strings.TrimSpace(problem.GetPath()+" "+problem.GetMessage()))
	}
	for _, problem := range status.GetUnsyncable() {
		unsyncable = append(unsyncable, problem.GetPath()+": "+problem.GetMessage())
	}
	section("Peers", peers)
	section("Local changes not sent (receive-only)", status.GetLocalChanges())
	section("Remote changes not applied (send-only)", status.GetOutOfSync())
	section("Can't sync here", unsyncable)
	section("Recent errors", problems)
	return nil
}

func (c *CLI) folderStatus(args []string) error {
	const usage = `Usage: dieter folder status FOLDER [--format text|json]

Show the target machine's copy of FOLDER: state, contents, peers, held
deletions, conflict copies, paths it can't sync and recent errors.
`
	set := flags("folder status")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	status, err := client.GetFolderStatus(rpcCtx, &dieterv1.FolderRef{FolderId: set.Arg(0)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, status)
	}
	return c.printStatus(status)
}

func (c *CLI) folderRescan(args []string) error {
	const usage = `Usage: dieter folder rescan FOLDER [--format text|json]

Scan the target machine's copy now and exchange with its peers; waits up to
a minute for the round, then prints the status.
`
	set := flags("folder rescan")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER required\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	status, err := client.RescanFolder(rpcCtx, &dieterv1.FolderRef{FolderId: set.Arg(0)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, status)
	}
	return c.printStatus(status)
}

func (c *CLI) folderDeletions(args []string) error {
	const usage = `Usage: dieter folder deletions FOLDER (--apply | --restore)

The deletion guard holds batches that would delete many files. --apply
deletes them; --restore brings the files back (local deletions are
downloaded again, remote ones are revived on every member).
`
	set := flags("folder deletions")
	apply := set.Bool("apply", false, "apply the deletions")
	restore := set.Bool("restore", false, "restore the files")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 || *apply == *restore {
		return errors.New("FOLDER and exactly one of --apply or --restore required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	status, err := client.ResolveFolderDeletions(rpcCtx, &dieterv1.ResolveFolderDeletionsRequest{FolderId: set.Arg(0), Apply: *apply})
	if err != nil {
		return err
	}
	return c.printStatus(status)
}

func (c *CLI) folderTrash(args []string) error {
	const help = `Usage: dieter folder trash <list|restore|purge> FOLDER [options]

Old versions the target machine kept: files deleted or replaced by a change
from another member, for the folder's trash days.

  list FOLDER [--after ID] [--limit N] [--format text|json]
  restore FOLDER ITEM_ID     Put a version back at its path as a new change
  purge FOLDER [ITEM_ID...]  Forget versions for good; without IDs, all
`
	if groupHelp(args) {
		fmt.Fprint(c.Out, help)
		return nil
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "list", "ls":
		set := flags("folder trash list")
		after := set.String("after", "", "continue after this item ID")
		limit := set.Int("limit", 100, "items per page")
		format := set.String("format", "text", "text or json")
		if h, err := parse(set, rest, "Usage: dieter folder trash list FOLDER [--after ID] [--limit N] [--format text|json]\n\nList old versions the target machine kept, newest first.\n", c.Out); h || err != nil {
			return err
		}
		if set.NArg() != 1 {
			return errors.New("FOLDER required")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		page, err := client.ListFolderTrash(rpcCtx, &dieterv1.ListFolderTrashRequest{FolderId: set.Arg(0), After: *after, PageSize: int32(*limit)})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, page)
		}
		w := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tPATH\tSIZE\tREASON\tBY\tAT")
		for _, item := range page.GetItems() {
			fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%s\t%s\n", item.GetId(), item.GetPath(), item.GetSize(), item.GetReason(), dash(item.GetDeletedBy()), item.GetDeletedAt())
		}
		if page.GetNext() != "" {
			fmt.Fprintf(w, "\nMore: --after %s\n", page.GetNext())
		}
		return w.Flush()
	case "restore":
		set := flags("folder trash restore")
		if h, err := parse(set, rest, "Usage: dieter folder trash restore FOLDER ITEM_ID\n\nPut an old version back at its path. It syncs to every member as a new change.\n", c.Out); h || err != nil {
			return err
		}
		if set.NArg() != 2 {
			return errors.New("FOLDER and ITEM_ID required")
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		entry, err := client.RestoreFolderTrash(rpcCtx, &dieterv1.RestoreFolderTrashRequest{FolderId: set.Arg(0), Id: set.Arg(1)})
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(c.Out, "Restored %s.\n", entry.GetPath())
		return err
	case "purge":
		set := flags("folder trash purge")
		if h, err := parse(set, rest, "Usage: dieter folder trash purge FOLDER [ITEM_ID...]\n\nForget old versions for good. Without IDs the whole trash is emptied.\n", c.Out); h || err != nil {
			return err
		}
		if set.NArg() < 1 {
			return errors.New("FOLDER required")
		}
		if err := c.folderMutation(); err != nil {
			return err
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		if _, err := client.PurgeFolderTrash(rpcCtx, &dieterv1.PurgeFolderTrashRequest{FolderId: set.Arg(0), Ids: set.Args()[1:]}); err != nil {
			return err
		}
		_, err = fmt.Fprintln(c.Out, "Purged.")
		return err
	}
	return fmt.Errorf("unknown folder trash action %q; run `dieter folder trash --help`", sub)
}

func (c *CLI) folderIndex(args []string) error {
	const usage = `Usage: dieter folder index FOLDER [--index-id ID] [--after SEQUENCE] [--limit N] [--member ID]

Print one page of the target machine's index of FOLDER as JSON: entries with
version vectors, the index ID, the last sequence and whether more follow.
Pass the page's index ID and sequence with --index-id and --after for the
next page. A different index ID restarts from the beginning (reset).
--member records how far that member got (peers and phones pass their ID).
`
	set := flags("folder index")
	indexID := set.String("index-id", "", "index ID of the checkpoint")
	after := set.Uint64("after", 0, "sequence to continue after")
	limit := set.Int("limit", 512, "1..512")
	member := set.String("member", "", "member ID")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("FOLDER ID required\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	folderID, err := c.folderID(set.Arg(0))
	if err != nil {
		return err
	}
	page, err := client.GetFolderIndex(rpcCtx, &dieterv1.GetFolderIndexRequest{FolderId: folderID, IndexId: *indexID, AfterSequence: *after, PageSize: int32(*limit), MemberId: *member})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, page)
}

// folderID resolves a folder name for protocol calls that take IDs only.
func (c *CLI) folderID(ref string) (string, error) {
	if strings.HasPrefix(ref, "fo_") {
		return ref, nil
	}
	folder, err := c.findFolder(ref)
	if err != nil {
		return "", err
	}
	return folder.GetId(), nil
}

func (c *CLI) folderBlocks(args []string) error {
	const usage = `Usage: dieter folder blocks FOLDER PATH --sha256 SHA256 [--after N] [--limit N]

Print the 1 MiB block hashes of PATH at content SHA256 on the target machine
as JSON. Members use them to download only the changed blocks of large files.
`
	set := flags("folder blocks")
	sha := set.String("sha256", "", "content SHA-256 of the version")
	after := set.Int("after", 0, "first block index")
	limit := set.Int("limit", 4096, "1..4096")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 2 || *sha == "" {
		return errors.New("FOLDER, PATH and --sha256 required\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	folderID, err := c.folderID(set.Arg(0))
	if err != nil {
		return err
	}
	page, err := client.GetFolderBlocks(rpcCtx, &dieterv1.GetFolderBlocksRequest{FolderId: folderID, Path: set.Arg(1), Sha256: *sha, After: int32(*after), PageSize: int32(*limit)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, page)
}

func (c *CLI) folderApply(args []string) error {
	const usage = `Usage: dieter folder apply FOLDER --entry JSON

Create a directory or record a deletion on the target machine, as phones and
peers do. JSON is a FolderEntry (path, kind FOLDER_ENTRY_KIND_DIRECTORY or
FOLDER_ENTRY_KIND_DELETED, version, authorId, authorName) whose version must
dominate the machine's entry; files are uploaded with ` + "`dieter file upload`" + ` instead.
`
	set := flags("folder apply")
	raw := set.String("entry", "", "FolderEntry JSON")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 || *raw == "" {
		return errors.New("FOLDER and --entry required\n\n" + usage)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	entry := &dieterv1.FolderEntry{}
	if err := protojson.Unmarshal([]byte(*raw), entry); err != nil {
		return fmt.Errorf("invalid --entry: %w", err)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	folderID, err := c.folderID(set.Arg(0))
	if err != nil {
		return err
	}
	result, err := client.ApplyFolderEntry(rpcCtx, &dieterv1.ApplyFolderEntryRequest{FolderId: folderID, Entry: entry})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, result)
}

func (c *CLI) folderClient(args []string) error {
	const help = `Usage: dieter folder client <register|unregister> FOLDER --device ID [options]

Make the target machine the home daemon of a phone member, or forget it.
Phones register themselves; this is for tests and tooling.

  register FOLDER --device ID [--name NAME] [--mode two-way|send-only|receive-only]
  unregister FOLDER --device ID
`
	if groupHelp(args) {
		fmt.Fprint(c.Out, help)
		return nil
	}
	sub, rest := args[0], args[1:]
	if sub != "register" && sub != "unregister" {
		return fmt.Errorf("unknown folder client action %q; run `dieter folder client --help`", sub)
	}
	set := flags("folder client " + sub)
	device := set.String("device", "", "device ID")
	name := set.String("name", "", "device name")
	mode := set.String("mode", "two-way", "direction")
	if h, err := parse(set, rest, help, c.Out); h || err != nil {
		return err
	}
	if set.NArg() != 1 || *device == "" {
		return errors.New("FOLDER and --device required\n\n" + help)
	}
	if err := c.folderMutation(); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	if sub == "unregister" {
		if _, err := client.UnregisterFolderClient(rpcCtx, &dieterv1.FolderClientRef{FolderId: set.Arg(0), DeviceId: *device}); err != nil {
			return err
		}
		_, err = fmt.Fprintln(c.Out, "Unregistered.")
		return err
	}
	folderMode, err := folderModeFlag(*mode)
	if err != nil {
		return err
	}
	member, err := client.RegisterFolderClient(rpcCtx, &dieterv1.RegisterFolderClientRequest{FolderId: set.Arg(0), DeviceId: *device, Name: *name, Mode: folderMode})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, member)
}
