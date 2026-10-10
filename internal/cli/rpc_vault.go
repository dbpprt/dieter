package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

const vaultHelp = `Usage: dieter vault <action> [options]

An account-wide password and TOTP vault shared by your machines. Items
replicate end-to-end encrypted; the gateway relays only ciphertext and vault
contents never cross the gateway relay route. Each machine joins once.

Setup and machines:
  status         Show vault state, members and this caller's access
  init           Create the vault on the first machine; prints a recovery key
  join           Join from another machine (approval code or recovery key)
  approve        Approve a joining machine after comparing its code
  remove-member  Revoke a machine and rotate to a new key
  rotate         Rotate the vault key; --recovery-key replaces the recovery key

Items:
  list           List items (no secrets)
  show           Show one item's metadata
  add            Add an item with name, URLs, username, password, TOTP, notes
  edit           Change fields of an item
  remove         Delete an item
  get            Print one field; secret fields require --reveal
  totp           Print the current TOTP code
  exec           Run a command with item fields in its environment
  audit          Show this machine's vault access log

ITEM is an exact vi_ ID or a unique case-insensitive name. Secrets are never
accepted as command-line arguments: use --password-file -, --prompt or
--generate. Agent turns may use the vault only when their card, chat or
schedule was created with --vault; agents cannot change membership or keys.
Prefer exec over get so secrets do not enter transcripts.
`

// vaultValues is a repeatable string flag.
type vaultValues []string

func (values *vaultValues) String() string { return strings.Join(*values, ",") }
func (values *vaultValues) Set(value string) error {
	if value = strings.TrimSpace(value); value == "" {
		return errors.New("value is required")
	}
	*values = append(*values, value)
	return nil
}

// exitStatusError propagates a child process's exit status from vault exec.
type exitStatusError struct{ code int }

func (e *exitStatusError) Error() string { return fmt.Sprintf("command exited with status %d", e.code) }

func (c *CLI) rpcVault(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, vaultHelp)
		return nil
	}
	actions := map[string]func([]string) error{
		"status": c.vaultStatus, "init": c.vaultInit, "join": c.vaultJoin, "members": c.vaultStatus,
		"approve": c.vaultApprove, "remove-member": c.vaultRemoveMember, "rotate": c.vaultRotate,
		"list": c.vaultList, "ls": c.vaultList, "show": c.vaultShow, "add": c.vaultAdd, "edit": c.vaultEdit,
		"remove": c.vaultRemove, "rm": c.vaultRemove, "get": c.vaultGet, "totp": c.vaultTOTP, "exec": c.vaultExec,
		"audit": c.vaultAudit,
	}
	action, ok := actions[args[0]]
	if !ok {
		return fmt.Errorf("unknown vault action %q; run `dieter vault --help`", args[0])
	}
	if !wantsHelp(args[1:]) && os.Getenv("DIETER_TURN_TOKEN") != "" && strings.TrimSpace(c.Machine) != "" {
		return errors.New("agent turns use the vault only through their own machine; omit --machine")
	}
	return action(args[1:])
}

// vaultSecretSource reads one secret from a file or stdin, keeping inner
// whitespace and removing only the final line break.
func (c *CLI) vaultSecretSource(path string) (string, error) {
	var raw []byte
	var err error
	if path == "-" {
		raw, err = io.ReadAll(io.LimitReader(c.In, 64<<10))
	} else {
		raw, err = os.ReadFile(path)
	}
	if err != nil {
		return "", err
	}
	return strings.TrimRight(string(raw), "\r\n"), nil
}

func stdinSources(paths ...string) error {
	count := 0
	for _, path := range paths {
		if path == "-" {
			count++
		}
	}
	if count > 1 {
		return errors.New("only one of --password-file, --totp-file and --notes-file may read stdin")
	}
	return nil
}

func (c *CLI) vaultPrompt(label string) (string, error) {
	file, ok := c.In.(*os.File)
	if !ok || !isTerminal(file) {
		return "", errors.New("--prompt needs an interactive terminal; use --password-file - or --totp-file - instead")
	}
	fmt.Fprint(c.Err, label)
	value, err := readHidden(file)
	fmt.Fprintln(c.Err)
	return strings.TrimRight(value, "\r\n"), err
}

