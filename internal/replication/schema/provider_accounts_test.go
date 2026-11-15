package schema

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

const testAccountID = "pa_abcdefghijklmnopqrstuvwxyz"

func providerKV(t *testing.T, ns, key string, value any) crdt.Record {
	t.Helper()
	raw, ok := value.([]byte)
	if !ok {
		var err error
		if raw, err = json.Marshal(value); err != nil {
			t.Fatal(err)
		}
	}
	return crdt.Record{Kind: KVKindPrefix + ns, ID: key, Versions: []crdt.Version{{Clock: crdt.Clock{"a": 1}, Value: raw}}}
}

func TestProviderAccountRecordsAreValidated(t *testing.T) {
	t.Parallel()
	account := ProviderAccountRecord{
		Provider: ProviderClaude, Label: "Work", Method: MethodClaudeCode,
		Identity:         &ProviderIdentity{Email: "alice@example.com", OrganizationID: "org_1", Plan: "max"},
		IncludeInSummary: true, CreatedAt: "2026-11-14T10:00:00Z", CreatedBy: "d_mini_1",
	}
	if err := ValidateKV(providerKV(t, ProviderAccountsNamespace, testAccountID, account)); err != nil {
		t.Fatalf("valid account rejected: %v", err)
	}
	siwc := account
	siwc.Provider, siwc.Method, siwc.SIWC = ProviderChatGPT, MethodSIWC, &ProviderSIWC{ClientID: "oaiapp_123"}
	if err := ValidateKV(providerKV(t, ProviderAccountsNamespace, testAccountID, siwc)); err != nil {
		t.Fatalf("valid SIWC account rejected: %v", err)
	}
	for name, mutate := range map[string]func(*ProviderAccountRecord){
		"provider":      func(a *ProviderAccountRecord) { a.Provider = "gemini" },
		"method":        func(a *ProviderAccountRecord) { a.Method = MethodCodex },
		"siwc claude":   func(a *ProviderAccountRecord) { a.Method = MethodSIWC },
		"empty label":   func(a *ProviderAccountRecord) { a.Label = "  " },
		"long label":    func(a *ProviderAccountRecord) { a.Label = strings.Repeat("é", 61) },
		"newline label": func(a *ProviderAccountRecord) { a.Label = "Work\nPersonal" },
		"siwc client":   func(a *ProviderAccountRecord) { a.SIWC = &ProviderSIWC{ClientID: "oaiapp_1"} },
		"identity":      func(a *ProviderAccountRecord) { a.Identity = &ProviderIdentity{Email: strings.Repeat("a", 300)} },
		"created":       func(a *ProviderAccountRecord) { a.CreatedAt = "yesterday" },
		"creator":       func(a *ProviderAccountRecord) { a.CreatedBy = "d.mini" },
	} {
		changed := account
		mutate(&changed)
		if err := ValidateKV(providerKV(t, ProviderAccountsNamespace, testAccountID, changed)); err == nil {
			t.Errorf("%s: invalid account accepted", name)
		}
	}
	if ValidateKV(providerKV(t, ProviderAccountsNamespace, "pa_short", account)) == nil {
		t.Error("invalid account key accepted")
	}
	if ValidateKV(providerKV(t, ProviderAccountsNamespace, "pa_ABCDEFGHIJKLMNOPQRSTUVWXYZ", account)) == nil {
		t.Error("uppercase account key accepted")
	}
	if ValidateKV(providerKV(t, ProviderAccountsNamespace, testAccountID, []byte(`{"provider":"claude","label":"Work","method":"claude-code","includeInSummary":true,"createdAt":"2026-11-14T10:00:00Z","createdBy":"d","token":"secret"}`))) == nil {
		t.Error("unknown field accepted")
	}
	deleted := crdt.Record{Kind: KVKindPrefix + ProviderAccountsNamespace, ID: testAccountID, Versions: []crdt.Version{{Clock: crdt.Clock{"a": 2}, Deleted: true}}}
	if err := ValidateKV(deleted); err != nil {
		t.Fatalf("tombstone rejected: %v", err)
	}
}

func TestProviderMethodRules(t *testing.T) {
	t.Parallel()
	allowed := map[string][]string{
		ProviderClaude:  {MethodClaudeCode, MethodHost, MethodEnvironment},
		ProviderChatGPT: {MethodCodex, MethodSIWC, MethodHost, MethodEnvironment},
	}
	for provider, methods := range allowed {
		for _, method := range []string{MethodClaudeCode, MethodCodex, MethodSIWC, MethodHost, MethodEnvironment, "api"} {
			want := false
			for _, m := range methods {
				want = want || m == method
			}
			if got := ProviderMethodAllowed(provider, method); got != want {
				t.Errorf("%s/%s = %v, want %v", provider, method, got, want)
			}
		}
	}
	if ProviderMethodAllowed("gemini", MethodHost) {
		t.Error("unknown provider accepted")
	}
}

func TestProviderDefaultRecords(t *testing.T) {
	t.Parallel()
	if err := ValidateKV(providerKV(t, ProviderDefaultsNamespace, ProviderChatGPT, ProviderDefaultRecord{AccountID: testAccountID})); err != nil {
		t.Fatalf("valid default rejected: %v", err)
	}
	if ValidateKV(providerKV(t, ProviderDefaultsNamespace, "gemini", ProviderDefaultRecord{AccountID: testAccountID})) == nil {
		t.Error("unknown provider key accepted")
	}
	if ValidateKV(providerKV(t, ProviderDefaultsNamespace, ProviderClaude, ProviderDefaultRecord{AccountID: "work"})) == nil {
		t.Error("invalid account ID accepted")
	}
}

