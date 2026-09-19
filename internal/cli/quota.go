package cli

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

const quotaHelp = `Usage: dieter quota <action>

Actions:
  list [PROVIDER] [--format table|json|jsonl]  List account quotas and provider summaries
  watch [PROVIDER] [--count N]                Stream quota updates as JSON Lines
  refresh [PROVIDER] [--account KEY]          Request a bounded refresh and show the result
  include PROVIDER --account KEY              Include an account in its header summary
  exclude PROVIDER --account KEY              Exclude an account from its header summary
  reset openai --account KEY --confirm RESET  Consume one available reset credit

PROVIDER is openai, codex, or claude. Quotas are gateway-account scoped and
combine accounts discovered by all online enrolled machines. Summary values
show the lowest remaining window; separate account quotas are never summed.
`

func (c *CLI) quotaCommand(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, quotaHelp)
		return nil
	}
	if strings.TrimSpace(c.Machine) != "" {
		return errors.New("quota is gateway-account scoped and does not accept global --machine")
	}
	switch args[0] {
	case "list":
		return c.quotaList(args[1:])
	case "watch":
		return c.quotaWatch(args[1:])
	case "refresh":
		return c.quotaRefresh(args[1:])
	case "include":
		return c.quotaSetInclusion(args[1:], true)
	case "exclude":
		return c.quotaSetInclusion(args[1:], false)
	case "reset":
		return c.quotaReset(args[1:])
	default:
		return fmt.Errorf("unknown quota action %q; run `dieter quota --help`", args[0])
	}
}

func (c *CLI) quotaSetInclusion(args []string, included bool) error {
	action := "exclude"
	if included {
		action = "include"
	}
	usage := fmt.Sprintf("Usage: dieter quota %s PROVIDER --account KEY\n", action)
	set := flags("quota " + action)
	account := set.String("account", "", "opaque account key returned by quota list --format json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	provider, err := quotaProviderArgument(set.Args())
	if err != nil {
		return err
	}
	if provider == gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED || strings.TrimSpace(*account) == "" {
		return errors.New("PROVIDER and --account KEY are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return err
	}
	response, err := gateway.client.SetProviderQuotaSummaryInclusion(ctx, &gatewayv1.SetProviderQuotaSummaryInclusionRequest{
		Provider: provider, AccountKey: strings.TrimSpace(*account), Included: included,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(c.Out, "Account %s is now %s the provider summary.\n", shortAccountKey(*account), map[bool]string{true: "included in", false: "excluded from"}[included])
	return c.writeQuotaGroups(response.GetGroups(), "table", nil)
}

func (c *CLI) quotaReset(args []string) error {
	const usage = "Usage: dieter quota reset openai --account KEY --confirm RESET\n"
	set := flags("quota reset")
	account := set.String("account", "", "opaque OpenAI account key returned by quota list --format json")
	confirm := set.String("confirm", "", "required exact confirmation phrase RESET")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	provider, err := quotaProviderArgument(set.Args())
	if err != nil {
		return err
	}
	if provider != gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX || strings.TrimSpace(*account) == "" {
		return errors.New("openai and --account KEY are required")
	}
	if *confirm != "RESET" {
		return errors.New("reset consumes one credit; pass --confirm RESET")
	}
	idempotencyKey, err := quotaResetUUID()
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return err
	}
	response, err := gateway.client.ConsumeProviderQuotaReset(ctx, &gatewayv1.ConsumeProviderQuotaResetRequest{
		Provider: provider, AccountKey: strings.TrimSpace(*account), IdempotencyKey: idempotencyKey,
	})
	if err != nil {
		return err
	}
	if !response.GetAccepted() {
		return errors.New("no online daemon with access to that OpenAI account accepted the reset")
	}
	fmt.Fprintf(c.Out, "Reset requested for %s. Idempotency key: %s\n", shortAccountKey(*account), idempotencyKey)
	return nil
}

func quotaResetUUID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("create reset idempotency key: %w", err)
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]), nil
}

func (c *CLI) quotaList(args []string) error {
	const usage = "Usage: dieter quota list [PROVIDER] [--format table|json|jsonl]\n"
	set := flags("quota list")
	format := set.String("format", "table", "table, json, or jsonl")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	provider, err := quotaProviderArgument(set.Args())
	if err != nil {
		return err
	}
	if *format != "table" && *format != "json" && *format != "jsonl" {
		return errors.New("--format must be table, json, or jsonl")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return err
	}
	response, err := gateway.client.ListProviderQuotas(ctx, &gatewayv1.ListProviderQuotasRequest{Provider: provider})
	if err != nil {
		return err
	}
	return c.writeQuotaGroups(response.GetGroups(), *format, response)
}

