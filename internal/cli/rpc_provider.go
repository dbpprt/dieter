package cli

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const providerHelp = `Usage: dieter provider <action> [options]

The Claude and ChatGPT accounts agent turns run on. Accounts, each machine's
sign-in state and plan usage replicate between your machines; credentials
never leave the machine that signed in. Claude Code and Codex keep their own
logins, so Dieter never reads Claude credentials.

Accounts (any machine):
  list     List accounts, their sign-in state and tightest usage window
  add      Add a Claude or ChatGPT account; then sign in with login
  rename   Rename an account
  include  Count an account in usage summaries
  exclude  Leave an account out of usage summaries
  default  Make an account its provider's default for new conversations
  remove   Remove an account; every machine signs it out and deletes its files

On the target machine (this one, or global --machine ID|NAME):
  login    Sign an account in with the provider's own sign-in
  logout   Sign an account out
  check    Verify an account's sign-in now
  usage    Show plan usage and Dieter's token use; --refresh reads it now
  reset    Spend one ChatGPT rate-limit reset credit

ACCOUNT is an account ID (pa_...) or a unique case-insensitive label. Pass
--account ID|LABEL to card, chat and schedule commands to pick the account a
conversation runs on. Agent turns may list accounts and read usage; they
cannot add, change, sign in or remove accounts.
`

func (c *CLI) rpcProvider(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, providerHelp)
		return nil
	}
	actions := map[string]func([]string) error{
		"list": c.providerList, "ls": c.providerList, "add": c.providerAdd, "rename": c.providerRename,
		"include": func(args []string) error { return c.providerInclusion(args, true) },
		"exclude": func(args []string) error { return c.providerInclusion(args, false) },
		"default": c.providerDefault, "remove": c.providerRemove, "rm": c.providerRemove,
		"login": c.providerLogin, "logout": c.providerLogout, "check": c.providerCheck,
		"usage": c.providerUsage, "reset": c.providerReset, "token": c.providerToken,
	}
	action, ok := actions[args[0]]
	if !ok {
		return fmt.Errorf("unknown provider action %q; run `dieter provider --help`", args[0])
	}
	return action(args[1:])
}

// providerMutation refuses agent turns before contacting any daemon: a turn
// token reaches only the local daemon, so --machine would otherwise hide it.
func (c *CLI) providerMutation() error {
	if c.env.TurnToken != "" {
		return errors.New("agents cannot manage provider accounts; ask the operator")
	}
	return nil
}

func providerKind(value string) (dieterv1.ProviderKind, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "claude":
		return dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE, nil
	case "chatgpt":
		return dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT, nil
	}
	return dieterv1.ProviderKind_PROVIDER_KIND_UNSPECIFIED, fmt.Errorf("unknown provider %q; use claude or chatgpt", value)
}

func providerKindName(kind dieterv1.ProviderKind) string {
	switch kind {
	case dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE:
		return "claude"
	case dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT:
		return "chatgpt"
	}
	return "unknown"
}

func providerKindTitle(kind dieterv1.ProviderKind) string {
	switch kind {
	case dieterv1.ProviderKind_PROVIDER_KIND_CLAUDE:
		return "Claude"
	case dieterv1.ProviderKind_PROVIDER_KIND_CHATGPT:
		return "ChatGPT"
	}
	return "provider"
}

var providerMethodNames = map[dieterv1.ProviderLoginMethod]string{
	dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE: "claude-code",
	dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX:       "codex",
	dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_SIWC:        "siwc",
	dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_HOST:        "host",
	dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_ENVIRONMENT: "environment",
}

func providerMethodName(method dieterv1.ProviderLoginMethod) string {
	if name, ok := providerMethodNames[method]; ok {
		return name
	}
	return "-"
}

// providerLoginTool names the program that runs a sign-in, as the apps do.
func providerLoginTool(account *dieterv1.ProviderAccount) string {
	switch account.GetMethod() {
	case dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE:
		return "Claude Code"
	case dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX:
		return "Codex"
	case dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_SIWC:
		return "ChatGPT"
	}
	return providerKindTitle(account.GetProvider())
}

func providerStateName(state dieterv1.ProviderLoginState) string {
	switch state {
	case dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN:
		return "signed in"
	case dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_OUT:
		return "signed out"
	case dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_EXPIRED:
		return "expired"
	case dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_FAILED:
		return "failed"
	}
	return "unknown"
}

// matchProviderAccount resolves ACCOUNT: an exact ID wins, otherwise the one
// account whose label matches case-insensitively.
func matchProviderAccount(accounts []*dieterv1.ProviderAccount, reference string) (*dieterv1.ProviderAccount, error) {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return nil, errors.New("ACCOUNT is required")
	}
	var matches []*dieterv1.ProviderAccount
	for _, account := range accounts {
		if account.GetId() == reference {
			return account, nil
		}
		if strings.EqualFold(account.GetLabel(), reference) {
			matches = append(matches, account)
		}
	}
	switch len(matches) {
	case 0:
		return nil, fmt.Errorf("provider account %q was not found; run `dieter provider list`", reference)
	case 1:
		return matches[0], nil
	}
	ids := make([]string, 0, len(matches))
	for _, account := range matches {
		ids = append(ids, account.GetId())
	}
	return nil, fmt.Errorf("provider account label %q is ambiguous (%s); use the account ID", reference, strings.Join(ids, ", "))
}