func TestProviderLoginRecordsAreBounded(t *testing.T) {
	t.Parallel()
	key := ProviderLoginKey(testAccountID, "d_mini_1")
	account, daemon, ok := ParseProviderLoginKey(key)
	if !ok || account != testAccountID || daemon != "d_mini_1" {
		t.Fatalf("parse %q = %q %q %v", key, account, daemon, ok)
	}
	for _, bad := range []string{testAccountID, testAccountID + ".", "pa_x.d1", testAccountID + ".d.1"} {
		if _, _, ok := ParseProviderLoginKey(bad); ok {
			t.Errorf("key %q parsed", bad)
		}
	}
	login := ProviderLoginRecord{
		State: LoginSignedIn, Method: MethodClaudeCode,
		Identity:   &ProviderIdentity{Email: "alice@example.com"},
		VerifiedAt: "2026-11-14T10:00:00Z",
		Usage: &ProviderUsage{
			Plan: "max", ObservedAt: "2026-11-14T10:00:00Z", Source: "probe",
			Windows: []ProviderUsageWindow{{Kind: "five_hour", Label: "5h", UsedPercent: 12.5, ResetsAt: "2026-11-14T12:00:00Z", DurationMinutes: 300}},
			Credits: &ProviderCredits{Balance: "12.00"}, Spend: &ProviderSpend{Used: 1.5, Limit: 50, Currency: "USD"},
			ResetCredits: &ProviderResetCredits{Available: 1},
		},
		DieterTokens: &ProviderTokenUsage{FiveHour: ProviderTokenTotals{Input: 1, Output: 2, Total: 3}, ObservedAt: "2026-11-14T10:00:00Z"},
	}
	if err := ValidateKV(providerKV(t, ProviderLoginsNamespace, key, login)); err != nil {
		t.Fatalf("valid login rejected: %v", err)
	}
	failed := ProviderLoginRecord{State: LoginFailed, Method: MethodCodex, Error: &ProviderLoginError{Code: "identity_mismatch", Message: "signed in as bob@example.com"}}
	if err := ValidateKV(providerKV(t, ProviderLoginsNamespace, key, failed)); err != nil {
		t.Fatalf("valid failed login rejected: %v", err)
	}
	clone := func() ProviderLoginRecord {
		raw, _ := json.Marshal(login)
		var copied ProviderLoginRecord
		_ = json.Unmarshal(raw, &copied)
		return copied
	}
	for name, mutate := range map[string]func(*ProviderLoginRecord){
		"state":       func(l *ProviderLoginRecord) { l.State = "maybe" },
		"method":      func(l *ProviderLoginRecord) { l.Method = "api" },
		"verified":    func(l *ProviderLoginRecord) { l.VerifiedAt = "now" },
		"error code":  func(l *ProviderLoginRecord) { l.Error = &ProviderLoginError{Code: "Identity Mismatch"} },
		"observed":    func(l *ProviderLoginRecord) { l.Usage.ObservedAt = "" },
		"source":      func(l *ProviderLoginRecord) { l.Usage.Source = "guess" },
		"unavailable": func(l *ProviderLoginRecord) { l.Usage.Unavailable = "broken" },
		"kind":        func(l *ProviderLoginRecord) { l.Usage.Windows[0].Kind = "daily" },
		"percent":     func(l *ProviderLoginRecord) { l.Usage.Windows[0].UsedPercent = 101 },
		"negative":    func(l *ProviderLoginRecord) { l.Usage.Windows[0].UsedPercent = -1 },
		"resets":      func(l *ProviderLoginRecord) { l.Usage.Windows[0].ResetsAt = "soon" },
		"spend":       func(l *ProviderLoginRecord) { l.Usage.Spend.Used = -2 },
		"credits":     func(l *ProviderLoginRecord) { l.Usage.ResetCredits.Available = -1 },
		"tokens":      func(l *ProviderLoginRecord) { l.DieterTokens.SevenDay.Total = -1 },
		"windows": func(l *ProviderLoginRecord) {
			for len(l.Usage.Windows) <= ProviderUsageWindows {
				l.Usage.Windows = append(l.Usage.Windows, l.Usage.Windows[0])
			}
		},
	} {
		changed := clone()
		mutate(&changed)
		if err := ValidateKV(providerKV(t, ProviderLoginsNamespace, key, changed)); err == nil {
			t.Errorf("%s: invalid login accepted", name)
		}
	}
	// A value that is otherwise valid but larger than 8 KiB.
	raw := []byte(`{"state":"signed_out","method":"host"` + strings.Repeat(" ", ProviderValueBytes) + `}`)
	if err := ValidateKV(providerKV(t, ProviderLoginsNamespace, key, []byte(`{"state":"signed_out","method":"host"}`))); err != nil {
		t.Fatalf("small login rejected: %v", err)
	}
	if err := ValidateKV(providerKV(t, ProviderLoginsNamespace, key, raw)); err == nil || !strings.Contains(err.Error(), "8 KiB") {
		t.Fatalf("oversized login accepted or misreported: %v", err)
	}
}