func (c *CLI) quotaWatch(args []string) error {
	const usage = "Usage: dieter quota watch [PROVIDER] [--count N]\n"
	set := flags("quota watch")
	count := set.Int("count", 0, "stop after N frames; zero streams until interrupted")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if *count < 0 {
		return errors.New("--count cannot be negative")
	}
	provider, err := quotaProviderArgument(set.Args())
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return err
	}
	stream, err := gateway.client.WatchProviderQuotas(ctx, &gatewayv1.WatchProviderQuotasRequest{
		HeartbeatSeconds: 15,
		Provider:         provider,
	})
	if err != nil {
		return err
	}
	for emitted := 0; ; emitted++ {
		value, receiveErr := stream.Recv()
		if receiveErr != nil {
			return streamEnd(receiveErr, ctx)
		}
		if err := protoJSONLine(c.Out, value); err != nil {
			return err
		}
		if *count > 0 && emitted+1 >= *count {
			return nil
		}
	}
}

func (c *CLI) quotaRefresh(args []string) error {
	const usage = "Usage: dieter quota refresh [PROVIDER] [--account KEY] [--format table|json]\n"
	set := flags("quota refresh")
	account := set.String("account", "", "opaque account key returned by quota list --format json")
	format := set.String("format", "table", "table or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	provider, err := quotaProviderArgument(set.Args())
	if err != nil {
		return err
	}
	if *format != "table" && *format != "json" {
		return errors.New("--format must be table or json")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return err
	}
	response, err := gateway.client.RefreshProviderQuotas(ctx, &gatewayv1.RefreshProviderQuotasRequest{
		Provider:   provider,
		AccountKey: strings.TrimSpace(*account),
	})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, response)
	}
	if !response.GetAccepted() {
		fmt.Fprintln(c.Out, "No matching online account source accepted the refresh request.")
	}
	return c.writeQuotaGroups(response.GetGroups(), "table", nil)
}

func quotaProviderArgument(args []string) (gatewayv1.ProviderQuotaProvider, error) {
	if len(args) > 1 {
		return gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED, errors.New("at most one PROVIDER is accepted")
	}
	if len(args) == 0 || strings.TrimSpace(args[0]) == "" || strings.EqualFold(args[0], "all") {
		return gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED, nil
	}
	switch strings.ToLower(strings.TrimSpace(args[0])) {
	case "openai", "codex":
		return gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, nil
	case "anthropic", "claude":
		return gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE, nil
	default:
		return gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED, fmt.Errorf("unknown provider %q; use openai or claude", args[0])
	}
}

func (c *CLI) writeQuotaGroups(groups []*gatewayv1.ProviderQuotaGroup, format string, whole any) error {
	if format == "json" {
		return protoJSONOut(c.Out, whole)
	}
	if format == "jsonl" {
		for _, group := range groups {
			if err := protoJSONLine(c.Out, group); err != nil {
				return err
			}
		}
		return nil
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	fmt.Fprintln(writer, "PROVIDER\tACCOUNT\tEMAIL\tPLAN\tSUMMARY\tSTATUS\tWINDOW\tREMAINING\tRESETS")
	for _, group := range groups {
		provider := quotaProviderName(group.GetProvider())
		if len(group.GetAccounts()) == 0 {
			fmt.Fprintf(writer, "%s\t—\t—\t—\t—\tunavailable\t—\t—\t—\n", provider)
			continue
		}
		for _, account := range group.GetAccounts() {
			key := shortAccountKey(account.GetAccountKey())
			summaryMembership := "included"
			if account.IncludedInSummary != nil && !account.GetIncludedInSummary() {
				summaryMembership = "excluded"
			}
			if len(account.GetWindows()) == 0 {
				fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t—\t—\t%s\n", provider, key, account.GetDisplayEmail(), account.GetPlan(), summaryMembership, quotaAvailabilityName(account.GetAvailability()), account.GetNextResetAt())
				continue
			}
			for _, window := range account.GetWindows() {
				remaining := "—"
				if window.RemainingPercent != nil {
					remaining = fmt.Sprintf("%d%%", window.GetRemainingPercent())
				}
				label := window.GetLabel()
				if label == "" {
					label = strings.TrimPrefix(strings.ToLower(window.GetKind().String()), "provider_quota_window_kind_")
				}
				fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", provider, key, account.GetDisplayEmail(), account.GetPlan(), summaryMembership, quotaAvailabilityName(account.GetAvailability()), label, remaining, window.GetResetsAt())
			}
		}
	}
	return writer.Flush()
}

func quotaProviderName(provider gatewayv1.ProviderQuotaProvider) string {
	switch provider {
	case gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX:
		return "OpenAI"
	case gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE:
		return "Claude"
	default:
		return "Unknown"
	}
}

func quotaAvailabilityName(value gatewayv1.ProviderQuotaAvailability) string {
	return strings.TrimPrefix(strings.ToLower(value.String()), "provider_quota_availability_")
}

func shortAccountKey(value string) string {
	if len(value) <= 8 {
		return value
	}
	return "…" + value[len(value)-8:]
}
