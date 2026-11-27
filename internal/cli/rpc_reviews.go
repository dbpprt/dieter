package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/emptypb"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const reviewerHelp = `Usage: dieter reviewer <action>

Actions:
  show     Print the account's code reviewer setting
  update   Change the harness, model, depth or limits of the code reviewer

The code reviewer is a separate, Dieter-managed harness that reviews a
conversation's changes: everything that differs from the workspace's base,
committed or not. One setting covers every machine of the account; each review
runs on the conversation's own machine, on a disposable snapshot of its
workspace. Give a conversation the reviewer with --code-review on card or chat
create (or dieter card reviewer CARD on); its agent then gets a
request_code_review tool. Review a conversation yourself with
dieter card review CARD --wait.
`

// codeReviewPollInterval is how often review --wait asks for the result
// (a variable for tests).
var codeReviewPollInterval = 2 * time.Second

// codeReviewWaitLimit bounds review --wait: the thorough review's own bound
// plus scheduling slack.
const codeReviewWaitLimit = 25 * time.Minute

func (c *CLI) rpcReviewer(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, reviewerHelp)
		return nil
	}
	switch args[0] {
	case "show":
		return c.rpcReviewerShow(args[1:])
	case "update":
		return c.rpcReviewerUpdate(args[1:])
	default:
		return fmt.Errorf("unknown reviewer action %q; run `dieter reviewer --help`", args[0])
	}
}

func (c *CLI) rpcReviewerShow(args []string) error {
	const usage = `Usage: dieter reviewer show [--format text|json]

Print the account's code reviewer setting. Until someone saves one, the
defaults are shown and "configured" is false.
`
	set := flags("reviewer show")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("reviewer show takes no arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetReviewerSettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writeReviewerSettings(c.Out, value)
	return nil
}

func (c *CLI) rpcReviewerUpdate(args []string) error {
	const usage = `Usage: dieter reviewer update [options]

Change the account's code reviewer setting. Options you leave out keep their
current value.

