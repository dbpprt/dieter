package cli

import (
	"context"
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
	default:
		return fmt.Errorf("unknown quota action %q; run `dieter quota --help`", args[0])
	}
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
	fmt.Fprintln(writer, "PROVIDER\tACCOUNT\tPLAN\tSTATUS\tWINDOW\tREMAINING\tRESETS")
	for _, group := range groups {
		provider := quotaProviderName(group.GetProvider())
		if len(group.GetAccounts()) == 0 {
			fmt.Fprintf(writer, "%s\t—\t—\tunavailable\t—\t—\t—\n", provider)
			continue
		}
		for _, account := range group.GetAccounts() {
			key := shortAccountKey(account.GetAccountKey())
			if len(account.GetWindows()) == 0 {
				fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t—\t—\t%s\n", provider, key, account.GetPlan(), quotaAvailabilityName(account.GetAvailability()), account.GetNextResetAt())
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
				fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", provider, key, account.GetPlan(), quotaAvailabilityName(account.GetAvailability()), label, remaining, window.GetResetsAt())
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
