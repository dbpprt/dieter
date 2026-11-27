package schema

import (
	"bytes"
	"encoding/json"
	"math"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Provider accounts replicate as KV records in these namespaces. Credentials
// never enter them: every client and peer can read KV records. Only daemons
// write them (the public KV API and generic peer writes refuse), and values are
// validated on write and on ingest.
const (
	// ProviderAccountsNamespace holds one record per account: key pa_<26 base32>.
	// Any daemon writes it with compare-and-set; deletion is a tombstone.
	ProviderAccountsNamespace = "provider-accounts"
	// ProviderDefaultsNamespace holds each provider's default account: key
	// claude or chatgpt.
	ProviderDefaultsNamespace = "provider-account-defaults"
	// ProviderLoginsNamespace holds one machine's login state and observed
	// usage of an account: key <accountId>.<daemonId>, written only by that
	// daemon.
	ProviderLoginsNamespace = "provider-logins"
)

// Providers, login methods and login states.
const (
	ProviderClaude  = "claude"
	ProviderChatGPT = "chatgpt"

	MethodClaudeCode  = "claude-code"
	MethodCodex       = "codex"
	MethodSIWC        = "siwc"
	MethodHost        = "host"
	MethodEnvironment = "environment"

	LoginSignedIn  = "signed_in"
	LoginSignedOut = "signed_out"
	LoginExpired   = "expired"
	LoginFailed    = "failed"
)

// Provider record bounds.
const (
	ProviderUsageWindows   = 16
	ProviderValueBytes     = 8 << 10
	ProviderLabelRunes     = 60
	providerAccountIDChars = 26
	providerTextBytes      = 256
	providerMessageBytes   = 512
	providerTokenBytes     = 64
	providerClientIDBytes  = 128
)

// ProviderIdentity is who a provider login belongs to. The account record
// binds it at the first verified sign-in; login records carry what each
// machine verified.
type ProviderIdentity struct {
	Email          string `json:"email,omitempty"`
	Organization   string `json:"organization,omitempty"`
	OrganizationID string `json:"organizationId,omitempty"`
	WorkspaceID    string `json:"workspaceId,omitempty"`
	Subject        string `json:"subject,omitempty"`
	Plan           string `json:"plan,omitempty"`
}

// Empty reports whether no identity field is set.
func (i ProviderIdentity) Empty() bool { return i == ProviderIdentity{} }

// ProviderSIWC is a Sign in with ChatGPT account's issued public client ID.
type ProviderSIWC struct {
	ClientID string `json:"clientId"`
}

// ProviderAccountRecord is one replicated account.
type ProviderAccountRecord struct {
	Provider         string            `json:"provider"`
	Label            string            `json:"label"`
	Method           string            `json:"method"`
	Identity         *ProviderIdentity `json:"identity,omitempty"`
	IncludeInSummary bool              `json:"includeInSummary"`
	// OMPAccess lets Oh My Pi turns use a Claude login (Claude only).
	OMPAccess bool          `json:"ompAccess,omitempty"`
	SIWC      *ProviderSIWC `json:"siwc,omitempty"`
	CreatedAt string        `json:"createdAt"`
	CreatedBy string        `json:"createdBy"`
}

// ProviderDefaultRecord names a provider's default account.
type ProviderDefaultRecord struct {
	AccountID string `json:"accountId"`
}

// ProviderLoginError is why a machine's login is not usable.
type ProviderLoginError struct {
	Code    string `json:"code"`
	Message string `json:"message,omitempty"`
}

// ProviderUsageWindow is one plan limit window.
type ProviderUsageWindow struct {
	Kind            string  `json:"kind"`
	Label           string  `json:"label,omitempty"`
	UsedPercent     float64 `json:"usedPercent"`
	ResetsAt        string  `json:"resetsAt,omitempty"`
	DurationMinutes int     `json:"durationMinutes,omitempty"`
}

// ProviderCredits is a ChatGPT credit balance.
type ProviderCredits struct {
	Balance   string `json:"balance,omitempty"`
	Unlimited bool   `json:"unlimited,omitempty"`
}

// ProviderSpend is extra-usage spend in currency units.
type ProviderSpend struct {
	Used     float64 `json:"used"`
	Limit    float64 `json:"limit"`
	Currency string  `json:"currency,omitempty"`
}

// ProviderResetCredits counts ChatGPT rate-limit reset credits.
type ProviderResetCredits struct {
	Available int `json:"available"`
}

// ProviderUsage is the newest provider-reported plan usage a machine saw.
type ProviderUsage struct {
	Plan         string                `json:"plan,omitempty"`
	ObservedAt   string                `json:"observedAt"`
	Source       string                `json:"source,omitempty"`
	Windows      []ProviderUsageWindow `json:"windows,omitempty"`
	Credits      *ProviderCredits      `json:"credits,omitempty"`
	Spend        *ProviderSpend        `json:"spend,omitempty"`
	ResetCredits *ProviderResetCredits `json:"resetCredits,omitempty"`
	Unavailable  string                `json:"unavailable,omitempty"`
}

// ProviderTokenTotals sums tokens of Dieter's own turns.
type ProviderTokenTotals struct {
	Input  int64 `json:"input"`
	Output int64 `json:"output"`
	Total  int64 `json:"total"`
}

// ProviderTokenUsage is a machine's rolling token sums on an account.
type ProviderTokenUsage struct {
	FiveHour   ProviderTokenTotals `json:"fiveHour"`
	SevenDay   ProviderTokenTotals `json:"sevenDay"`
	ObservedAt string              `json:"observedAt"`
}

// ProviderLoginRecord is one machine's login of an account.
type ProviderLoginRecord struct {
	State        string              `json:"state"`
	Method       string              `json:"method"`
	Identity     *ProviderIdentity   `json:"identity,omitempty"`
	VerifiedAt   string              `json:"verifiedAt,omitempty"`
	Error        *ProviderLoginError `json:"error,omitempty"`
	Usage        *ProviderUsage      `json:"usage,omitempty"`
	DieterTokens *ProviderTokenUsage `json:"dieterTokens,omitempty"`
}

// ProviderNamespaceKind reports whether ns is one of the provider namespaces.
func ProviderNamespaceKind(ns string) bool {
	switch ns {
	case ProviderAccountsNamespace, ProviderDefaultsNamespace, ProviderLoginsNamespace:
		return true
	}
	return false
}

// ValidProviderAccountID reports whether id is pa_ followed by 26 lowercase
// base32 characters.
func ValidProviderAccountID(id string) bool {
	rest, ok := strings.CutPrefix(id, "pa_")
	if !ok || len(rest) != providerAccountIDChars {
		return false
	}
	for _, c := range rest {
		if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
			return false
		}
	}
	return true
}

