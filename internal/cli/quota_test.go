package cli

import (
	"bytes"
	"strings"
	"testing"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
)

func TestQuotaProviderArgumentAliases(t *testing.T) {
	for _, test := range []struct {
		value string
		want  gatewayv1.ProviderQuotaProvider
	}{
		{"", gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED},
		{"openai", gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX},
		{"codex", gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX},
		{"claude", gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE},
	} {
		args := []string(nil)
		if test.value != "" {
			args = []string{test.value}
		}
		got, err := quotaProviderArgument(args)
		if err != nil || got != test.want {
			t.Fatalf("provider %q = %s, %v; want %s", test.value, got, err, test.want)
		}
	}
}

func TestQuotaTableKeepsAccountsSeparateAndAbbreviatesKeys(t *testing.T) {
	var output bytes.Buffer
	client := New(store.New(t.TempDir()))
	client.Out = &output
	groups := []*gatewayv1.ProviderQuotaGroup{{
		Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		Accounts: []*gatewayv1.ProviderQuotaSnapshot{
			{AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", Plan: "plus", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, Windows: []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(75)}}},
			{AccountKey: "account_key_bbbbbbbbbbbbbbbbbbbb", Plan: "team", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, Windows: []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(25)}}},
		},
	}}
	if err := client.writeQuotaGroups(groups, "table", nil); err != nil {
		t.Fatal(err)
	}
	value := output.String()
	if !strings.Contains(value, "75%") || !strings.Contains(value, "25%") {
		t.Fatalf("separate account rows are missing: %q", value)
	}
	for _, key := range []string{"account_key_aaaaaaaaaaaaaaaaaaaa", "account_key_bbbbbbbbbbbbbbbbbbbb"} {
		if strings.Contains(value, key) {
			t.Fatalf("table exposed full opaque account key %q", key)
		}
	}
}