Options:
  --harness HARNESS          Catalog harness (see dieter harness list); Strix is refused
  --model MODEL              Model of that harness
  --effort EFFORT            Reasoning effort (empty: the model's default)
  --account ID|LABEL         Provider account for Claude Code and Codex
                             reviewers; "" uses the provider's default
  --depth quick|thorough     quick: one pass over the inlined diff (default);
                             thorough: every finding confirmed in the code
  --max-findings N           At most N findings per review (1-20, default 6)
  --min-confidence N         Drop findings rated below N (0-10, default 0)
  --max-rounds N             Reviews the agent may request per task (1-10, default 3)
  --instructions TEXT        Extra instructions for every review (4 KiB)
  --instructions-file FILE   Read them from FILE or -
  --ignore GLOB              Leave matching paths out of reviews; repeat. Lock
                             files and generated code are always left out
  --clear-ignore             Remove every --ignore glob
  --format text|json         Output format

Agent turns cannot change the setting.
`
	set := flags("reviewer update")
	harnessName := set.String("harness", "", "catalog harness")
	modelName := set.String("model", "", "model")
	effort := set.String("effort", "", "reasoning effort")
	account := set.String("account", "", "provider account ID or label")
	depth := set.String("depth", "", "quick or thorough")
	maxFindings := set.Int("max-findings", 0, "maximum findings per review")
	minConfidence := set.Int("min-confidence", -1, "minimum confidence")
	maxRounds := set.Int("max-rounds", 0, "maximum agent reviews per task")
	instructions := set.String("instructions", "", "extra instructions")
	instructionsFile := set.String("instructions-file", "", "extra instructions file")
	var ignore repeatedStrings
	set.Var(&ignore, "ignore", "ignored path glob")
	clearIgnore := set.Bool("clear-ignore", false, "remove every ignore glob")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("reviewer update takes options only")
	}
	given := map[string]bool{}
	set.Visit(func(f *flag.Flag) { given[f.Name] = true })
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	current, err := client.GetReviewerSettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	next := &dieterv1.ReviewerSettings{
		Harness: current.GetHarness(), Model: current.GetModel(), Effort: current.GetEffort(), AccountId: current.GetAccountId(),
		Depth: current.GetDepth(), MaxFindings: current.GetMaxFindings(), MinConfidence: current.GetMinConfidence(),
		Instructions: current.GetInstructions(), IgnoreGlobs: append([]string(nil), current.GetIgnoreGlobs()...), MaxRounds: current.GetMaxRounds(),
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
	if given["depth"] {
		next.Depth = *depth
	}
	if given["max-findings"] {
		next.MaxFindings = int32(*maxFindings)
	}
	if given["min-confidence"] {
		next.MinConfidence = int32(*minConfidence)
	}
	if given["max-rounds"] {
		next.MaxRounds = int32(*maxRounds)
	}
	if given["instructions"] || given["instructions-file"] {
		if next.Instructions, err = textValue(*instructions, *instructionsFile, c.In); err != nil {
			return err
		}
	}
	if *clearIgnore {
		next.IgnoreGlobs = nil
	}
	next.IgnoreGlobs = append(next.IgnoreGlobs, ignore...)
	value, err := client.UpdateReviewerSettings(rpcCtx, &dieterv1.UpdateReviewerSettingsRequest{Settings: next, ExpectedRevision: current.GetRevision()})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writeReviewerSettings(c.Out, value)
	return nil
}

func writeReviewerSettings(out io.Writer, value *dieterv1.ReviewerSettings) {
	model := value.GetModel()
	if value.GetEffort() != "" {
		model += " (" + value.GetEffort() + ")"
	}
	fmt.Fprintf(out, "Harness:\t%s\nModel:\t%s\n", value.GetHarness(), model)
	account := value.GetAccountId()
	if account == "" {
		account = "provider default"
	}
	fmt.Fprintf(out, "Account:\t%s\nDepth:\t%s\nMax findings:\t%d\nMin confidence:\t%d\nMax rounds:\t%d\n", account, value.GetDepth(), value.GetMaxFindings(), value.GetMinConfidence(), value.GetMaxRounds())
	if globs := value.GetIgnoreGlobs(); len(globs) > 0 {
		fmt.Fprintf(out, "Ignore:\t%s\n", strings.Join(globs, ", "))
	}
	if text := value.GetInstructions(); text != "" {
		fmt.Fprintf(out, "Instructions:\t%s\n", strings.ReplaceAll(text, "\n", "\n\t"))
	}
	if !value.GetConfigured() {
		fmt.Fprintln(out, "(defaults: no reviewer setting saved yet)")
	}
}

func (c *CLI) rpcCardReview(args []string) error {
	const usage = `Usage: dieter card review [--wait] [--focus TEXT] [--depth quick|thorough] [--format text|json] CARD

Review the conversation's changes with the account's code reviewer (see
dieter reviewer --help): everything that differs from the workspace's base,
committed or not, untracked files included. The review runs on the
conversation's machine and appears in the conversation. Without --wait it
prints the running review's ID; with --wait it waits for the result and prints
the findings. An agent turn may review only its own conversation, and its
review counts as the agent's.
Global --machine selects the owning daemon through authenticated direct/relay routes.
`
	set := flags("card review")
	wait := set.Bool("wait", false, "wait for the result and print it")
	focus := set.String("focus", "", "what the reviewer should look at most closely")
	depth := set.String("depth", "", "quick or thorough (default: the setting)")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, c.scoped(usage), c.Out)
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
	review, err := client.StartCodeReview(rpcCtx, &dieterv1.StartCodeReviewRequest{CardId: set.Arg(0), Focus: *focus, Depth: *depth})
	if err != nil {
		return err
	}
	if *wait {
		if review, err = c.waitForCodeReview(set.Arg(0), review.GetId()); err != nil {
			return err
		}
	}
	if *format == "json" {
		return protoJSONOut(c.Out, review)
	}
	if !*wait {
		fmt.Fprintf(c.Out, "Code review %s is running (%s, %s %s). Read it with: dieter card reviews --id %s %s\n", review.GetId(), review.GetDepth(), review.GetHarness(), review.GetModel(), review.GetId(), set.Arg(0))
		return nil
	}
	writeCodeReview(c.Out, review)
	return nil
}

// waitForCodeReview polls one review until it has finished.
func (c *CLI) waitForCodeReview(cardID, reviewID string) (*dieterv1.CodeReview, error) {
	deadline := time.Now().Add(codeReviewWaitLimit)
	for {
		review, err := c.getCodeReview(cardID, reviewID)
		if err != nil {
			return nil, err
		}
		if review.GetStatus() != "running" {
			return review, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("code review %s is still running after %s", reviewID, codeReviewWaitLimit)
		}
		time.Sleep(codeReviewPollInterval)
	}
}

func (c *CLI) getCodeReview(cardID, reviewID string) (*dieterv1.CodeReview, error) {
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, err
	}
	return client.GetCodeReview(rpcCtx, &dieterv1.GetCodeReviewRequest{CardId: cardID, ReviewId: reviewID})
}

func (c *CLI) rpcCardReviews(args []string) error {
	const usage = `Usage: dieter card reviews [--id REVIEW] [--format text|json] CARD

List the conversation's code reviews, newest first, or show one with --id.
Global --machine selects the owning daemon through authenticated direct/relay routes.
`
	set := flags("card reviews")
	reviewID := set.String("id", "", "show this review")
	format := set.String("format", "text", "text or json")
	help, err := parse(set, args, c.scoped(usage), c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	if *reviewID != "" {
		review, err := c.getCodeReview(set.Arg(0), *reviewID)
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, review)
		}
		writeCodeReview(c.Out, review)
		return nil
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ListCodeReviews(rpcCtx, &dieterv1.ListCodeReviewsRequest{CardId: set.Arg(0)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	if len(value.GetReviews()) == 0 {
		fmt.Fprintln(c.Out, "No code reviews yet.")
		return nil
	}
	for _, review := range value.GetReviews() {
		fmt.Fprintf(c.Out, "%s\t%s\tround %d\t%s\t%s\t%s\n", review.GetId(), review.GetStatus(), review.GetRound(), reviewCounts(review), review.GetTrigger(), review.GetStartedAt())
	}
	return nil
}

func (c *CLI) rpcCardReviewer(args []string) error {
	const usage = `Usage: dieter card reviewer CARD on|off

Switch the conversation's code reviewer on or off. From its next turn, the
agent gets (or loses) the request_code_review tool and its instructions.
Agent turns cannot switch it.
Global --machine selects the owning daemon through authenticated direct/relay routes.
`
	set := flags("card reviewer")
	help, err := parse(set, args, c.scoped(usage), c.Out)
	if help || err != nil {
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
	card, err := client.SetCardCodeReview(rpcCtx, &dieterv1.SetCardCodeReviewRequest{CardId: set.Arg(0), Enabled: set.Arg(1) == "on"})
	if err != nil {
		return err
	}
	state := "off"
	if card.GetCodeReview() {
		state = "on"
	}
	fmt.Fprintf(c.Out, "Code reviewer %s for %s\n", state, card.GetId())
	return nil
}

func reviewCounts(review *dieterv1.CodeReview) string {
	if review.GetStatus() == "running" {
		return "reviewing"
	}
	if review.GetStatus() != "completed" {
		return review.GetStatus()
	}
	if review.GetFilesChanged() == 0 {
		return "no changes"
	}
	high := 0
	for _, finding := range review.GetFindings() {
		if finding.GetSeverity() == "high" {
			high++
		}
	}
	text := fmt.Sprintf("%d findings", len(review.GetFindings()))
	if len(review.GetFindings()) == 1 {
		text = "1 finding"
	}
	if high > 0 {
		text += fmt.Sprintf(" (%d high)", high)
	}
	return text
}

// writeCodeReview prints a review as the agent's tool result reads.
func writeCodeReview(out io.Writer, review *dieterv1.CodeReview) {
	switch review.GetStatus() {
	case "failed":
		fmt.Fprintf(out, "Code review %s failed: %s\n", review.GetId(), review.GetError())
		return
	case "cancelled":
		fmt.Fprintf(out, "Code review %s was cancelled.\n", review.GetId())
		return
	case "running":
		fmt.Fprintf(out, "Code review %s is still running.\n", review.GetId())
		return
	}
	fmt.Fprintf(out, "Code review %s (round %d, %s, %s %s)", review.GetId(), max(1, review.GetRound()), review.GetDepth(), review.GetHarness(), review.GetModel())
	if review.GetFilesChanged() == 0 {
		fmt.Fprintln(out, ": there are no changes to review.")
		return
	}
	fmt.Fprintf(out, " of %d files, +%d -%d, in %s.\n", review.GetFilesChanged(), review.GetAdditions(), review.GetDeletions(), (time.Duration(review.GetDurationMs()) * time.Millisecond).Round(time.Second))
	if review.GetSummary() != "" {
		fmt.Fprintln(out, "Summary: "+review.GetSummary())
	}
	if security := review.GetSecurity(); security != "" && !strings.EqualFold(security, "no") {
		fmt.Fprintln(out, "Security: "+security)
	}
	if len(review.GetResolved()) > 0 {
		fmt.Fprintf(out, "Resolved since the previous review: %d.\n", len(review.GetResolved()))
	}
	if len(review.GetFindings()) == 0 {
		fmt.Fprintln(out, "No findings.")
		return
	}
	for _, finding := range review.GetFindings() {
		location := finding.GetFile()
		if finding.GetStartLine() > 0 {
			location = fmt.Sprintf("%s:%d", finding.GetFile(), finding.GetStartLine())
			if finding.GetEndLine() > finding.GetStartLine() {
				location += fmt.Sprintf("-%d", finding.GetEndLine())
			}
		}
		state := ""
		if finding.GetStatus() == "open" {
			state = ", still open"
		}
		fmt.Fprintf(out, "\n[%s] %s (%s, confidence %d%s) %s\n%s\n", finding.GetId(), finding.GetTitle(), finding.GetSeverity(), finding.GetConfidence(), state, location, strings.TrimSpace(finding.GetBody()))
		if suggestion := strings.TrimSpace(finding.GetSuggestion()); suggestion != "" {
			fmt.Fprintln(out, "Suggestion: "+suggestion)
		}
	}
}
