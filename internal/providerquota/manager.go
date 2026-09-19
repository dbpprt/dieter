package providerquota

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"google.golang.org/protobuf/proto"
)

const (
	maxAccounts        = 8
	maxProbeOutput     = 64 << 10
	probeCacheDuration = time.Minute
)

type Manager struct {
	runner *harness.SubprocessRunner
	logger *slog.Logger
	now    func() time.Time

	mu      sync.Mutex
	handles map[string]accountHandle
}

type accountHandle struct {
	profileRoot     string
	stableAccountID string
	lastProbe       probeResult
	probedAt        time.Time
}

type probeWindow struct {
	ID               string  `json:"id"`
	Label            string  `json:"label"`
	Kind             string  `json:"kind"`
	UsedPercent      *uint32 `json:"usedPercent"`
	RemainingPercent *uint32 `json:"remainingPercent"`
	DurationMinutes  *uint32 `json:"durationMinutes"`
	ResetsAt         string  `json:"resetsAt"`
}

type probeCredits struct {
	Balance    string `json:"balance"`
	HasCredits bool   `json:"hasCredits"`
	Unlimited  bool   `json:"unlimited"`
}

type probeSpendAllowance struct {
	Used             string  `json:"used"`
	Limit            string  `json:"limit"`
	Currency         string  `json:"currency"`
	RemainingPercent *uint32 `json:"remainingPercent"`
	ResetsAt         string  `json:"resetsAt"`
}

type probeResetCredit struct {
	Title     string `json:"title"`
	Kind      string `json:"kind"`
	Status    string `json:"status"`
	GrantedAt string `json:"grantedAt"`
	ExpiresAt string `json:"expiresAt"`
}

type probeResetCredits struct {
	AvailableCount uint32             `json:"availableCount"`
	Details        []probeResetCredit `json:"details"`
}

type probeResult struct {
	StableAccountID      string               `json:"stableAccountID"`
	DisplayEmail         string               `json:"displayEmail"`
	AccountKind          string               `json:"accountKind"`
	Plan                 string               `json:"plan"`
	Availability         string               `json:"availability"`
	Windows              []probeWindow        `json:"windows"`
	Credits              *probeCredits        `json:"credits"`
	SpendAllowance       *probeSpendAllowance `json:"spendAllowance"`
	ResetCredits         *probeResetCredits   `json:"resetCredits"`
	OrdinaryUsageAllowed *bool                `json:"ordinaryUsageAllowed"`
	ResetOutcome         string               `json:"resetOutcome"`
}

func New(root string, logger *slog.Logger) *Manager {
	if logger == nil {
		logger = slog.Default()
	}
	return &Manager{runner: harness.NewSubprocessRunner(root), logger: logger, now: time.Now, handles: map[string]accountHandle{}}
}