func vaultStatusTable(out io.Writer, value *dieterv1.VaultStatus) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "State:\t%s\n", value.GetState())
	if value.GetVaultId() != "" {
		fmt.Fprintf(writer, "Vault:\t%s (%d items)\n", value.GetVaultId(), value.GetItemCount())
	}
	if caller := value.GetCaller(); caller != nil {
		fmt.Fprintf(writer, "Caller:\t%s via %s, vault access %t\n", caller.GetKind(), caller.GetRoute(), caller.GetVaultAccess())
	}
	if value.GetJoinCode() != "" {
		fmt.Fprintf(writer, "Join code:\t%s\n", value.GetJoinCode())
	}
	if len(value.GetConflictItemIds()) > 0 {
		fmt.Fprintf(writer, "Conflicts:\t%s (edit an item to resolve)\n", strings.Join(value.GetConflictItemIds(), ", "))
	}
	if len(value.GetMembers()) > 0 {
		fmt.Fprintln(writer, "\nMEMBER\tNAME\tSTATE\tCODE")
		for _, member := range value.GetMembers() {
			state := "approved"
			switch {
			case member.GetRecovery():
				state = "recovery key"
			case member.GetPending():
				state = "pending"
			}
			if member.GetSelf() {
				state += " (this machine)"
			}
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", member.GetId(), member.GetName(), state, member.GetJoinCode())
		}
	}
	return writer.Flush()
}