func resolveProviderAccount(ctx context.Context, client dieterclient.Client, reference string) (*dieterv1.ProviderAccount, error) {
	response, err := client.ListProviderAccounts(ctx, &dieterv1.ListProviderAccountsRequest{})
	if err != nil {
		return nil, err
	}
	return matchProviderAccount(response.GetAccounts(), reference)
}

// providerAccountID resolves an --account value on the target daemon. Empty
// means the provider default and is passed through.
func providerAccountID(ctx context.Context, client dieterclient.Client, reference string) (string, error) {
	if strings.TrimSpace(reference) == "" {
		return "", nil
	}
	account, err := resolveProviderAccount(ctx, client, reference)
	if err != nil {
		return "", err
	}
	return account.GetId(), nil
}

// targetMachine names the daemon a machine-scoped command acts on.
func (c *CLI) targetMachine() string {
	if machine := strings.TrimSpace(c.Machine); machine != "" {
		return machine
	}
	return "this machine"
}

// targetDaemonID is the daemon ID of the target machine, or "" when it is
// unknown (an unenrolled local daemon).
func (c *CLI) targetDaemonID() string {
	if c.transport != nil && c.transport.daemonID != "" {
		return c.transport.daemonID
	}
	if strings.TrimSpace(c.Machine) != "" {
		return ""
	}
	identity, err := link.LoadIdentity(c.Root)
	if err != nil {
		return ""
	}
	return identity.ID
}

func providerTargetLogin(account *dieterv1.ProviderAccount, daemonID string) *dieterv1.ProviderMachineLogin {
	if daemonID == "" {
		return nil
	}
	for _, login := range account.GetLogins() {
		if login.GetDaemonId() == daemonID {
			return login
		}
	}
	return nil
}

func providerIdentityText(identity *dieterv1.ProviderIdentity) string {
	name := identity.GetEmail()
	if name == "" {
		name = identity.GetSubject()
	}
	if organization := identity.GetOrganization(); organization != "" {
		if name == "" {
			return organization
		}
		return name + " (" + organization + ")"
	}
	return name
}

func orDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}

func providerUsageLeft(window *dieterv1.ProviderUsageWindow) int {
	return int(math.Floor(math.Max(0, math.Min(100, 100-window.GetUsedPercent()))))
}

// providerUsageSummary is the tightest window's remaining share, or why no
// usage is known.
func providerUsageSummary(usage *dieterv1.ProviderUsage) string {
	var tightest *dieterv1.ProviderUsageWindow
	for _, window := range usage.GetWindows() {
		if tightest == nil || window.GetUsedPercent() > tightest.GetUsedPercent() {
			tightest = window
		}
	}
	if tightest != nil {
		return fmt.Sprintf("%d%% left", providerUsageLeft(tightest))
	}
	return orDash(strings.ReplaceAll(usage.GetUnavailable(), "_", " "))
}

func providerMachinesSummary(logins []*dieterv1.ProviderMachineLogin) string {
	if len(logins) == 0 {
		return "not signed in"
	}
	signedIn := 0
	for _, login := range logins {
		if login.GetState() == dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
			signedIn++
		}
	}
	return fmt.Sprintf("%d/%d signed in", signedIn, len(logins))
}

func providerAccountsTable(out io.Writer, accounts []*dieterv1.ProviderAccount) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tPROVIDER\tLABEL\tMETHOD\tDEFAULT\tIDENTITY\tUSAGE\tMACHINES")
	for _, account := range accounts {
		isDefault := ""
		if account.GetIsDefault() {
			isDefault = "yes"
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", account.GetId(), providerKindName(account.GetProvider()), account.GetLabel(),
			providerMethodName(account.GetMethod()), isDefault, orDash(providerIdentityText(account.GetIdentity())),
			providerUsageSummary(account.GetUsage()), providerMachinesSummary(account.GetLogins()))
	}
	return writer.Flush()
}

func providerLoginsTable(out io.Writer, account *dieterv1.ProviderAccount) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "MACHINE\tSTATE\tMETHOD\tIDENTITY\tVERIFIED\tERROR")
	for _, login := range account.GetLogins() {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\n", login.GetDaemonId(), providerStateName(login.GetState()), providerMethodName(login.GetMethod()),
			orDash(providerIdentityText(login.GetIdentity())), orDash(login.GetVerifiedAt()), orDash(login.GetErrorMessage()))
	}
	return writer.Flush()
}

func checkFormat(value string, allowed ...string) error {
	for _, candidate := range allowed {
		if value == candidate {
			return nil
		}
	}
	return fmt.Errorf("--format must be %s", strings.Join(allowed, ", "))
}

func (c *CLI) providerList(args []string) error {
	const usage = `Usage: dieter provider list [--provider claude|chatgpt] [--format table|json|jsonl|ids]

List provider accounts. IDENTITY is the provider login the account is bound
to by its first sign-in, USAGE the tightest plan window's remaining share and
MACHINES how many machines reporting the account are signed in to it.
`
	set := flags("provider list")
	provider := set.String("provider", "", "claude or chatgpt")
	format := set.String("format", "table", "table, json, jsonl or ids")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New(usage)
	}
	if err := checkFormat(*format, "table", "json", "jsonl", "ids"); err != nil {
		return err
	}
	request := &dieterv1.ListProviderAccountsRequest{}
	if *provider != "" {
		kind, err := providerKind(*provider)
		if err != nil {
			return err
		}
		request.Provider = kind
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	response, err := client.ListProviderAccounts(rpcCtx, request)
	if err != nil {
		return err
	}
	switch *format {
	case "json":
		return protoJSONOut(c.Out, response)
	case "jsonl":
		for _, account := range response.GetAccounts() {
			if err := protoJSONLine(c.Out, account); err != nil {
				return err
			}
		}
		return nil
	case "ids":
		for _, account := range response.GetAccounts() {
			fmt.Fprintln(c.Out, account.GetId())
		}
		return nil
	}
	return providerAccountsTable(c.Out, response.GetAccounts())
}