// ValidProvider reports whether provider is claude or chatgpt.
func ValidProvider(provider string) bool {
	return provider == ProviderClaude || provider == ProviderChatGPT
}

// ProviderMethodAllowed reports whether method is a login method of provider.
func ProviderMethodAllowed(provider, method string) bool {
	switch method {
	case MethodHost, MethodEnvironment:
		return ValidProvider(provider)
	case MethodClaudeCode:
		return provider == ProviderClaude
	case MethodCodex, MethodSIWC:
		return provider == ProviderChatGPT
	}
	return false
}

func validProviderMethod(method string) bool {
	switch method {
	case MethodClaudeCode, MethodCodex, MethodSIWC, MethodHost, MethodEnvironment:
		return true
	}
	return false
}

// ProviderLoginKey is the key of a machine's login record of an account.
func ProviderLoginKey(accountID, daemonID string) string { return accountID + "." + daemonID }

// ParseProviderLoginKey splits a login record key into its account and
// daemon. Account IDs and daemon IDs never contain dots.
func ParseProviderLoginKey(key string) (accountID, daemonID string, ok bool) {
	accountID, daemonID, found := strings.Cut(key, ".")
	if !found || !ValidProviderAccountID(accountID) || !channelID(daemonID) {
		return "", "", false
	}
	return accountID, daemonID, true
}

