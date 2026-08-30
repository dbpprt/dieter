package cli

import (
	"errors"
	"fmt"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const workspaceHelp = `Usage: dieter workspace <action>

Actions:
  show CARD                 Provision and show a conversation workspace
  list [--project PROJECT]  List durable project workspaces
  changes CARD              Show the current changeset and revision
  diff --path PATH CARD     Read a revision-checked file or commit diff
  comments CARD             List changeset review comments
  comment [options] CARD    Add a changeset review comment
  scm CARD                  Show daemon-host source-control capabilities
  operation OPERATION       Show a durable Git operation
  watch OPERATION           Stream operation and log frames as JSON Lines
  run --kind KIND CARD      Start a serialized durable Git operation
  cancel OPERATION          Request cancellation of an operation

Operation kinds include commit, update, continue_conflict, abort_conflict,
validate, merge_local, push, cleanup, discard, adopt, create_pr, refresh_pr,
and merge_pr. Repeat --param KEY=VALUE for kind-specific parameters.
`

func (c *CLI) rpcWorkspace(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, workspaceHelp)
		return nil
	}
	switch args[0] {
	case "show":
		return c.rpcWorkspaceShow(args[1:])
	case "list", "ls":
		return c.rpcWorkspaceList(args[1:])
	case "changes", "status":
		return c.rpcWorkspaceChanges(args[1:])
	case "diff":
		return c.rpcWorkspaceDiff(args[1:])
	case "comments":
		return c.rpcWorkspaceComments(args[1:])
	case "comment":
		return c.rpcWorkspaceComment(args[1:])
	case "scm":
		return c.rpcWorkspaceSCM(args[1:])
	case "operation", "op":
		return c.rpcWorkspaceOperation(args[1:])
	case "watch":
		return c.rpcWorkspaceWatch(args[1:])
	case "run":
		return c.rpcWorkspaceRun(args[1:])
	case "cancel":
		return c.rpcWorkspaceCancel(args[1:])
	default:
		return fmt.Errorf("unknown workspace action %q; run `dieter workspace --help`", args[0])
	}
}

