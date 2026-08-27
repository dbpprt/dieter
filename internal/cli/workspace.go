package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/changeset"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/gitops"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/workspace"
)

func readValidationCommands(path string) ([]model.ValidationCommand, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var values []model.ValidationCommand
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, fmt.Errorf("decode validation commands: %w", err)
	}
	for _, value := range values {
		if strings.TrimSpace(value.Executable) == "" {
			return nil, errors.New("every validation command requires an executable")
		}
	}
	return values, nil
}

func (c *CLI) workspace(args []string) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprint(c.Out, `Usage: dieter workspace <action>

Actions:
  show CARD                 Provision and show one card/chat workspace
  list [--project PROJECT]  List durable workspaces
  changes CARD              Show the current changeset and revision
  diff --path PATH CARD     Show a revision-checked file or commit diff
  comments CARD             List changeset review comments
  comment [options] CARD    Add a changeset review comment
  scm CARD                  Show daemon-host GitHub/remote capabilities
  operation OPERATION       Show an operation and its durable log
  run --kind KIND CARD      Run a serialized durable Git operation

Kinds include commit, update, continue_conflict, abort_conflict, validate,
merge_local, push, cleanup, discard, adopt, migrate, create_pr, refresh_pr,
and merge_pr. Repeat --param KEY=VALUE for operation-specific parameters.
`)
		return nil
	}
	switch args[0] {
	case "show":
		if len(args) != 2 {
			return errors.New("CARD is required")
		}
		value, err := workspace.New(c.Store, nil).Ensure(context.Background(), args[1])
		if err != nil {
			return err
		}
		return jsonOut(c.Out, value)
	case "list", "ls":
		return c.workspaceList(args[1:])
	case "changes", "status":
		if len(args) != 2 {
			return errors.New("CARD is required")
		}
		value, err := changeset.New(workspace.New(c.Store, nil)).Get(context.Background(), args[1])
		if err != nil {
			return err
		}
		return jsonOut(c.Out, value)
	case "diff":
		return c.workspaceDiff(args[1:])
	case "comments":
		if len(args) != 2 {
			return errors.New("CARD is required")
		}
		values, err := c.Store.ListChangeComments(args[1])
		if err != nil {
			return err
		}
		return jsonOut(c.Out, values)
	case "comment":
		return c.workspaceComment(args[1:])
	case "scm":
		if len(args) != 2 {
			return errors.New("CARD is required")
		}
		manager := workspace.New(c.Store, nil)
		value, err := manager.Ensure(context.Background(), args[1])
		if err != nil {
			return err
		}
		capabilities := gitops.New(c.Store, manager, nil).SCM.Capabilities(context.Background(), value.Path, value.BaseRemote)
		return jsonOut(c.Out, capabilities)
	case "operation", "op":
		if len(args) != 2 {
			return errors.New("OPERATION is required")
		}
		operation, err := c.Store.GitOperation(args[1])
		if err != nil {
			return err
		}
		logs, err := c.Store.GitOperationLog(operation.ID, 0, 500)
		if err != nil {
			return err
		}
		return jsonOut(c.Out, map[string]any{"operation": operation, "logs": logs})
	case "run":
		return c.workspaceRun(args[1:])
	default:
		return fmt.Errorf("unknown workspace action %q", args[0])
	}
}

func (c *CLI) workspaceList(args []string) error {
	const usage = "Usage: dieter workspace list [--project PROJECT] [--refresh] [--size]\n"
	set := flags("workspace list")
	project := set.String("project", "", "project")
	refresh := set.Bool("refresh", false, "refresh Git state")
	size := set.Bool("size", false, "measure workspace disk usage")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	values, err := workspace.New(c.Store, nil).List(context.Background(), *project, *refresh, *size)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, values)
}