func (c *CLI) providerAdd(args []string) error {
	const usage = `Usage: dieter provider add claude|chatgpt --label LABEL [--method claude-code|codex|siwc] [--format text|json|id]

Add an account. Its first verified sign-in binds it to that provider login
for good. Claude accounts sign in with Claude Code (claude-code); ChatGPT
accounts with Codex (codex, the default) or Sign in with ChatGPT (siwc).
Then sign in on every machine that should run turns on it:
  dieter [--machine ID|NAME] provider login ACCOUNT
`
	set := flags("provider add")
	label := set.String("label", "", "account label, at most 60 characters")
	method := set.String("method", "", "claude-code, codex or siwc")
	format := set.String("format", "text", "text, json or id")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*label) == "" {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	if err := checkFormat(*format, "text", "json", "id"); err != nil {
		return err
	}
	kind, err := providerKind(set.Arg(0))
	if err != nil {
		return err
	}
	request := &dieterv1.CreateProviderAccountRequest{Provider: kind, Label: strings.TrimSpace(*label)}
	switch strings.TrimSpace(*method) {
	case "":
	case "claude-code":
		request.Method = dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CLAUDE_CODE
	case "codex":
		request.Method = dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_CODEX
	case "siwc":
		request.Method = dieterv1.ProviderLoginMethod_PROVIDER_LOGIN_METHOD_SIWC
	default:
		return errors.New("--method must be claude-code, codex or siwc")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	account, err := client.CreateProviderAccount(rpcCtx, request)
	if err != nil {
		return err
	}
	switch *format {
	case "json":
		return protoJSONOut(c.Out, account)
	case "id":
		fmt.Fprintln(c.Out, account.GetId())
		return nil
	}
	fmt.Fprintf(c.Out, "Added %s account %q (%s).\nSign it in on a machine with: dieter [--machine ID|NAME] provider login %s\n",
		providerKindTitle(account.GetProvider()), account.GetLabel(), account.GetId(), account.GetId())
	return nil
}

// providerChange applies one edit to a resolved account and returns the
// updated account with a one-line confirmation.
type providerChange func(context.Context, dieterclient.Client, *dieterv1.ProviderAccount) (*dieterv1.ProviderAccount, string, error)

// providerAccountChange resolves ACCOUNT, runs change and prints its result.
func (c *CLI) providerAccountChange(reference, format string, change providerChange) error {
	if err := checkFormat(format, "text", "json"); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	account, err := resolveProviderAccount(rpcCtx, client, reference)
	if err != nil {
		return err
	}
	updated, message, err := change(rpcCtx, client, account)
	if err != nil {
		return err
	}
	if format == "json" {
		return protoJSONOut(c.Out, updated)
	}
	fmt.Fprintln(c.Out, message)
	return nil
}

func (c *CLI) providerRename(args []string) error {
	const usage = "Usage: dieter provider rename ACCOUNT LABEL [--format text|json]\nRename an account on every machine. Labels are one line of at most 60 characters.\n"
	set := flags("provider rename")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 2 || strings.TrimSpace(set.Arg(1)) == "" {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	label := strings.TrimSpace(set.Arg(1))
	return c.providerAccountChange(set.Arg(0), *format, func(ctx context.Context, client dieterclient.Client, account *dieterv1.ProviderAccount) (*dieterv1.ProviderAccount, string, error) {
		updated, err := client.UpdateProviderAccount(ctx, &dieterv1.UpdateProviderAccountRequest{AccountId: account.GetId(), Label: &label})
		return updated, fmt.Sprintf("Renamed %s to %q.", account.GetId(), updated.GetLabel()), err
	})
}

func (c *CLI) providerInclusion(args []string, included bool) error {
	action, effect := "exclude", "Leave ACCOUNT out of"
	if included {
		action, effect = "include", "Count ACCOUNT in"
	}
	usage := fmt.Sprintf("Usage: dieter provider %s ACCOUNT [--format text|json]\n%s the provider usage summaries the apps show.\n", action, effect)
	set := flags("provider " + action)
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	return c.providerAccountChange(set.Arg(0), *format, func(ctx context.Context, client dieterclient.Client, account *dieterv1.ProviderAccount) (*dieterv1.ProviderAccount, string, error) {
		updated, err := client.UpdateProviderAccount(ctx, &dieterv1.UpdateProviderAccountRequest{AccountId: account.GetId(), IncludeInSummary: &included})
		message := fmt.Sprintf("%q now counts in usage summaries.", account.GetLabel())
		if !included {
			message = fmt.Sprintf("%q no longer counts in usage summaries.", account.GetLabel())
		}
		return updated, message, err
	})
}

func (c *CLI) providerDefault(args []string) error {
	const usage = "Usage: dieter provider default ACCOUNT [--format text|json]\nMake ACCOUNT its provider's default: conversations started without --account use it.\n"
	set := flags("provider default")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	return c.providerAccountChange(set.Arg(0), *format, func(ctx context.Context, client dieterclient.Client, account *dieterv1.ProviderAccount) (*dieterv1.ProviderAccount, string, error) {
		updated, err := client.SetDefaultProviderAccount(ctx, &dieterv1.SetDefaultProviderAccountRequest{AccountId: account.GetId()})
		return updated, fmt.Sprintf("%q is now the default %s account.", account.GetLabel(), providerKindTitle(account.GetProvider())), err
	})
}

func (c *CLI) providerRemove(args []string) error {
	const usage = "Usage: dieter provider remove ACCOUNT --confirm REMOVE\nRemove an account. Every machine signs it out and deletes its local files.\n"
	set := flags("provider remove")
	confirm := set.String("confirm", "", "required exact confirmation phrase REMOVE")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	if *confirm != "REMOVE" {
		return errors.New("removing an account signs it out on every machine; pass --confirm REMOVE")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	account, err := resolveProviderAccount(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	if _, err := client.DeleteProviderAccount(rpcCtx, &dieterv1.DeleteProviderAccountRequest{AccountId: account.GetId()}); err != nil {
		return err
	}
	fmt.Fprintf(c.Out, "Removed %q (%s). Every machine signs it out and deletes its files.\n", account.GetLabel(), account.GetId())
	return nil
}

func (c *CLI) providerLogout(args []string) error {
	const usage = "Usage: dieter provider logout ACCOUNT [--format text|json]\nSign ACCOUNT out on the target machine (this one, or global --machine ID|NAME).\nOther machines stay signed in.\n"
	set := flags("provider logout")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	return c.providerAccountChange(set.Arg(0), *format, func(ctx context.Context, client dieterclient.Client, account *dieterv1.ProviderAccount) (*dieterv1.ProviderAccount, string, error) {
		updated, err := client.SignOutProviderAccount(ctx, &dieterv1.SignOutProviderAccountRequest{AccountId: account.GetId()})
		return updated, fmt.Sprintf("Signed %q out on %s.", account.GetLabel(), c.targetMachine()), err
	})
}

func (c *CLI) providerCheck(args []string) error {
	const usage = `Usage: dieter provider check ACCOUNT [--format text|json]

Verify ACCOUNT's sign-in on the target machine (this one, or global --machine
ID|NAME) now, with the provider's own status check, and print the result.
Exits non-zero unless the account is signed in there.
`
	set := flags("provider check")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := checkFormat(*format, "text", "json"); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	account, err := resolveProviderAccount(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	checked, err := client.CheckProviderLogin(rpcCtx, &dieterv1.CheckProviderLoginRequest{AccountId: account.GetId()})
	if err != nil {
		return err
	}
	daemonID := c.targetDaemonID()
	login := providerTargetLogin(checked, daemonID)
	if *format == "json" {
		if err := protoJSONOut(c.Out, checked); err != nil {
			return err
		}
	}
	if daemonID == "" {
		// Without the target's daemon ID, show every machine's state.
		if *format == "json" {
			return nil
		}
		return providerLoginsTable(c.Out, checked)
	}
	if login.GetState() != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
		state := "not signed in"
		if login != nil {
			state = providerStateName(login.GetState())
		}
		detail := ""
		if message := login.GetErrorMessage(); message != "" {
			detail = ": " + message
		}
		return fmt.Errorf("%q is %s on %s%s", checked.GetLabel(), state, c.targetMachine(), detail)
	}
	if *format == "text" {
		identity := ""
		if text := providerIdentityText(login.GetIdentity()); text != "" {
			identity = " as " + text
		}
		verified := ""
		if login.GetVerifiedAt() != "" {
			verified = " (verified " + login.GetVerifiedAt() + ")"
		}
		fmt.Fprintf(c.Out, "%q is signed in on %s%s%s.\n", checked.GetLabel(), c.targetMachine(), identity, verified)
	}
	return nil
}

var providerWindowLabels = map[string]string{"five_hour": "5-hour", "weekly": "Weekly", "model": "Model", "other": "Other"}

func providerTokenText(totals *dieterv1.ProviderTokenTotals) string {
	if totals == nil {
		return "-"
	}
	return fmt.Sprintf("%d (in %d, out %d)", totals.GetTotalTokens(), totals.GetInputTokens(), totals.GetOutputTokens())
}

func providerUsageExtras(usage *dieterv1.ProviderUsage) string {
	var extras []string
	switch {
	case usage.GetCreditsUnlimited():
		extras = append(extras, "unlimited credits")
	case usage.GetCreditsBalance() != "":
		extras = append(extras, "credits "+usage.GetCreditsBalance())
	}
	if usage.GetSpendLimit() > 0 || usage.GetSpendUsed() > 0 {
		extras = append(extras, fmt.Sprintf("spend %.2f/%.2f %s", usage.GetSpendUsed(), usage.GetSpendLimit(), usage.GetSpendCurrency()))
	}
	if count := usage.GetResetCreditsAvailable(); count > 0 {
		extras = append(extras, fmt.Sprintf("%d reset credit(s)", count))
	}
	return orDash(strings.Join(extras, ", "))
}

func providerUsageTable(out io.Writer, accounts []*dieterv1.ProviderAccount) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ACCOUNT\tPROVIDER\tPLAN\tWINDOW\tLEFT\tRESETS\tUPDATED")
	for _, account := range accounts {
		usage := account.GetUsage()
		prefix := fmt.Sprintf("%s\t%s\t%s", account.GetLabel(), providerKindName(account.GetProvider()), orDash(usage.GetPlan()))
		updated := orDash(usage.GetObservedAt())
		if usage.GetSource() != "" && usage.GetObservedAt() != "" {
			updated += " (" + usage.GetSource() + ")"
		}
		if len(usage.GetWindows()) == 0 {
			fmt.Fprintf(writer, "%s\t-\t%s\t-\t%s\n", prefix, providerUsageSummary(usage), updated)
			continue
		}
		for _, window := range usage.GetWindows() {
			label := window.GetLabel()
			if label == "" {
				label = orDash(providerWindowLabels[window.GetKind()])
			}
			fmt.Fprintf(writer, "%s\t%s\t%d%%\t%s\t%s\n", prefix, label, providerUsageLeft(window), orDash(window.GetResetsAt()), updated)
		}
	}
	fmt.Fprintln(writer, "\nACCOUNT\tDIETER 5H\tDIETER 7D\tEXTRAS")
	for _, account := range accounts {
		tokens := account.GetDieterTokens()
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", account.GetLabel(), providerTokenText(tokens.GetFiveHour()), providerTokenText(tokens.GetSevenDay()), providerUsageExtras(account.GetUsage()))
	}
	return writer.Flush()
}

func (c *CLI) providerUsage(args []string) error {
	const usage = `Usage: dieter provider usage [ACCOUNT] [--refresh] [--format table|json|jsonl]

Show plan usage as the provider reports it: each window's remaining share,
when it resets and when it was read, and the tokens Dieter's own turns used
in the last 5 hours and 7 days, summed over machines. Without ACCOUNT, every
account. --refresh reads usage now on the target machine (this one, or global
--machine ID|NAME) for each account signed in there.
`
	set := flags("provider usage")
	refresh := set.Bool("refresh", false, "read usage now on the target machine")
	format := set.String("format", "table", "table, json or jsonl")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() > 1 {
		return errors.New(usage)
	}
	if err := checkFormat(*format, "table", "json", "jsonl"); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	response, err := client.ListProviderAccounts(rpcCtx, &dieterv1.ListProviderAccountsRequest{})
	if err != nil {
		return err
	}
	accounts := response.GetAccounts()
	if set.NArg() == 1 {
		account, err := matchProviderAccount(accounts, set.Arg(0))
		if err != nil {
			return err
		}
		accounts = []*dieterv1.ProviderAccount{account}
	}
	if *refresh {
		daemonID := c.targetDaemonID()
		for index, account := range accounts {
			// Without an ACCOUNT, refresh only what can be read here.
			if set.NArg() == 0 && daemonID != "" && providerTargetLogin(account, daemonID).GetState() != dieterv1.ProviderLoginState_PROVIDER_LOGIN_STATE_SIGNED_IN {
				continue
			}
			refreshCtx, cancelRefresh := context.WithTimeout(context.Background(), c.connectionTimeout())
			refreshed, err := client.RefreshProviderUsage(refreshCtx, &dieterv1.RefreshProviderUsageRequest{AccountId: account.GetId()})
			cancelRefresh()
			if err != nil {
				if set.NArg() == 1 {
					return err
				}
				fmt.Fprintf(c.Err, "Could not refresh %q on %s: %v\n", account.GetLabel(), c.targetMachine(), err)
				continue
			}
			accounts[index] = refreshed
		}
	}
	switch *format {
	case "json":
		return protoJSONOut(c.Out, &dieterv1.ListProviderAccountsResponse{Accounts: accounts})
	case "jsonl":
		for _, account := range accounts {
			if err := protoJSONLine(c.Out, account); err != nil {
				return err
			}
		}
		return nil
	}
	return providerUsageTable(c.Out, accounts)
}

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func newUUIDv4() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("create idempotency key: %w", err)
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]), nil
}