func (m *Manager) Discover(ctx context.Context, correlationKey []byte) (*gatewayv1.ProviderAccountsPresence, error) {
	if len(correlationKey) != 32 {
		return nil, errors.New("provider account correlation key is invalid")
	}
	profiles, err := configuredCodexProfiles()
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	previousHandles := make(map[string]accountHandle, len(m.handles))
	for key, handle := range m.handles {
		previousHandles[key] = handle
	}
	m.mu.Unlock()
	type discoveredProfile struct {
		root   string
		result probeResult
		err    error
	}
	jobs := make(chan string, len(profiles))
	results := make(chan discoveredProfile, len(profiles))
	for _, profileRoot := range profiles {
		jobs <- profileRoot
	}
	close(jobs)
	workerCount := min(2, len(profiles))
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for range workerCount {
		go func() {
			defer workers.Done()
			for profileRoot := range jobs {
				result, err := m.probe(ctx, profileRoot)
				results <- discoveredProfile{root: profileRoot, result: result, err: err}
			}
		}()
	}
	go func() {
		workers.Wait()
		close(results)
	}()
	presence := &gatewayv1.ProviderAccountsPresence{}
	nextHandles := map[string]accountHandle{}
	for discovered := range results {
		if discovered.err != nil {
			m.logger.Warn("OpenAI quota profile is temporarily unavailable")
			for accountKey, handle := range previousHandles {
				if handle.profileRoot != discovered.root {
					continue
				}
				nextHandles[accountKey] = handle
				presence.Accounts = append(presence.Accounts, &gatewayv1.ProviderAccountPresence{
					Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: accountKey,
					AccountKind: accountKind(handle.lastProbe.AccountKind), Plan: bounded(handle.lastProbe.Plan, 128),
					Availability:     gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE,
					RefreshSupported: true,
				})
			}
			continue
		}
		result, profileRoot := discovered.result, discovered.root
		if result.StableAccountID == "" {
			continue
		}
		accountKey := correlateAccount(correlationKey, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, result.StableAccountID)
		if _, duplicate := nextHandles[accountKey]; duplicate {
			continue
		}
		nextHandles[accountKey] = accountHandle{profileRoot: profileRoot, stableAccountID: result.StableAccountID, lastProbe: result, probedAt: m.now().UTC()}
		presence.Accounts = append(presence.Accounts, &gatewayv1.ProviderAccountPresence{
			Provider:   gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
			AccountKey: accountKey, AccountKind: accountKind(result.AccountKind), Plan: bounded(result.Plan, 128),
			Availability: availability(result.Availability), RefreshSupported: true,
		})
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	sort.Slice(presence.Accounts, func(i, j int) bool {
		return presence.Accounts[i].GetAccountKey() < presence.Accounts[j].GetAccountKey()
	})
	m.mu.Lock()
	m.handles = nextHandles
	m.mu.Unlock()
	return presence, nil
}

func (m *Manager) Refresh(ctx context.Context, correlationKey []byte, request *gatewayv1.ProviderQuotaRefreshRequest) (*gatewayv1.ProviderQuotaRefreshResult, error) {
	if len(correlationKey) != 32 || request == nil || request.GetProvider() != gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX {
		return nil, errors.New("provider quota refresh request is invalid")
	}
	m.mu.Lock()
	handle, exists := m.handles[request.GetAccountKey()]
	m.mu.Unlock()
	if !exists {
		return &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "account_not_found"}, nil
	}
	result := handle.lastProbe
	probed := false
	if handle.probedAt.IsZero() || m.now().Sub(handle.probedAt) > probeCacheDuration {
		var err error
		result, err = m.probe(ctx, handle.profileRoot)
		if err != nil {
			return &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "temporarily_unavailable"}, nil
		}
		probed = true
	}
	if result.StableAccountID == "" || result.StableAccountID != handle.stableAccountID ||
		correlateAccount(correlationKey, request.GetProvider(), result.StableAccountID) != request.GetAccountKey() {
		return &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "identity_mismatch"}, nil
	}
	if probed {
		m.mu.Lock()
		if current, ok := m.handles[request.GetAccountKey()]; ok && current.stableAccountID == handle.stableAccountID {
			current.lastProbe = result
			current.probedAt = m.now().UTC()
			m.handles[request.GetAccountKey()] = current
		}
		m.mu.Unlock()
	}
	snapshot := normalizeSnapshot(request.GetAccountKey(), result, m.now().UTC())
	return &gatewayv1.ProviderQuotaRefreshResult{Snapshot: snapshot}, nil
}

func (m *Manager) ConsumeReset(ctx context.Context, correlationKey []byte, request *gatewayv1.ProviderQuotaResetRequest) (*gatewayv1.ProviderQuotaResetResult, error) {
	if len(correlationKey) != 32 || request == nil || request.GetProvider() != gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX ||
		!validIdempotencyKey(request.GetIdempotencyKey()) {
		return nil, errors.New("provider quota reset request is invalid")
	}
	m.mu.Lock()
	handle, exists := m.handles[request.GetAccountKey()]
	m.mu.Unlock()
	if !exists {
		return &gatewayv1.ProviderQuotaResetResult{ErrorCode: "account_not_found"}, nil
	}
	result, err := m.runProbe(ctx, handle.profileRoot, "consume_reset", request.GetIdempotencyKey(), handle.stableAccountID)
	if err != nil {
		return &gatewayv1.ProviderQuotaResetResult{ErrorCode: "temporarily_unavailable"}, nil
	}
	if result.StableAccountID == "" || result.StableAccountID != handle.stableAccountID ||
		correlateAccount(correlationKey, request.GetProvider(), result.StableAccountID) != request.GetAccountKey() {
		return &gatewayv1.ProviderQuotaResetResult{ErrorCode: "identity_mismatch"}, nil
	}
	switch result.ResetOutcome {
	case "reset", "nothingToReset", "noCredit", "alreadyRedeemed":
	default:
		return &gatewayv1.ProviderQuotaResetResult{ErrorCode: "invalid_reset_outcome"}, nil
	}
	m.mu.Lock()
	if current, ok := m.handles[request.GetAccountKey()]; ok && current.stableAccountID == handle.stableAccountID {
		current.lastProbe = result
		current.probedAt = m.now().UTC()
		m.handles[request.GetAccountKey()] = current
	}
	m.mu.Unlock()
	return &gatewayv1.ProviderQuotaResetResult{
		Snapshot: normalizeSnapshot(request.GetAccountKey(), result, m.now().UTC()),
		Outcome:  result.ResetOutcome,
	}, nil
}