// ValidProviderLabel reports whether label is 1–60 runes on one line.
func ValidProviderLabel(label string) bool {
	if strings.TrimSpace(label) == "" || utf8.RuneCountInString(label) > ProviderLabelRunes || !utf8.ValidString(label) {
		return false
	}
	for _, c := range label {
		if unicode.IsControl(c) {
			return false
		}
	}
	return true
}

// DecodeProviderAccount decodes and validates an account record stored at key.
func DecodeProviderAccount(key string, raw []byte) (ProviderAccountRecord, error) {
	var value ProviderAccountRecord
	if err := providerJSON(raw, &value); err != nil {
		return value, err
	}
	if !ValidProviderAccountID(key) {
		return value, fault.New(fault.Invalid, "invalid provider account ID")
	}
	if !ValidProvider(value.Provider) || !ProviderMethodAllowed(value.Provider, value.Method) {
		return value, fault.New(fault.Invalid, "invalid provider account provider or method")
	}
	if !ValidProviderLabel(value.Label) {
		return value, fault.New(fault.Invalid, "a provider account label is 1 to 60 characters on one line")
	}
	if value.Identity != nil && !validProviderIdentity(*value.Identity) {
		return value, fault.New(fault.Invalid, "invalid provider account identity")
	}
	if value.OMPAccess && value.Provider != ProviderClaude {
		return value, fault.New(fault.Invalid, "only Claude accounts have Oh My Pi access")
	}
	if value.SIWC != nil && (value.Method != MethodSIWC || !validClientID(value.SIWC.ClientID)) {
		return value, fault.New(fault.Invalid, "invalid Sign in with ChatGPT client")
	}
	if !channelTime(value.CreatedAt) || !channelID(value.CreatedBy) {
		return value, fault.New(fault.Invalid, "invalid provider account creation")
	}
	return value, nil
}

// DecodeProviderDefault decodes and validates a provider default record.
func DecodeProviderDefault(key string, raw []byte) (ProviderDefaultRecord, error) {
	var value ProviderDefaultRecord
	if err := providerJSON(raw, &value); err != nil {
		return value, err
	}
	if !ValidProvider(key) || !ValidProviderAccountID(value.AccountID) {
		return value, fault.New(fault.Invalid, "invalid provider default")
	}
	return value, nil
}

// DecodeProviderLogin decodes and validates a machine's login record.
func DecodeProviderLogin(key string, raw []byte) (ProviderLoginRecord, error) {
	var value ProviderLoginRecord
	if err := providerJSON(raw, &value); err != nil {
		return value, err
	}
	if _, _, ok := ParseProviderLoginKey(key); !ok {
		return value, fault.New(fault.Invalid, "invalid provider login key")
	}
	switch value.State {
	case LoginSignedIn, LoginSignedOut, LoginExpired, LoginFailed:
	default:
		return value, fault.New(fault.Invalid, "invalid provider login state")
	}
	if !validProviderMethod(value.Method) {
		return value, fault.New(fault.Invalid, "invalid provider login method")
	}
	if value.Identity != nil && !validProviderIdentity(*value.Identity) {
		return value, fault.New(fault.Invalid, "invalid provider login identity")
	}
	if value.VerifiedAt != "" && !channelTime(value.VerifiedAt) {
		return value, fault.New(fault.Invalid, "invalid provider login verification time")
	}
	if value.Error != nil && (!providerToken(value.Error.Code) || !providerText(value.Error.Message, providerMessageBytes)) {
		return value, fault.New(fault.Invalid, "invalid provider login error")
	}
	if value.Usage != nil {
		if err := validateProviderUsage(*value.Usage); err != nil {
			return value, err
		}
	}
	if tokens := value.DieterTokens; tokens != nil {
		if !channelTime(tokens.ObservedAt) || !validTokenTotals(tokens.FiveHour) || !validTokenTotals(tokens.SevenDay) {
			return value, fault.New(fault.Invalid, "invalid provider token usage")
		}
	}
	return value, nil
}

