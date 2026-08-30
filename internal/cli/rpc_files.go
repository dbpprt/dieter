package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const fileHelp = `Usage: dieter file <action>

Every action accepts either --project PROJECT or --card CARD. A card scope uses
that conversation's selected project directory or isolated worktree.

Actions:
  list [PATH]                 List a directory
  read PATH                   Read text or binary file content
  save PATH                   Revision-checked update of an existing text file
  create PATH                 Create a file or directory
  move SOURCE DESTINATION     Move or rename a file or directory
  delete PATH                 Delete a file; directories require --recursive
`

func (c *CLI) rpcFile(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, fileHelp)
		return nil
	}
	switch args[0] {
	case "list", "ls":
		return c.rpcFileList(args[1:])
	case "read", "show":
		return c.rpcFileRead(args[1:])
	case "save", "write":
		return c.rpcFileSave(args[1:])
	case "create", "new":
		return c.rpcFileCreate(args[1:])
	case "move", "rename":
		return c.rpcFileMove(args[1:])
	case "delete", "remove", "rm":
		return c.rpcFileDelete(args[1:])
	default:
		return fmt.Errorf("unknown file action %q; run `dieter file --help`", args[0])
	}
}

func fileTextValue(inline, path string, in io.Reader) (string, error) {
	if inline != "" && path != "" {
		return "", errors.New("use either --content or --file, not both")
	}
	if path == "" {
		return inline, nil
	}
	var raw []byte
	var err error
	if path == "-" {
		raw, err = io.ReadAll(io.LimitReader(in, (10<<20)+1))
	} else {
		raw, err = os.ReadFile(path)
	}
	if err == nil && len(raw) > 10<<20 {
		return "", errors.New("file content exceeds 10 MiB")
	}
	return string(raw), err
}

func addFileScopeFlags(set *flag.FlagSet) (*string, *string) {
	return set.String("project", "", "project ID or unique name"), set.String("card", "", "card/chat ID; operates in its selected workspace")
}

func (c *CLI) resolveFileScope(ctx context.Context, client dieterv1.DieterServiceClient, rpcCtx context.Context, projectRef, cardID string) (string, string, error) {
	projectRef, cardID = strings.TrimSpace(projectRef), strings.TrimSpace(cardID)
	if (projectRef == "") == (cardID == "") {
		return "", "", errors.New("exactly one of --project or --card is required")
	}
	if cardID != "" {
		return "", cardID, nil
	}
	state, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
	if err != nil {
		return "", "", err
	}
	project, err := resolveProtoProject(state, projectRef)
	if err != nil {
		return "", "", err
	}
	return project.GetId(), "", nil
}

func (c *CLI) rpcFileList(args []string) error {
	const usage = "Usage: dieter file list (--project PROJECT|--card CARD) [--hidden] [--format table|json|jsonl] [PATH]\n"
	set := flags("file list")
	project, card := addFileScopeFlags(set)
	hidden := set.Bool("hidden", false, "include dotfiles")
	format := set.String("format", "table", "table, json, or jsonl")
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
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	value, err := client.ListFiles(rpcCtx, &dieterv1.ListFilesRequest{ProjectId: projectID, CardId: cardID, Path: path, ShowHidden: *hidden})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	for _, item := range value.GetEntries() {
		if *format == "jsonl" {
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
			continue
		}
		fmt.Fprintf(writer, "%s\t%d\t%s\t%s\n", item.GetKind(), item.GetSize(), item.GetModifiedAt(), item.GetPath())
	}
	return writer.Flush()
}

func (c *CLI) rpcFileRead(args []string) error {
	const usage = "Usage: dieter file read (--project PROJECT|--card CARD) [--output FILE|-] [--format content|json] PATH\n"
	set := flags("file read")
	project, card := addFileScopeFlags(set)
	output := set.String("output", "-", "write content to FILE or stdout (-)")
	format := set.String("format", "content", "content or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PATH is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	value, err := client.ReadFile(rpcCtx, &dieterv1.ReadFileRequest{ProjectId: projectID, CardId: cardID, Path: set.Arg(0)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	data := value.GetData()
	if !value.GetBinary() {
		data = []byte(value.GetContent())
	}
	if *output == "-" {
		_, err = c.Out.Write(data)
		return err
	}
	return os.WriteFile(*output, data, 0o600)
}

func (c *CLI) rpcFileSave(args []string) error {
	const usage = "Usage: dieter file save (--project PROJECT|--card CARD) (--content TEXT|--file FILE|--file -) [--revision REVISION|--revision auto] PATH\n"
	set := flags("file save")
	project, card := addFileScopeFlags(set)
	content := set.String("content", "", "replacement text content")
	file := set.String("file", "", "read replacement text from FILE or stdin (-)")
	revision := set.String("revision", "auto", "expected file revision; auto reads the current revision")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PATH is required")
	}
	value, err := fileTextValue(*content, *file, c.In)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	if *revision == "auto" {
		current, readErr := client.ReadFile(rpcCtx, &dieterv1.ReadFileRequest{ProjectId: projectID, CardId: cardID, Path: set.Arg(0)})
		if readErr != nil {
			return readErr
		}
		*revision = current.GetRevision()
	}
	updated, err := client.SaveFile(rpcCtx, &dieterv1.SaveFileRequest{ProjectId: projectID, CardId: cardID, Path: set.Arg(0), Content: value, Revision: *revision})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

func (c *CLI) rpcFileCreate(args []string) error {
	const usage = "Usage: dieter file create (--project PROJECT|--card CARD) [--kind file|directory] [--content TEXT|--file FILE] PATH\n"
	set := flags("file create")
	project, card := addFileScopeFlags(set)
	kind := set.String("kind", "file", "file or directory")
	content := set.String("content", "", "initial text content")
	file := set.String("file", "", "read initial text from FILE or stdin (-)")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PATH is required")
	}
	value, err := fileTextValue(*content, *file, c.In)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	created, err := client.CreateFile(rpcCtx, &dieterv1.CreateFileRequest{ProjectId: projectID, CardId: cardID, Path: set.Arg(0), Kind: *kind, Content: value})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, created)
}

func (c *CLI) rpcFileMove(args []string) error {
	const usage = "Usage: dieter file move (--project PROJECT|--card CARD) SOURCE DESTINATION\n"
	set := flags("file move")
	project, card := addFileScopeFlags(set)
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 2 {
		return errors.New("SOURCE and DESTINATION are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	value, err := client.MoveFile(rpcCtx, &dieterv1.MoveFileRequest{ProjectId: projectID, CardId: cardID, Source: set.Arg(0), Destination: set.Arg(1)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcFileDelete(args []string) error {
	const usage = "Usage: dieter file delete (--project PROJECT|--card CARD) [--recursive] PATH\n"
	set := flags("file delete")
	project, card := addFileScopeFlags(set)
	recursive := set.Bool("recursive", false, "delete a directory tree")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PATH is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	_, err = client.DeleteFile(rpcCtx, &dieterv1.DeleteFileRequest{ProjectId: projectID, CardId: cardID, Path: set.Arg(0), Recursive: *recursive})
	return err
}