func (c *CLI) workspaceDiff(args []string) error {
	const usage = "Usage: dieter workspace diff --path PATH [--revision REVISION] [--commit SHA] [--offset N] CARD\n"
	set := flags("workspace diff")
	path := set.String("path", "", "file path")
	revision := set.String("revision", "", "expected changeset revision")
	commit := set.String("commit", "", "commit SHA")
	offset := set.Int("offset", 0, "diff byte offset")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || *path == "" {
		return errors.New("CARD and --path are required")
	}
	service := changeset.New(workspace.New(c.Store, nil))
	if *revision == "" {
		value, getErr := service.Get(context.Background(), set.Arg(0))
		if getErr != nil {
			return getErr
		}
		*revision = value.Revision
	}
	var value model.FileDiff
	if *commit == "" {
		value, err = service.FileDiff(context.Background(), set.Arg(0), *revision, *path, "", *offset, 0)
	} else {
		value, err = service.CommitDiff(context.Background(), set.Arg(0), *revision, *commit, *path, *offset, 0)
	}
	if err != nil {
		return err
	}
	return jsonOut(c.Out, value)
}

func (c *CLI) workspaceComment(args []string) error {
	const usage = "Usage: dieter workspace comment --path PATH --revision REVISION --message TEXT [--side new|old] [--line N] CARD\n"
	set := flags("workspace comment")
	path := set.String("path", "", "file path")
	revision := set.String("revision", "", "changeset revision")
	message := set.String("message", "", "comment")
	side := set.String("side", "new", "new or old side")
	line := set.Int("line", 0, "line number")
	author := set.String("author", "Dieter agent", "display author")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	value, err := c.Store.AddChangeComment(model.ChangeComment{
		CardID: set.Arg(0), ChangesetRevision: *revision, Path: *path, Side: *side,
		Line: *line, Body: *message, Author: model.Author{Kind: "agent", Name: *author},
	})
	if err != nil {
		return err
	}
	return jsonOut(c.Out, value)
}

type parameterFlags map[string]string

func (values *parameterFlags) String() string {
	parts := make([]string, 0, len(*values))
	for key, value := range *values {
		parts = append(parts, key+"="+value)
	}
	return strings.Join(parts, ",")
}

func (values *parameterFlags) Set(value string) error {
	key, item, found := strings.Cut(value, "=")
	if !found || strings.TrimSpace(key) == "" {
		return errors.New("operation parameters must be KEY=VALUE")
	}
	if *values == nil {
		*values = map[string]string{}
	}
	(*values)[strings.TrimSpace(key)] = item
	return nil
}