func (c *CLI) rpcWorkspaceShow(args []string) error {
	const usage = "Usage: dieter workspace show CARD\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetWorkspace(rpcCtx, &dieterv1.ConversationRef{CardId: args[0]})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceList(args []string) error {
	const usage = "Usage: dieter workspace list --project PROJECT\n"
	set := flags("workspace list")
	projectRef := set.String("project", "", "exact project ID or unique name")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*projectRef) == "" {
		return errors.New("--project is required")
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
	project, err := resolveProtoProject(state, *projectRef)
	if err != nil {
		return err
	}
	value, err := client.ListProjectWorkspaces(rpcCtx, &dieterv1.ProjectRef{ProjectId: project.GetId()})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceChanges(args []string) error {
	const usage = "Usage: dieter workspace changes CARD\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetChangeset(rpcCtx, &dieterv1.GetChangesetRequest{CardId: args[0]})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceDiff(args []string) error {
	const usage = "Usage: dieter workspace diff --path PATH [--revision REVISION] [--commit SHA] [--offset N] [--limit N] CARD\n"
	set := flags("workspace diff")
	path := set.String("path", "", "workspace-relative file path")
	revision := set.String("revision", "", "expected changeset revision; current revision when omitted")
	commit := set.String("commit", "", "commit SHA instead of working-tree diff")
	offset := set.Int64("offset", 0, "diff byte offset")
	limit := set.Int("limit", 0, "maximum bytes; daemon default when zero")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*path) == "" {
		return errors.New("CARD and --path are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*revision) == "" {
		changes, readErr := client.GetChangeset(rpcCtx, &dieterv1.GetChangesetRequest{CardId: set.Arg(0)})
		if readErr != nil {
			return readErr
		}
		*revision = changes.GetRevision()
	}
	request := &dieterv1.GetDiffRequest{CardId: set.Arg(0), Path: *path, CommitSha: *commit, ExpectedRevision: *revision, Offset: *offset, Limit: int32(*limit)}
	var value *dieterv1.FileDiff
	if strings.TrimSpace(*commit) == "" {
		value, err = client.GetFileDiff(rpcCtx, request)
	} else {
		value, err = client.GetCommitDiff(rpcCtx, request)
	}
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceComments(args []string) error {
	const usage = "Usage: dieter workspace comments [--revision REVISION] CARD\n"
	set := flags("workspace comments")
	revision := set.String("revision", "", "changeset revision filter")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
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
	value, err := client.ListChangeComments(rpcCtx, &dieterv1.ListChangeCommentsRequest{CardId: set.Arg(0), Revision: *revision})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceComment(args []string) error {
	const usage = "Usage: dieter workspace comment --path PATH --revision REVISION --message TEXT [--side new|old] [--line N] [--author NAME] [--commit SHA] CARD\n"
	set := flags("workspace comment")
	path := set.String("path", "", "workspace-relative file path")
	revision := set.String("revision", "", "changeset revision")
	message := set.String("message", "", "comment body")
	side := set.String("side", "new", "new or old diff side")
	line := set.Int("line", 0, "diff line number")
	author := set.String("author", "Dieter CLI", "display author")
	commit := set.String("commit", "", "commit SHA")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*path) == "" || strings.TrimSpace(*message) == "" || strings.TrimSpace(*revision) == "" {
		return errors.New("CARD, --path, --revision, and --message are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.AddChangeComment(rpcCtx, &dieterv1.AddChangeCommentRequest{CardId: set.Arg(0), Path: *path, Side: *side, Line: int32(*line), Body: *message, Author: *author, Revision: *revision, CommitSha: *commit})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceSCM(args []string) error {
	const usage = "Usage: dieter workspace scm CARD\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetSCMCapabilities(rpcCtx, &dieterv1.ConversationRef{CardId: args[0]})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceOperation(args []string) error {
	const usage = "Usage: dieter workspace operation OPERATION\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one OPERATION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetGitOperation(rpcCtx, &dieterv1.GitOperationRef{OperationId: args[0]})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcWorkspaceWatch(args []string) error {
	const usage = "Usage: dieter workspace watch [--after SEQUENCE] [--count N] OPERATION\n"
	set := flags("workspace watch")
	after := set.Uint64("after", 0, "last received log sequence")
	count := set.Int("count", 0, "stop after N frames; zero streams until completion")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one OPERATION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	stream, err := client.WatchGitOperation(rpcCtx, &dieterv1.WatchGitOperationRequest{OperationId: set.Arg(0), AfterSequence: *after, HeartbeatMs: 1_000})
	if err != nil {
		return err
	}
	for emitted := 0; ; emitted++ {
		frame, receiveErr := stream.Recv()
		if receiveErr != nil {
			return streamEnd(receiveErr, ctx)
		}
		if err := protoJSONLine(c.Out, frame); err != nil {
			return err
		}
		if *count > 0 && emitted+1 >= *count {
			return nil
		}
		status := frame.GetOperation().GetStatus()
		if status != "queued" && status != "running" {
			return nil
		}
	}
}

func (c *CLI) rpcWorkspaceRun(args []string) error {
	const usage = "Usage: dieter workspace run --kind KIND [--revision REVISION] [--param KEY=VALUE ...] [--wait] CARD\n"
	set := flags("workspace run")
	kind := set.String("kind", "", "operation kind")
	revision := set.String("revision", "", "expected changeset revision")
	wait := set.Bool("wait", false, "stream until the operation reaches a terminal or waiting state")
	parameters := parameterFlags{}
	set.Var(&parameters, "param", "operation parameter; repeatable")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*kind) == "" {
		return errors.New("CARD and --kind are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.StartGitOperation(rpcCtx, &dieterv1.StartGitOperationRequest{CardId: set.Arg(0), Kind: *kind, ExpectedRevision: *revision, Parameters: map[string]string(parameters)})
	if err != nil {
		return err
	}
	if !*wait {
		return protoJSONOut(c.Out, value)
	}
	stream, err := client.WatchGitOperation(rpcCtx, &dieterv1.WatchGitOperationRequest{OperationId: value.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		return err
	}
	for {
		frame, receiveErr := stream.Recv()
		if receiveErr != nil {
			return streamEnd(receiveErr, ctx)
		}
		if err := protoJSONLine(c.Out, frame); err != nil {
			return err
		}
		status := frame.GetOperation().GetStatus()
		if status != "queued" && status != "running" {
			return nil
		}
	}
}

func (c *CLI) rpcWorkspaceCancel(args []string) error {
	const usage = "Usage: dieter workspace cancel OPERATION\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one OPERATION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.CancelGitOperation(rpcCtx, &dieterv1.GitOperationRef{OperationId: args[0]})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}