func validateProviderUsage(usage ProviderUsage) error {
	if !channelTime(usage.ObservedAt) || !providerText(usage.Plan, providerTokenBytes) {
		return fault.New(fault.Invalid, "invalid provider usage")
	}
	switch usage.Source {
	case "", "probe", "turn":
	default:
		return fault.New(fault.Invalid, "invalid provider usage source")
	}
	switch usage.Unavailable {
	case "", "signed_out", "unsupported", "rate_limited", "plan_usage_not_granted":
	default:
		return fault.New(fault.Invalid, "invalid provider usage availability")
	}
	if len(usage.Windows) > ProviderUsageWindows {
		return fault.New(fault.Invalid, "too many provider usage windows")
	}
	for _, window := range usage.Windows {
		switch window.Kind {
		case "five_hour", "weekly", "model", "other":
		default:
			return fault.New(fault.Invalid, "invalid provider usage window kind")
		}
		if !providerText(window.Label, providerTokenBytes) || !finiteRange(window.UsedPercent, 0, 100) ||
			window.DurationMinutes < 0 || window.DurationMinutes > 1<<20 || (window.ResetsAt != "" && !channelTime(window.ResetsAt)) {
			return fault.New(fault.Invalid, "invalid provider usage window")
		}
	}
	if credits := usage.Credits; credits != nil && !providerText(credits.Balance, providerTokenBytes) {
		return fault.New(fault.Invalid, "invalid provider credits")
	}
	if spend := usage.Spend; spend != nil {
		if !finiteRange(spend.Used, 0, 1e12) || !finiteRange(spend.Limit, 0, 1e12) || len(spend.Currency) > 8 || !providerText(spend.Currency, 8) {
			return fault.New(fault.Invalid, "invalid provider spend")
		}
	}
	if reset := usage.ResetCredits; reset != nil && (reset.Available < 0 || reset.Available > 10000) {
		return fault.New(fault.Invalid, "invalid provider reset credits")
	}
	return nil
}

func validateProvider(ns, key string, raw []byte) error {
	if len(raw) > ProviderValueBytes {
		return fault.New(fault.Invalid, "provider record exceeds 8 KiB")
	}
	var err error
	switch ns {
	case ProviderAccountsNamespace:
		_, err = DecodeProviderAccount(key, raw)
	case ProviderDefaultsNamespace:
		_, err = DecodeProviderDefault(key, raw)
	case ProviderLoginsNamespace:
		_, err = DecodeProviderLogin(key, raw)
	}
	return err
}

func providerJSON(raw []byte, value any) error {
	if len(raw) > ProviderValueBytes {
		return fault.New(fault.Invalid, "provider record exceeds 8 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return fault.Invalidf("invalid provider record: %v", err)
	}
	return nil
}

func validProviderIdentity(identity ProviderIdentity) bool {
	for _, text := range []string{identity.Email, identity.Organization, identity.OrganizationID, identity.WorkspaceID, identity.Subject} {
		if !providerText(text, providerTextBytes) {
			return false
		}
	}
	return providerText(identity.Plan, providerTokenBytes)
}

func validClientID(value string) bool {
	if value == "" || len(value) > providerClientIDBytes {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

// providerToken is a short snake_case code such as identity_mismatch.
func providerToken(value string) bool {
	if value == "" || len(value) > providerTokenBytes {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

func providerText(value string, limit int) bool {
	if len(value) > limit || !utf8.ValidString(value) {
		return false
	}
	for _, c := range value {
		if unicode.IsControl(c) {
			return false
		}
	}
	return true
}

func finiteRange(value, low, high float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && value >= low && value <= high
}

func validTokenTotals(totals ProviderTokenTotals) bool {
	return totals.Input >= 0 && totals.Output >= 0 && totals.Total >= 0
}