func correlateAccount(key []byte, provider gatewayv1.ProviderQuotaProvider, stableID string) string {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(provider.String()))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(stableID))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func configuredCodexProfiles() ([]string, error) {
	var candidates []string
	if configured := strings.TrimSpace(os.Getenv("DIETER_CODEX_ACCOUNT_HOMES")); configured != "" {
		for _, value := range filepath.SplitList(configured) {
			if value = strings.TrimSpace(value); value != "" {
				candidates = append(candidates, value)
			}
		}
	}
	if current := strings.TrimSpace(os.Getenv("CODEX_HOME")); current != "" {
		candidates = append(candidates, current)
	}
	if len(candidates) == 0 {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		candidates = append(candidates, filepath.Join(home, ".codex"))
	}
	seen := map[string]struct{}{}
	profiles := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		absolute, err := filepath.Abs(candidate)
		if err != nil {
			return nil, err
		}
		if _, duplicate := seen[absolute]; duplicate {
			continue
		}
		seen[absolute] = struct{}{}
		info, err := os.Stat(absolute)
		if err != nil || !info.IsDir() {
			continue
		}
		profiles = append(profiles, absolute)
		if len(profiles) == maxAccounts {
			break
		}
	}
	return profiles, nil
}

type cappedBuffer struct {
	buffer   bytes.Buffer
	exceeded bool
}

func (w *cappedBuffer) Write(value []byte) (int, error) {
	remaining := maxProbeOutput - w.buffer.Len()
	if remaining > 0 {
		kept := value
		if len(kept) > remaining {
			kept = kept[:remaining]
		}
		_, _ = w.buffer.Write(kept)
	}
	if len(value) > remaining {
		w.exceeded = true
	}
	return len(value), nil
}

func (m *Manager) probe(ctx context.Context, profileRoot string) (probeResult, error) {
	return m.runProbe(ctx, profileRoot, "read", "", "")
}

func (m *Manager) runProbe(ctx context.Context, profileRoot, action, idempotencyKey, expectedAccountID string) (probeResult, error) {
	var result probeResult
	runtimeDirectory, err := m.runner.RuntimeDirectory(ctx)
	if err != nil {
		return result, err
	}
	command := exec.CommandContext(ctx, "node", filepath.Join(runtimeDirectory, "quota-openai.mjs"))
	command.Dir = runtimeDirectory
	command.WaitDelay = 2 * time.Second
	command.Env = environmentWithCodexHome(os.Environ(), profileRoot)
	command.Env = append(command.Env, "DIETER_QUOTA_ACTION="+action)
	if idempotencyKey != "" {
		command.Env = append(command.Env, "DIETER_QUOTA_IDEMPOTENCY_KEY="+idempotencyKey)
	}
	if expectedAccountID != "" {
		command.Env = append(command.Env, "DIETER_QUOTA_EXPECTED_ACCOUNT_ID="+expectedAccountID)
	}
	var output cappedBuffer
	command.Stdout, command.Stderr = &output, io.Discard
	if err := command.Run(); err != nil {
		return result, errors.New("OpenAI quota probe failed")
	}
	if output.exceeded {
		return result, errors.New("OpenAI quota probe output exceeded 64 KiB")
	}
	if err := json.Unmarshal(bytes.TrimSpace(output.buffer.Bytes()), &result); err != nil {
		return result, errors.New("OpenAI quota probe returned invalid data")
	}
	return result, nil
}

func validIdempotencyKey(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f') || (character >= 'A' && character <= 'F')) {
			return false
		}
	}
	return true
}

func environmentWithCodexHome(environment []string, profileRoot string) []string {
	result := make([]string, 0, len(environment)+1)
	for _, value := range environment {
		if strings.EqualFold(strings.SplitN(value, "=", 2)[0], "CODEX_HOME") {
			continue
		}
		result = append(result, value)
	}
	return append(result, "CODEX_HOME="+profileRoot)
}

func accountKind(value string) gatewayv1.ProviderAccountKind {
	if value == "api" {
		return gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_API
	}
	return gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION
}