func (c *CLI) providerReset(args []string) error {
	const usage = `Usage: dieter provider reset ACCOUNT --confirm RESET [--key UUID]

Spend one rate-limit reset credit of a ChatGPT account signed in on the target
machine (this one, or global --machine ID|NAME). Each run prints a fresh
idempotency key first; if the outcome is lost, rerun with --key KEY: a
repeated key never spends a second credit.
`
	set := flags("provider reset")
	confirm := set.String("confirm", "", "required exact confirmation phrase RESET")
	key := set.String("key", "", "idempotency key of an earlier attempt")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	if *confirm != "RESET" {
		return errors.New("reset spends one credit; pass --confirm RESET")
	}
	idempotencyKey := strings.ToLower(strings.TrimSpace(*key))
	if idempotencyKey != "" && !uuidPattern.MatchString(idempotencyKey) {
		return errors.New("--key must be the UUID an earlier reset printed")
	}
	if idempotencyKey == "" {
		var err error
		if idempotencyKey, err = newUUIDv4(); err != nil {
			return err
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	account, err := resolveProviderAccount(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintf(c.Out, "Idempotency key: %s\n", idempotencyKey)
	response, err := client.ConsumeProviderUsageReset(rpcCtx, &dieterv1.ConsumeProviderUsageResetRequest{AccountId: account.GetId(), IdempotencyKey: idempotencyKey})
	if err != nil {
		return err
	}
	switch outcome := response.GetOutcome(); outcome {
	case "reset":
		fmt.Fprintf(c.Out, "Reset: the rate limits of %q start over.\n", account.GetLabel())
	case "nothingToReset":
		fmt.Fprintf(c.Out, "Nothing to reset: %q is not rate limited; no credit was spent.\n", account.GetLabel())
	case "alreadyRedeemed":
		fmt.Fprintln(c.Out, "This key was already redeemed; no second credit was spent.")
	case "noCredit":
		return fmt.Errorf("%q has no reset credit left", account.GetLabel())
	default:
		fmt.Fprintf(c.Out, "Outcome: %s\n", outcome)
	}
	return nil
}

func (c *CLI) providerToken(args []string) error {
	const usage = `Usage: dieter provider token --turn

Print the current access token of the running agent turn's own Sign in with
ChatGPT account, and nothing else. Codex runs this as its provider auth
command inside Dieter turns. It needs the turn's DIETER_TURN_TOKEN and talks
only to the local daemon.
`
	set := flags("provider token")
	turn := set.Bool("turn", false, "the calling agent turn's token")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 0 || !*turn {
		return errors.New(usage)
	}
	if c.env.TurnToken == "" {
		return errors.New("dieter provider token runs only inside an agent turn (DIETER_TURN_TOKEN)")
	}
	if strings.TrimSpace(c.Machine) != "" {
		return errors.New("dieter provider token uses the turn's own machine; omit --machine")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	token, err := client.GetProviderTurnToken(rpcCtx, &dieterv1.GetProviderTurnTokenRequest{})
	if err != nil {
		return err
	}
	if token.GetToken() == "" {
		return errors.New("the daemon returned no token")
	}
	_, err = fmt.Fprintln(c.Out, token.GetToken())
	return err
}

func (c *CLI) providerLogin(args []string) error {
	const usage = `Usage: dieter provider login ACCOUNT [--device-code|--browser] [--code CODE] [--callback URL]

Sign ACCOUNT in on the target machine (this one, or global --machine ID|NAME)
with the provider's own sign-in: Claude Code for Claude accounts, Codex or
Sign in with ChatGPT for ChatGPT accounts. Dieter never sees your password.

By default Claude prints a URL: open it on any device, approve, then paste
the code the page shows. ChatGPT prints a URL and a device code to enter
there. --browser uses a URL that redirects to the machine's loopback
instead: a browser on that machine finishes by itself; elsewhere, paste the
http://localhost... address the browser could not open. On a terminal the
code or address is read without echo; --code and --callback hand it over
without prompting. Ctrl-C cancels the sign-in. Exits non-zero unless the
sign-in succeeds.

Options:
  --device-code   Enter a code on the provider's device page
  --browser       Redirect the browser to the machine's loopback
  --code CODE     The code the provider's page shows
  --callback URL  The loopback address the browser was sent to
`
	set := flags("provider login")
	deviceCode := set.Bool("device-code", false, "sign in with a device code")
	browser := set.Bool("browser", false, "sign in with a loopback browser redirect")
	code := set.String("code", "", "the code the provider's page shows")
	callback := set.String("callback", "", "the loopback address the browser was sent to")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if err := c.providerMutation(); err != nil {
		return err
	}
	if *deviceCode && *browser {
		return errors.New("use either --device-code or --browser")
	}
	session := &providerLoginSession{c: c, code: strings.TrimSpace(*code), callback: strings.TrimSpace(*callback)}
	if session.code != "" && session.callback != "" {
		return errors.New("use either --code or --callback")
	}
	if session.callback != "" {
		if err := checkLoginCallback(session.callback); err != nil {
			return err
		}
	}
	flow := dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_UNSPECIFIED
	switch {
	case *deviceCode:
		flow = dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_DEVICE_CODE
	case *browser:
		flow = dieterv1.ProviderLoginFlow_PROVIDER_LOGIN_FLOW_BROWSER
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return session.run(ctx, set.Arg(0), flow)
}

// checkLoginCallback accepts the loopback address a provider redirected the
// browser to, such as http://localhost:PORT/callback?code=... .
func checkLoginCallback(raw string) error {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.RawQuery != "" {
		host := parsed.Hostname()
		if host == "localhost" {
			return nil
		}
		if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
			return nil
		}
	}
	return errors.New("the callback must be the http://localhost... or http://127.0.0.1... address the browser was sent to, with its query")
}

// providerLoginInput turns a pasted line into the sign-in input: a loopback
// address is a callback, anything else a code.
func providerLoginInput(value string) (*dieterv1.SubmitProviderLoginInputRequest, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, errors.New("nothing was entered")
	}
	lower := strings.ToLower(value)
	if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
		if err := checkLoginCallback(value); err != nil {
			return nil, err
		}
		return &dieterv1.SubmitProviderLoginInputRequest{Input: &dieterv1.SubmitProviderLoginInputRequest_CallbackUrl{CallbackUrl: value}}, nil
	}
	return &dieterv1.SubmitProviderLoginInputRequest{Input: &dieterv1.SubmitProviderLoginInputRequest_Code{Code: value}}, nil
}

// errInputRejected marks input the user may correct and enter again.
var errInputRejected = errors.New("input rejected")

type providerPromptResult struct {
	value string
	err   error
}

// providerLoginSession drives one sign-in: it shows each challenge, hands
// over the code or callback (given, or read from the terminal) and waits for
// the outcome. Leaving early cancels the sign-in on the daemon.
type providerLoginSession struct {
	c              *CLI
	client         dieterclient.Client
	account        *dieterv1.ProviderAccount
	loginID        string
	code, callback string
	shown          *dieterv1.ProviderLoginChallenge
	// handedOver is set once input reached the daemon; a challenge that asks
	// again (a rejected code) clears it.
	handedOver bool
	prompting  bool
	noPrompt   bool
	prompts    chan providerPromptResult
	promptCtx  context.Context
	promptDone chan struct{}
}

func (s *providerLoginSession) run(ctx context.Context, reference string, flow dieterv1.ProviderLoginFlow) error {
	client, _, err := s.c.rpc(ctx)
	if err != nil {
		return err
	}
	s.client = client
	callCtx, cancel := context.WithTimeout(ctx, s.c.connectionTimeout())
	account, err := resolveProviderAccount(callCtx, client, reference)
	if err != nil {
		cancel()
		return err
	}
	s.account = account
	login, err := client.StartProviderLogin(callCtx, &dieterv1.StartProviderLoginRequest{AccountId: account.GetId(), Flow: flow})
	cancel()
	if err != nil {
		return err
	}
	s.loginID = login.GetLoginId()
	fmt.Fprintf(s.c.Out, "Signing %s account %q in to %s on %s. Ctrl-C cancels.\n", providerKindTitle(account.GetProvider()), account.GetLabel(), providerLoginTool(account), s.c.targetMachine())

	promptCtx, stopPrompt := context.WithCancel(ctx)
	defer func() {
		// Wait for an abandoned prompt so the terminal gets its echo back.
		stopPrompt()
		if s.promptDone != nil {
			<-s.promptDone
		}
	}()
	s.promptCtx, s.prompts = promptCtx, make(chan providerPromptResult, 1)
	if done, err := s.handle(ctx, login); done {
		return err
	}
	watchCtx, stopWatch := context.WithCancel(ctx)
	defer stopWatch()
	stream, err := client.WatchProviderLogin(watchCtx, &dieterv1.WatchProviderLoginRequest{LoginId: s.loginID, HeartbeatSeconds: 15})
	if err != nil {
		return s.abandon(err)
	}
	events := make(chan *dieterv1.ProviderLogin)
	failures := make(chan error, 1)
	go func() {
		for {
			event, err := stream.Recv()
			if err != nil {
				failures <- err
				return
			}
			select {
			case events <- event:
			case <-watchCtx.Done():
				return
			}
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return s.abandon(errors.New("sign-in canceled"))
		case event := <-events:
			if done, err := s.handle(ctx, event); done {
				return err
			}
		case err := <-failures:
			if ctx.Err() != nil {
				return s.abandon(errors.New("sign-in canceled"))
			}
			if errors.Is(err, io.EOF) {
				err = fmt.Errorf("the sign-in ended without a result; run `dieter provider check %s`", s.account.GetId())
			}
			return s.abandon(err)
		case result := <-s.prompts:
			s.prompting = false
			if result.err != nil {
				if ctx.Err() != nil {
					return s.abandon(errors.New("sign-in canceled"))
				}
				if errors.Is(result.err, io.EOF) {
					// The terminal closed; the sign-in can still finish in the browser.
					s.noPrompt = true
					continue
				}
				return s.abandon(result.err)
			}
			login, err := s.submit(ctx, result.value)
			if errors.Is(err, errInputRejected) {
				fmt.Fprintf(s.c.Err, "%v\n", err)
				s.startPrompt()
				continue
			}
			if err != nil {
				return s.abandon(err)
			}
			if done, err := s.handle(ctx, login); done {
				return err
			}
		}
	}
}

// handle shows a new challenge, hands over input once the sign-in waits for
// it, and reports whether the sign-in ended.
func (s *providerLoginSession) handle(ctx context.Context, login *dieterv1.ProviderLogin) (bool, error) {
	switch login.GetPhase() {
	case dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_SUCCEEDED:
		identity := ""
		if text := providerIdentityText(login.GetIdentity()); text != "" {
			identity = " as " + text
		}
		fmt.Fprintf(s.c.Out, "Signed in: %q on %s%s.\n", s.account.GetLabel(), s.c.targetMachine(), identity)
		return true, nil
	case dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_FAILED:
		return true, fmt.Errorf("sign-in failed: %s", providerLoginError(login))
	case dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_CANCELED:
		return true, errors.New("the sign-in was canceled")
	}
	challenge := login.GetChallenge()
	if challenge != nil && !proto.Equal(challenge, s.shown) {
		s.shown = proto.Clone(challenge).(*dieterv1.ProviderLoginChallenge)
		s.printChallenge(challenge)
	}
	if login.GetPhase() != dieterv1.ProviderLoginPhase_PROVIDER_LOGIN_PHASE_WAITING {
		return false, nil
	}
	// Events may omit an unchanged challenge; the last one shown still applies.
	switch s.shown.GetExpects() {
	case dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE, dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK:
	case dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE:
		if s.code != "" || s.callback != "" {
			return true, s.abandon(errors.New("this sign-in takes no code or callback; it finishes on the provider's page"))
		}
		return false, nil
	default:
		return false, nil
	}
	if s.handedOver {
		if login.GetErrorMessage() == "" && login.GetErrorCode() == "" {
			return false, nil
		}
		// The sign-in asks again: the provider refused what was handed over.
		if s.code != "" || s.callback != "" {
			return true, s.abandon(fmt.Errorf("the provider did not accept the input: %s", providerLoginError(login)))
		}
		fmt.Fprintf(s.c.Err, "The provider did not accept that: %s\n", providerLoginError(login))
		s.handedOver = false
	}
	if given := s.code + s.callback; given != "" {
		next, err := s.submit(ctx, given)
		if err != nil {
			return true, s.abandon(err)
		}
		return s.handle(ctx, next)
	}
	if !s.prompting {
		s.startPrompt()
	}
	return false, nil
}

func providerLoginError(login *dieterv1.ProviderLogin) string {
	message, code := login.GetErrorMessage(), login.GetErrorCode()
	switch {
	case message != "" && code != "":
		return message + " (" + code + ")"
	case message != "":
		return message
	case code != "":
		return code
	}
	return "unknown error"
}

func (s *providerLoginSession) printChallenge(challenge *dieterv1.ProviderLoginChallenge) {
	out := s.c.Out
	if open := challenge.GetOpenUrl(); open != "" {
		fmt.Fprintf(out, "\nOpen this URL in a browser:\n  %s\n", open)
	}
	if local := challenge.GetLocalUrl(); local != "" && local != challenge.GetOpenUrl() && strings.TrimSpace(s.c.Machine) == "" {
		fmt.Fprintf(out, "\nIn a browser on this machine, this URL finishes without a code:\n  %s\n", local)
	}
	if code := challenge.GetUserCode(); code != "" {
		fmt.Fprintf(out, "\nEnter this code on that page: %s\n", code)
	}
	if expires := challenge.GetExpiresAt(); expires != "" {
		fmt.Fprintf(out, "It expires at %s.\n", expires)
	}
	switch challenge.GetExpects() {
	case dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CODE:
		fmt.Fprintln(out, "\nThen paste the code the page shows, or the http://localhost... address the browser could not open.")
	case dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK:
		fmt.Fprintf(out, "\nThe browser then goes to %s. A browser on %s finishes by itself; elsewhere, paste the address it could not open.\n", providerCallbackHint(challenge), s.c.targetMachine())
	case dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_NONE:
		fmt.Fprintln(out, "\nWaiting for you to finish in the browser...")
	}
}

func providerCallbackHint(challenge *dieterv1.ProviderLoginChallenge) string {
	if port := challenge.GetCallbackPort(); port > 0 {
		return fmt.Sprintf("http://localhost:%d/...", port)
	}
	return "an http://localhost... address"
}

// startPrompt reads the code or address in the background, so the watch keeps
// reporting while the user types, or finishes the sign-in in a browser.
func (s *providerLoginSession) startPrompt() {
	if s.noPrompt {
		return
	}
	prompt := s.c.promptHidden
	if prompt == nil {
		file, ok := s.c.In.(*os.File)
		if !ok || !isTerminal(file) {
			s.noPrompt = true
			fmt.Fprintln(s.c.Err, "No terminal to read the code from: pass --code CODE or --callback URL, or finish in a browser on the target machine.")
			return
		}
		prompt = func(ctx context.Context, label string) (string, error) {
			fmt.Fprint(s.c.Err, label)
			value, err := readHiddenContext(ctx, file)
			fmt.Fprintln(s.c.Err)
			return value, err
		}
	}
	label := "Code or address (hidden): "
	if s.shown.GetExpects() == dieterv1.ProviderLoginInput_PROVIDER_LOGIN_INPUT_CALLBACK {
		label = "Address the browser could not open (hidden): "
	}
	done := make(chan struct{})
	s.prompting, s.promptDone = true, done
	ctx, results := s.promptCtx, s.prompts
	go func() {
		defer close(done)
		value, err := prompt(ctx, label)
		results <- providerPromptResult{value: value, err: err}
	}()
}

// submit hands a code or callback to the daemon. Input the user can fix
// returns errInputRejected.
func (s *providerLoginSession) submit(ctx context.Context, value string) (*dieterv1.ProviderLogin, error) {
	request, err := providerLoginInput(value)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errInputRejected, err)
	}
	request.LoginId = s.loginID
	callCtx, cancel := context.WithTimeout(ctx, s.c.connectionTimeout())
	defer cancel()
	login, err := s.client.SubmitProviderLoginInput(callCtx, request)
	if status.Code(err) == codes.InvalidArgument && s.code == "" && s.callback == "" {
		return nil, fmt.Errorf("%w: %s", errInputRejected, status.Convert(err).Message())
	}
	if err != nil {
		return nil, err
	}
	s.handedOver = true
	return login, nil
}

// abandon cancels the sign-in on the daemon and returns cause.
func (s *providerLoginSession) abandon(cause error) error {
	ctx, cancel := context.WithTimeout(context.Background(), s.c.connectionTimeout())
	defer cancel()
	if _, err := s.client.CancelProviderLogin(ctx, &dieterv1.CancelProviderLoginRequest{LoginId: s.loginID}); err != nil {
		fmt.Fprintf(s.c.Err, "Could not cancel the sign-in on %s: %v\n", s.c.targetMachine(), err)
	}
	return cause
}