func (c *CLI) workspaceRun(args []string) error {
	const usage = "Usage: dieter workspace run --kind KIND [--revision REVISION] [--param KEY=VALUE ...] CARD\n"
	set := flags("workspace run")
	kind := set.String("kind", "", "operation kind")
	revision := set.String("revision", "", "expected changeset revision")
	parameters := parameterFlags{}
	set.Var(&parameters, "param", "operation parameter")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*kind) == "" {
		return errors.New("CARD and --kind are required")
	}
	if submitted, submitErr := c.workspaceRunThroughDaemon(context.Background(), set.Arg(0), *kind, *revision, parameters); submitted {
		return submitErr
	}
	manager := gitops.New(c.Store, workspace.New(c.Store, nil), nil)
	operation, err := manager.Start(context.Background(), gitops.Request{CardID: set.Arg(0), Kind: *kind, ExpectedRevision: *revision, Parameters: parameters})
	if err != nil {
		return err
	}
	deadline := time.NewTimer(24 * time.Hour)
	defer deadline.Stop()
	for {
		value, readErr := manager.Get(operation.ID)
		if readErr != nil {
			return readErr
		}
		switch value.Status {
		case model.GitOperationQueued, model.GitOperationRunning:
		case model.GitOperationWaitingForResolution:
			return jsonOut(c.Out, value)
		case model.GitOperationSucceeded:
			return jsonOut(c.Out, value)
		default:
			_ = jsonOut(c.Out, value)
			return fmt.Errorf("Git operation %s: %s", value.Status, value.Error)
		}
		select {
		case <-deadline.C:
			return errors.New("timed out waiting for Git operation")
		case <-manager.Changed(operation.ID):
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (c *CLI) workspaceRunThroughDaemon(ctx context.Context, cardID, kind, revision string, parameters map[string]string) (bool, error) {
	statusValue, err := dieterdaemon.LoadRuntimeStatus(c.Store.Root)
	if dieterdaemon.IsRuntimeStatusMissing(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read Dieter daemon status: %w", err)
	}
	if !dieterdaemon.RuntimeStatusCurrent(statusValue, time.Now().UTC()) {
		return false, nil
	}
	address := strings.TrimSpace(statusValue.ListenAddress)
	if address == "" {
		return true, errors.New("running Dieter daemon has no local API address")
	}
	operationCtx, cancel := context.WithTimeout(ctx, 24*time.Hour)
	defer cancel()
	client := dieterv1connect.NewDieterServiceClient(http.DefaultClient, "http://"+address)
	started, err := client.StartGitOperation(operationCtx, connect.NewRequest(&dieterv1.StartGitOperationRequest{
		CardId: cardID, Kind: kind, ExpectedRevision: revision, Parameters: parameters,
	}))
	if err != nil {
		return true, fmt.Errorf("start Git operation through running Dieter daemon at %s: %w", address, err)
	}
	watch, err := client.WatchGitOperation(operationCtx, connect.NewRequest(&dieterv1.WatchGitOperationRequest{
		OperationId: started.Msg.GetId(), HeartbeatMs: 1_000,
	}))
	if err != nil {
		return true, fmt.Errorf("watch Git operation through running Dieter daemon: %w", err)
	}
	value := modelGitOperation(started.Msg)
	for watch.Receive() {
		value = modelGitOperation(watch.Msg().GetOperation())
		if value.Status == model.GitOperationWaitingForResolution {
			return true, jsonOut(c.Out, value)
		}
	}
	if err := watch.Err(); err != nil {
		return true, fmt.Errorf("watch Git operation through running Dieter daemon: %w", err)
	}
	if value.Status != model.GitOperationSucceeded {
		_ = jsonOut(c.Out, value)
		return true, fmt.Errorf("Git operation %s: %s", value.Status, value.Error)
	}
	return true, jsonOut(c.Out, value)
}

func modelGitOperation(value *dieterv1.GitOperation) model.GitOperation {
	if value == nil {
		return model.GitOperation{}
	}
	result := model.GitOperation{
		ID: value.GetId(), CardID: value.GetCardId(), ProjectID: value.GetProjectId(), Kind: value.GetKind(), Status: value.GetStatus(),
		ExpectedRevision: value.GetExpectedRevision(), ExpectedBaseSHA: value.GetExpectedBaseSha(), ExpectedHeadSHA: value.GetExpectedHeadSha(),
		Parameters: cloneStringMap(value.GetParameters()), CompletedSteps: append([]string(nil), value.GetCompletedSteps()...),
		Result: value.GetResult(), Error: value.GetError(), Sequence: value.GetSequence(), CreatedAt: value.GetCreatedAt(),
		StartedAt: value.GetStartedAt(), FinishedAt: value.GetFinishedAt(), UpdatedAt: value.GetUpdatedAt(),
	}
	for _, conflict := range value.GetConflicts() {
		result.Conflicts = append(result.Conflicts, model.GitConflict{Path: conflict.GetPath(), HunkCount: int(conflict.GetHunkCount())})
	}
	for _, validation := range value.GetValidationResults() {
		result.ValidationResults = append(result.ValidationResults, model.ValidationResult{
			Name: validation.GetName(), ExitCode: int(validation.GetExitCode()), Output: validation.GetOutput(),
			Truncated: validation.GetTruncated(), DurationMS: validation.GetDurationMs(),
		})
	}
	return result
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}