func (c *CLI) vaultStatus(args []string) error {
	const usage = "Usage: dieter vault status [--format table|json]\nShow vault state, machine members, pending join codes and this caller's access.\n"
	set := flags("vault status")
	format := set.String("format", "table", "table or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetVaultStatus(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	return vaultStatusTable(c.Out, value)
}

func (c *CLI) vaultInit(args []string) error {
	const usage = `Usage: dieter vault init [--name NAME] [--format text|json]

Create the account vault with this machine as its first member. The printed
recovery key is shown once and never stored: keep it offline. It unlocks the
vault on any machine with dieter vault join --recovery-key-stdin.
`
	set := flags("vault init")
	name := set.String("name", "", "member name (default host name)")
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
	value, err := client.InitVault(rpcCtx, &dieterv1.InitVaultRequest{Name: *name})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	fmt.Fprintf(c.Out, "Vault %s created.\n\nRecovery key (shown once; store it offline):\n\n  %s\n\nJoin other machines with: dieter vault join\n", value.GetStatus().GetVaultId(), value.GetRecoveryKey())
	return nil
}

func (c *CLI) vaultJoin(args []string) error {
	const usage = `Usage: dieter vault join [--name NAME] [--recovery-key-stdin] [--format text|json]

Without a recovery key, publish this machine's vault key and print a join code.
On an existing member, compare that code and run:
  dieter vault approve MEMBER --code CODE
The code is derived from both machines' views, so a relay that substitutes keys
produces a different code. With --recovery-key-stdin, read the recovery key
from stdin and unlock immediately.
`
	set := flags("vault join")
	name := set.String("name", "", "member name (default host name)")
	recovery := set.Bool("recovery-key-stdin", false, "read the recovery key from stdin")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	request := &dieterv1.JoinVaultRequest{Name: *name}
	if *recovery {
		key, err := c.vaultSecretSource("-")
		if err != nil {
			return err
		}
		if request.RecoveryKey = strings.TrimSpace(key); request.RecoveryKey == "" {
			return errors.New("no recovery key on stdin")
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.JoinVault(rpcCtx, request)
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	if value.GetJoinCode() == "" {
		fmt.Fprintf(c.Out, "This machine joined vault %s.\n", value.GetStatus().GetVaultId())
		return nil
	}
	fmt.Fprintf(c.Out, "Join requested for member %s.\n\nJoin code: %s\n\nOn a machine that is already a member, after peer sync, run:\n  dieter vault approve %s --code %s\n", value.GetStatus().GetMemberId(), value.GetJoinCode(), value.GetStatus().GetMemberId(), value.GetJoinCode())
	return nil
}

func (c *CLI) vaultApprove(args []string) error {
	const usage = "Usage: dieter vault approve MEMBER --code CODE\nApprove a pending machine. Compare CODE with the code its dieter vault join printed;\ndieter vault status lists pending members with the code this machine expects.\n"
	set := flags("vault approve")
	code := set.String("code", "", "join code printed on the joining machine")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*code) == "" {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ApproveVaultMember(rpcCtx, &dieterv1.ApproveVaultMemberRequest{MemberId: set.Arg(0), JoinCode: *code})
	if err != nil {
		return err
	}
	return vaultStatusTable(c.Out, value)
}

func (c *CLI) vaultRemoveMember(args []string) error {
	const usage = "Usage: dieter vault remove-member MEMBER\nRevoke a machine and rotate to a key it never receives. It keeps anything it\nalready decrypted: change those passwords. Unenroll a lost machine too.\n"
	set := flags("vault remove-member")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.RemoveVaultMember(rpcCtx, &dieterv1.VaultMemberRef{MemberId: set.Arg(0)})
	if err != nil {
		return err
	}
	return vaultStatusTable(c.Out, value)
}

func (c *CLI) vaultRotate(args []string) error {
	const usage = "Usage: dieter vault rotate [--recovery-key]\nCreate a new vault key, reseal it to every member and re-encrypt all items.\n--recovery-key also replaces the recovery key and prints the new one once.\n"
	set := flags("vault rotate")
	recovery := set.Bool("recovery-key", false, "replace the recovery key")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.RotateVault(rpcCtx, &dieterv1.RotateVaultRequest{NewRecoveryKey: *recovery})
	if err != nil {
		return err
	}
	fmt.Fprintf(c.Out, "Vault key rotated to %s.\n", value.GetStatus().GetCurrentKeyId())
	if value.GetRecoveryKey() != "" {
		fmt.Fprintf(c.Out, "\nNew recovery key (shown once; the previous one no longer works):\n\n  %s\n", value.GetRecoveryKey())
	}
	return nil
}

func vaultItemsTable(out io.Writer, items []*dieterv1.VaultItem) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tNAME\tUSERNAME\tURL\tSECRETS")
	for _, item := range items {
		var secrets []string
		for name, present := range map[string]bool{"password": item.GetHasPassword(), "totp": item.GetHasTotp(), "notes": item.GetHasNotes()} {
			if present {
				secrets = append(secrets, name)
			}
		}
		sort.Strings(secrets)
		url := ""
		if len(item.GetUrls()) > 0 {
			url = item.GetUrls()[0]
		}
		state := strings.Join(secrets, ",")
		if item.GetConflict() {
			state += " (conflict)"
		}
		if item.GetError() != "" {
			state = "unreadable: " + item.GetError()
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", item.GetId(), item.GetName(), item.GetUsername(), url, state)
	}
	return writer.Flush()
}

func (c *CLI) vaultList(args []string) error {
	const usage = "Usage: dieter vault list [--query TEXT] [--url URL] [--format table|json|jsonl|ids]\nList item metadata. --url matches items for that host and its subdomains.\n"
	set := flags("vault list")
	query := set.String("query", "", "name, username or URL substring")
	url := set.String("url", "", "match items by URL host")
	format := set.String("format", "table", "table, json, jsonl or ids")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ListVaultItems(rpcCtx, &dieterv1.ListVaultItemsRequest{Query: *query, Url: *url})
	if err != nil {
		return err
	}
	switch *format {
	case "json":
		return protoJSONOut(c.Out, value)
	case "jsonl":
		for _, item := range value.GetItems() {
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		}
		return nil
	case "ids":
		for _, item := range value.GetItems() {
			fmt.Fprintln(c.Out, item.GetId())
		}
		return nil
	}
	return vaultItemsTable(c.Out, value.GetItems())
}

func (c *CLI) vaultShow(args []string) error {
	const usage = "Usage: dieter vault show ITEM\nPrint item metadata as JSON. Secret values are never included.\n"
	set := flags("vault show")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetVaultItem(rpcCtx, &dieterv1.VaultItemRef{Item: set.Arg(0)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

const vaultSecretOptions = `  --password-file FILE|-     Read the password from FILE or stdin
  --generate                 Generate the password on the daemon; it is not printed
  --length N                 Generated length (default 24)
  --no-symbols               Generate letters and digits only
  --totp-file FILE|-         Read an otpauth://totp URI or base32 TOTP secret
  --notes-file FILE|-        Read notes
  --prompt                   Prompt for password and TOTP without echo (terminal)
`

type vaultSecretFlags struct {
	passwordFile, totpFile, notesFile *string
	generate, noSymbols, prompt       *bool
	length                            *int
}

func addVaultSecretFlags(set *flag.FlagSet) vaultSecretFlags {
	return vaultSecretFlags{
		passwordFile: set.String("password-file", "", "password file or -"),
		totpFile:     set.String("totp-file", "", "TOTP URI or secret file or -"),
		notesFile:    set.String("notes-file", "", "notes file or -"),
		generate:     set.Bool("generate", false, "generate the password on the daemon"),
		noSymbols:    set.Bool("no-symbols", false, "generate letters and digits only"),
		prompt:       set.Bool("prompt", false, "prompt for password and TOTP without echo"),
		length:       set.Int("length", 0, "generated password length"),
	}
}

type vaultSecretValues struct {
	password, totp, notes *string
	generate, noSymbols   bool
	length                int32
}

func (c *CLI) readVaultSecrets(values vaultSecretFlags) (vaultSecretValues, error) {
	result := vaultSecretValues{generate: *values.generate, noSymbols: *values.noSymbols, length: int32(*values.length)}
	if *values.generate && *values.passwordFile != "" {
		return result, errors.New("use either --generate or --password-file")
	}
	if err := stdinSources(*values.passwordFile, *values.totpFile, *values.notesFile); err != nil {
		return result, err
	}
	read := func(path string) (*string, error) {
		if path == "" {
			return nil, nil
		}
		value, err := c.vaultSecretSource(path)
		return &value, err
	}
	var err error
	if result.password, err = read(*values.passwordFile); err != nil {
		return result, err
	}
	if result.totp, err = read(*values.totpFile); err != nil {
		return result, err
	}
	if result.notes, err = read(*values.notesFile); err != nil {
		return result, err
	}
	if *values.prompt {
		if result.password == nil && !result.generate {
			value, err := c.vaultPrompt("Password (empty to skip): ")
			if err != nil {
				return result, err
			}
			if value != "" {
				result.password = &value
			}
		}
		if result.totp == nil {
			value, err := c.vaultPrompt("TOTP URI or secret (empty to skip): ")
			if err != nil {
				return result, err
			}
			if value != "" {
				result.totp = &value
			}
		}
	}
	return result, nil
}

func (c *CLI) vaultAdd(args []string) error {
	usage := `Usage: dieter vault add --name NAME [--url URL]... [--username USER] [options]

Add an item. Secrets are read from files, stdin or a no-echo prompt.

Options:
  --name NAME                Unique item name
  --url URL                  Login URL; repeat for several
  --username USER            Account user name or email
` + vaultSecretOptions + `  --format json|id           Output format

Example:
  printf '%s' "$PASSWORD" | dieter vault add --name GitHub --url https://github.com/login --username me --password-file -
`
	set := flags("vault add")
	name := set.String("name", "", "item name")
	var urls vaultValues
	set.Var(&urls, "url", "login URL")
	username := set.String("username", "", "user name")
	secrets := addVaultSecretFlags(set)
	format := set.String("format", "json", "json or id")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*name) == "" {
		return errors.New("--name is required")
	}
	values, err := c.readVaultSecrets(secrets)
	if err != nil {
		return err
	}
	request := &dieterv1.CreateVaultItemRequest{Name: *name, Urls: urls, Username: *username, GeneratePassword: values.generate,
		PasswordLength: values.length, PasswordWithoutSymbols: values.noSymbols}
	if values.password != nil {
		request.Password = *values.password
	}
	if values.totp != nil {
		request.Totp = *values.totp
	}
	if values.notes != nil {
		request.Notes = *values.notes
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.CreateVaultItem(rpcCtx, request)
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, value.GetId())
		return nil
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) vaultEdit(args []string) error {
	usage := `Usage: dieter vault edit ITEM [options]

Change item fields. Unspecified fields keep their value. Editing an item with
a conflict keeps the shown version and resolves the conflict.

Options:
  --name NAME                Rename
  --url URL                  Add a URL; repeat for several
  --replace-urls             Replace all URLs with the given --url values
  --username USER            Set the user name
  --clear-totp               Remove the TOTP secret
  --clear-notes              Remove notes
` + vaultSecretOptions
	set := flags("vault edit")
	name := set.String("name", "", "new item name")
	var urls vaultValues
	set.Var(&urls, "url", "URL to add")
	replaceURLs := set.Bool("replace-urls", false, "replace URLs")
	username := set.String("username", "", "user name")
	clearTOTP := set.Bool("clear-totp", false, "remove TOTP")
	clearNotes := set.Bool("clear-notes", false, "remove notes")
	secrets := addVaultSecretFlags(set)
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	values, err := c.readVaultSecrets(secrets)
	if err != nil {
		return err
	}
	request := &dieterv1.UpdateVaultItemRequest{Item: set.Arg(0), Urls: urls, ReplaceUrls: *replaceURLs, GeneratePassword: values.generate,
		PasswordLength: values.length, PasswordWithoutSymbols: values.noSymbols, Password: values.password, Totp: values.totp, Notes: values.notes}
	explicit := map[string]bool{}
	set.Visit(func(item *flag.Flag) { explicit[item.Name] = true })
	if explicit["name"] {
		request.Name = name
	}
	if explicit["username"] {
		request.Username = username
	}
	empty := ""
	if *clearTOTP {
		if request.Totp != nil {
			return errors.New("use either --clear-totp or --totp-file")
		}
		request.Totp = &empty
	}
	if *clearNotes {
		if request.Notes != nil {
			return errors.New("use either --clear-notes or --notes-file")
		}
		request.Notes = &empty
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.UpdateVaultItem(rpcCtx, request)
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) vaultRemove(args []string) error {
	const usage = "Usage: dieter vault remove ITEM\nDelete an item on every member machine.\n"
	set := flags("vault remove")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.DeleteVaultItem(rpcCtx, &dieterv1.VaultItemRef{Item: set.Arg(0)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

var vaultSecretFields = map[string]bool{"password": true, "totp": true, "notes": true}

func (c *CLI) vaultGet(args []string) error {
	const usage = `Usage: dieter vault get ITEM [--field FIELD]... [--reveal] [--format value|json]

Print item fields: password (default), username, url, name, totp or notes.
password, totp and notes require --reveal. One field prints its raw value;
several print JSON. Prefer dieter vault exec so secrets stay out of output.
`
	set := flags("vault get")
	var fields vaultValues
	set.Var(&fields, "field", "field to print; repeatable")
	reveal := set.Bool("reveal", false, "print secret fields")
	format := set.String("format", "value", "value or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if len(fields) == 0 {
		fields = vaultValues{"password"}
	}
	for _, field := range fields {
		if vaultSecretFields[field] && !*reveal {
			return fmt.Errorf("printing %s requires --reveal; prefer `dieter vault exec %s --env NAME=%s -- COMMAND`", field, set.Arg(0), field)
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.RevealVaultItem(rpcCtx, &dieterv1.RevealVaultItemRequest{Item: set.Arg(0), Fields: fields, Purpose: "get"})
	if err != nil {
		return err
	}
	if len(fields) == 1 && *format == "value" {
		fmt.Fprintln(c.Out, value.GetValues()[fields[0]])
		return nil
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) vaultTOTP(args []string) error {
	const usage = "Usage: dieter vault totp ITEM [--no-wait] [--format value|json]\nPrint the current TOTP code. With fewer than 5 seconds left, wait for the next\ncode unless --no-wait is set.\n"
	set := flags("vault totp")
	noWait := set.Bool("no-wait", false, "return the current code even when it is about to expire")
	format := set.String("format", "value", "value or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	request := &dieterv1.RevealVaultItemRequest{Item: set.Arg(0), Fields: []string{"totp"}, Purpose: "totp"}
	value, err := client.RevealVaultItem(rpcCtx, request)
	if err != nil {
		return err
	}
	if remaining := value.GetTotpRemainingSeconds(); !*noWait && remaining < 5 {
		select {
		case <-time.After(time.Duration(remaining)*time.Second + 250*time.Millisecond):
		case <-ctx.Done():
			return ctx.Err()
		}
		if value, err = client.RevealVaultItem(rpcCtx, request); err != nil {
			return err
		}
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	fmt.Fprintln(c.Out, value.GetValues()["totp"])
	return nil
}

func (c *CLI) vaultExec(args []string) error {
	const usage = `Usage: dieter vault exec ITEM --env NAME=FIELD... -- COMMAND [ARG...]

Run COMMAND locally with item fields in its environment. FIELD is password,
username, url, name, totp or notes. Arguments run without a shell; wrap in
sh -c only when needed. stdin, stdout and stderr pass through and the exit
status is preserved. Secrets are not printed.

Example:
  dieter vault exec GitHub --env GH_USER=username --env GH_PASS=password -- ./login.sh
`
	split := len(args)
	for index, argument := range args {
		if argument == "--" {
			split = index
			break
		}
	}
	set := flags("vault exec")
	var envs vaultValues
	set.Var(&envs, "env", "NAME=FIELD; repeatable")
	if help, err := parse(set, args[:split], usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 || split >= len(args)-1 || len(envs) == 0 {
		return errors.New(usage)
	}
	command := args[split+1:]
	names := map[string]string{}
	var fields []string
	for _, assignment := range envs {
		name, field, ok := strings.Cut(assignment, "=")
		if !ok || !validEnvironmentName(name) || field == "" {
			return fmt.Errorf("invalid --env %q; use NAME=FIELD", assignment)
		}
		names[name] = field
		known := false
		for _, existing := range fields {
			known = known || existing == field
		}
		if !known {
			fields = append(fields, field)
		}
	}
	ctx, cancel := c.commandContext()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		cancel()
		return err
	}
	value, err := client.RevealVaultItem(rpcCtx, &dieterv1.RevealVaultItemRequest{Item: set.Arg(0), Fields: fields, Purpose: "exec"})
	cancel()
	if err != nil {
		return err
	}
	child := exec.Command(command[0], command[1:]...)
	child.Stdin, child.Stdout, child.Stderr = c.In, c.Out, c.Err
	child.Env = os.Environ()
	for name, field := range names {
		child.Env = append(child.Env, name+"="+value.GetValues()[field])
	}
	if err = child.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code := exitErr.ExitCode()
			if code <= 0 || code > 255 {
				code = 255
			}
			return &exitStatusError{code: code}
		}
		return err
	}
	return nil
}

func validEnvironmentName(name string) bool {
	if name == "" {
		return false
	}
	for index, char := range name {
		if !(char == '_' || char >= 'A' && char <= 'Z' || char >= 'a' && char <= 'z' || index > 0 && char >= '0' && char <= '9') {
			return false
		}
	}
	return true
}

func (c *CLI) vaultAudit(args []string) error {
	const usage = "Usage: dieter vault audit [--item ITEM] [--card CARD] [--limit N] [--format table|jsonl]\nShow this machine's vault access log, newest first. It never contains secret values.\n"
	set := flags("vault audit")
	item := set.String("item", "", "item ID or name")
	card := set.String("card", "", "agent card ID")
	limit := set.Int("limit", 50, "maximum entries (up to 1000)")
	format := set.String("format", "table", "table or jsonl")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ListVaultAudit(rpcCtx, &dieterv1.ListVaultAuditRequest{Item: *item, CardId: *card, Limit: int32(*limit)})
	if err != nil {
		return err
	}
	if *format == "jsonl" {
		for _, entry := range value.GetEntries() {
			if err := protoJSONLine(c.Out, entry); err != nil {
				return err
			}
		}
		return nil
	}
	writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "TIME\tACTION\tOUTCOME\tCALLER\tROUTE\tITEM\tFIELDS\tDETAIL")
	for _, entry := range value.GetEntries() {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", entry.GetTime(), entry.GetAction(), entry.GetOutcome(), entry.GetCaller(), entry.GetRoute(), entry.GetItemName(), entry.GetFields(), entry.GetDetail())
	}
	return writer.Flush()
}