func availability(value string) gatewayv1.ProviderQuotaAvailability {
	switch value {
	case "signed_out":
		return gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT
	case "unsupported":
		return gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_UNSUPPORTED
	case "permission_denied":
		return gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_PERMISSION_DENIED
	case "temporarily_unavailable":
		return gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE
	default:
		return gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE
	}
}

func windowKind(value string) gatewayv1.ProviderQuotaWindowKind {
	switch value {
	case "five_hour":
		return gatewayv1.ProviderQuotaWindowKind_PROVIDER_QUOTA_WINDOW_KIND_FIVE_HOUR
	case "weekly":
		return gatewayv1.ProviderQuotaWindowKind_PROVIDER_QUOTA_WINDOW_KIND_WEEKLY
	case "monthly":
		return gatewayv1.ProviderQuotaWindowKind_PROVIDER_QUOTA_WINDOW_KIND_MONTHLY
	case "model":
		return gatewayv1.ProviderQuotaWindowKind_PROVIDER_QUOTA_WINDOW_KIND_MODEL
	default:
		return gatewayv1.ProviderQuotaWindowKind_PROVIDER_QUOTA_WINDOW_KIND_OTHER
	}
}

func normalizeSnapshot(accountKey string, result probeResult, now time.Time) *gatewayv1.ProviderQuotaSnapshot {
	snapshot := &gatewayv1.ProviderQuotaSnapshot{
		Provider:   gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		AccountKey: accountKey, AccountKind: accountKind(result.AccountKind), Plan: bounded(result.Plan, 128),
		DisplayEmail: bounded(result.DisplayEmail, 320),
		Availability: availability(result.Availability), RefreshState: gatewayv1.ProviderQuotaRefreshState_PROVIDER_QUOTA_REFRESH_STATE_IDLE,
	}
	var earliest time.Time
	for _, value := range result.Windows {
		window := &gatewayv1.ProviderQuotaWindow{
			Id: bounded(value.ID, 128), Label: bounded(value.Label, 128), Kind: windowKind(value.Kind),
			UsedPercent: value.UsedPercent, RemainingPercent: value.RemainingPercent, DurationMinutes: value.DurationMinutes,
			ResetsAt: value.ResetsAt,
		}
		if window.UsedPercent != nil && window.RemainingPercent == nil && window.GetUsedPercent() <= 100 {
			window.RemainingPercent = proto.Uint32(100 - window.GetUsedPercent())
		}
		if reset, err := time.Parse(time.RFC3339Nano, window.GetResetsAt()); err == nil && reset.After(now) && (earliest.IsZero() || reset.Before(earliest)) {
			earliest, snapshot.NextResetAt, snapshot.NextResetWindowId = reset, reset.Format(time.RFC3339Nano), window.GetId()
		}
		snapshot.Windows = append(snapshot.Windows, window)
	}
	if result.Credits != nil {
		snapshot.Credits = &gatewayv1.ProviderCreditBalance{
			Balance: bounded(result.Credits.Balance, 128), HasCredits: proto.Bool(result.Credits.HasCredits), Unlimited: result.Credits.Unlimited,
		}
	}
	if result.SpendAllowance != nil {
		snapshot.SpendAllowance = &gatewayv1.ProviderSpendAllowance{
			Used: bounded(result.SpendAllowance.Used, 128), Limit: bounded(result.SpendAllowance.Limit, 128),
			Currency: bounded(result.SpendAllowance.Currency, 16), RemainingPercent: result.SpendAllowance.RemainingPercent,
			ResetsAt: result.SpendAllowance.ResetsAt,
		}
	}
	if result.ResetCredits != nil {
		snapshot.ResetCredits = &gatewayv1.ProviderResetCredits{AvailableCount: result.ResetCredits.AvailableCount}
		for _, detail := range result.ResetCredits.Details {
			snapshot.ResetCredits.Details = append(snapshot.ResetCredits.Details, &gatewayv1.ProviderResetCredit{
				Title: bounded(detail.Title, 128), Kind: bounded(detail.Kind, 128), Status: bounded(detail.Status, 128),
				GrantedAt: detail.GrantedAt, ExpiresAt: detail.ExpiresAt,
			})
		}
	}
	snapshot.OrdinaryUsageAllowed = result.OrdinaryUsageAllowed
	return snapshot
}

func bounded(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}
	for len(value) > limit {
		_, size := utf8.DecodeLastRuneInString(value)
		if size == 0 {
			return ""
		}
		value = value[:len(value)-size]
	}
	return value
}
