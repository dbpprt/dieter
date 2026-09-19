package gateway

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

const (
	providerQuotaCapability        = "provider_quota_v1"
	providerQuotaRefreshInterval   = time.Minute
	providerQuotaRequestTimeout    = 15 * time.Second
	providerQuotaScheduleTick      = time.Second
	maxProviderAccountsPerDaemon   = 8
	maxProviderQuotaWindows        = 16
	maxProviderResetCreditDetails  = 32
	maxProviderLabelBytes          = 128
	maxProviderStatusCodeBytes     = 64
	maxProviderQuotaFrameBytes     = 64 << 10
	maxConcurrentProviderRefreshes = 8
	maxProviderRefreshesPerDaemon  = 2
)

type pendingProviderRefresh struct {
	githubID   int64
	provider   gatewayv1.ProviderQuotaProvider
	accountKey string
	daemonID   string
	startedAt  time.Time
	failures   int
}

type QuotaManager struct {
	store  *Store
	hub    *Hub
	logger *slog.Logger
	now    func() time.Time

	revision atomic.Uint64
	changed  chan struct{}
	start    sync.Once

	mu        sync.Mutex
	pending   map[string]pendingProviderRefresh
	byAccount map[string]string
}

func NewQuotaManager(store *Store, hub *Hub, logger *slog.Logger) *QuotaManager {
	if logger == nil {
		logger = slog.Default()
	}
	return &QuotaManager{
		store: store, hub: hub, logger: logger, now: time.Now,
		changed: make(chan struct{}, 1), pending: map[string]pendingProviderRefresh{}, byAccount: map[string]string{},
	}
}

func (m *QuotaManager) Start(ctx context.Context) {
	m.start.Do(func() { go m.run(ctx) })
}

func (m *QuotaManager) run(ctx context.Context) {
	ticker := time.NewTicker(providerQuotaScheduleTick)
	defer ticker.Stop()
	m.schedule(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.expireRequests()
			m.schedule(ctx)
		}
	}
}

func (m *QuotaManager) Revision() uint64 { return m.revision.Load() }

func (m *QuotaManager) Changed() <-chan struct{} { return m.changed }

func (m *QuotaManager) signalChanged() {
	m.revision.Add(1)
	select {
	case m.changed <- struct{}{}:
	default:
	}
}

func providerAccountIndex(githubID int64, provider gatewayv1.ProviderQuotaProvider, accountKey string) string {
	return fmt.Sprintf("%d:%d:%s", githubID, provider, accountKey)
}

func validProvider(provider gatewayv1.ProviderQuotaProvider) bool {
	return provider == gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX ||
		provider == gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE
}

func validAvailability(value gatewayv1.ProviderQuotaAvailability) bool {
	return value >= gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE &&
		value <= gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_PERMISSION_DENIED
}

func validAccountKey(value string) bool {
	if len(value) < 32 || len(value) > 128 || !utf8.ValidString(value) {
		return false
	}
	for _, character := range value {
		if !((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '-' || character == '_') {
			return false
		}
	}
	return true
}

func validateProviderAccountPresence(account *gatewayv1.ProviderAccountPresence) error {
	if account == nil || !validProvider(account.GetProvider()) || !validAccountKey(account.GetAccountKey()) {
		return errors.New("provider account presence is invalid")
	}
	if account.GetAccountKind() < gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION ||
		account.GetAccountKind() > gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_API || !validAvailability(account.GetAvailability()) {
		return errors.New("provider account presence has an invalid state")
	}
	if len(account.GetPlan()) > maxProviderLabelBytes || !utf8.ValidString(account.GetPlan()) {
		return errors.New("provider account plan is invalid")
	}
	return nil
}

func validateProviderTimestamp(value string) bool {
	if value == "" {
		return true
	}
	_, err := time.Parse(time.RFC3339Nano, value)
	return err == nil
}

func validateProviderQuotaSnapshot(snapshot *gatewayv1.ProviderQuotaSnapshot) error {
	if snapshot == nil || !validProvider(snapshot.GetProvider()) || !validAccountKey(snapshot.GetAccountKey()) ||
		!validAvailability(snapshot.GetAvailability()) {
		return errors.New("provider quota snapshot identity is invalid")
	}
	if len(snapshot.GetPlan()) > maxProviderLabelBytes || !utf8.ValidString(snapshot.GetPlan()) || len(snapshot.GetWindows()) > maxProviderQuotaWindows {
		return errors.New("provider quota snapshot exceeds its bounds")
	}
	seen := map[string]struct{}{}
	for _, window := range snapshot.GetWindows() {
		if window == nil || strings.TrimSpace(window.GetId()) == "" || len(window.GetId()) > maxProviderLabelBytes ||
			len(window.GetLabel()) > maxProviderLabelBytes || !utf8.ValidString(window.GetLabel()) || !validateProviderTimestamp(window.GetResetsAt()) {
			return errors.New("provider quota window is invalid")
		}
		if _, exists := seen[window.GetId()]; exists {
			return errors.New("provider quota window IDs must be unique")
		}
		seen[window.GetId()] = struct{}{}
		if window.UsedPercent != nil && window.GetUsedPercent() > 100 || window.RemainingPercent != nil && window.GetRemainingPercent() > 100 {
			return errors.New("provider quota percentage is out of range")
		}
		if window.UsedPercent != nil && window.RemainingPercent != nil && window.GetUsedPercent()+window.GetRemainingPercent() != 100 {
			return errors.New("provider quota percentages are inconsistent")
		}
	}
	if credits := snapshot.GetResetCredits(); credits != nil && len(credits.GetDetails()) > maxProviderResetCreditDetails {
		return errors.New("provider reset-credit details exceed their bound")
	}
	for _, value := range []string{snapshot.GetNextResetAt(), snapshot.GetRefreshedAt(), snapshot.GetNextRefreshAt(), snapshot.GetFreshUntil(), snapshot.GetLastSuccessAt()} {
		if !validateProviderTimestamp(value) {
			return errors.New("provider quota snapshot has an invalid timestamp")
		}
	}
	if len(snapshot.GetStatusCode()) > maxProviderStatusCodeBytes {
		return errors.New("provider quota status code is too long")
	}
	return nil
}

func (m *QuotaManager) HandlePresence(record DaemonRecord, daemonID string, presence *gatewayv1.ProviderAccountsPresence) error {
	if presence == nil || proto.Size(presence) > maxProviderQuotaFrameBytes {
		return errors.New("provider account presence exceeds 64 KiB")
	}
	if err := m.store.ReplaceProviderAccountPresence(record.GitHubID, daemonID, presence.GetAccounts(), m.now()); err != nil {
		return err
	}
	m.signalChanged()
	for _, account := range presence.GetAccounts() {
		if account.GetRefreshSupported() && account.GetAvailability() == gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE {
			_, _ = m.Refresh(record.GitHubID, account.GetProvider(), account.GetAccountKey())
		}
	}
	return nil
}

func (m *QuotaManager) HandleResult(record DaemonRecord, daemonID, requestID string, result *gatewayv1.ProviderQuotaRefreshResult) error {
	if requestID == "" || result == nil || proto.Size(result) > maxProviderQuotaFrameBytes {
		return errors.New("provider quota result is invalid")
	}
	m.mu.Lock()
	pending, exists := m.pending[requestID]
	if exists {
		delete(m.pending, requestID)
		delete(m.byAccount, providerAccountIndex(pending.githubID, pending.provider, pending.accountKey))
	}
	m.mu.Unlock()
	if !exists || pending.githubID != record.GitHubID || pending.daemonID != daemonID {
		return errors.New("provider quota result does not match a pending request")
	}
	now := m.now().UTC()
	if snapshot := result.GetSnapshot(); snapshot != nil {
		if snapshot.GetProvider() != pending.provider || snapshot.GetAccountKey() != pending.accountKey {
			return errors.New("provider quota result account does not match its request")
		}
		if err := m.store.SaveProviderQuotaSnapshot(record.GitHubID, daemonID, snapshot, now); err != nil {
			return err
		}
		m.signalChanged()
		return nil
	}
	code := strings.TrimSpace(result.GetErrorCode())
	if code == "" {
		code = "refresh_failed"
	}
	delay := providerFailureBackoff(pending.failures + 1)
	if seconds := result.GetRetryAfterSeconds(); seconds > 0 {
		delay = time.Duration(seconds) * time.Second
		if delay > time.Hour {
			delay = time.Hour
		}
	}
	if err := m.store.MarkProviderQuotaFailure(record.GitHubID, daemonID, pending.provider, pending.accountKey, code, now.Add(delay)); err != nil {
		return err
	}
	m.signalChanged()
	return nil
}

func providerFailureBackoff(failures int) time.Duration {
	steps := []time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour}
	if failures <= 1 {
		return steps[0]
	}
	if failures >= len(steps) {
		return steps[len(steps)-1]
	}
	return steps[failures-1]
}

func (m *QuotaManager) expireRequests() {
	now := m.now().UTC()
	var expired []pendingProviderRefresh
	m.mu.Lock()
	for requestID, pending := range m.pending {
		if now.Sub(pending.startedAt) >= providerQuotaRequestTimeout {
			delete(m.pending, requestID)
			delete(m.byAccount, providerAccountIndex(pending.githubID, pending.provider, pending.accountKey))
			expired = append(expired, pending)
		}
	}
	m.mu.Unlock()
	for _, pending := range expired {
		_ = m.store.MarkProviderQuotaFailure(pending.githubID, pending.daemonID, pending.provider, pending.accountKey, "timeout", now.Add(providerFailureBackoff(pending.failures+1)))
		m.signalChanged()
	}
}

func (m *QuotaManager) schedule(ctx context.Context) {
	owners, err := m.store.ListProviderQuotaOwners()
	if err != nil {
		m.logger.Warn("list provider quota owners", "error", err)
		return
	}
	now := m.now().UTC()
	for _, owner := range owners {
		records, err := m.store.ListProviderQuotaRecords(owner, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED)
		if err != nil {
			m.logger.Warn("list provider quota schedule", "error", err)
			continue
		}
		for _, record := range records {
			if ctx.Err() != nil {
				return
			}
			if record.NextAttemptAt.IsZero() || !record.NextAttemptAt.After(now) {
				_, _ = m.startRefresh(record)
			}
		}
	}
}

func (m *QuotaManager) Refresh(githubID int64, provider gatewayv1.ProviderQuotaProvider, accountKey string) (bool, error) {
	records, err := m.store.ListProviderQuotaRecords(githubID, provider)
	if err != nil {
		return false, err
	}
	accepted := false
	found := false
	for _, record := range records {
		if accountKey != "" && record.Account.GetAccountKey() != accountKey {
			continue
		}
		found = true
		started, err := m.startRefresh(record)
		if err != nil {
			continue
		}
		accepted = accepted || started
	}
	if accountKey != "" && !found {
		return false, errors.New("provider account was not found")
	}
	return accepted, nil
}

func (m *QuotaManager) startRefresh(record ProviderQuotaRecord) (bool, error) {
	if record.Account == nil || record.Account.GetAvailability() != gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE {
		return false, nil
	}
	accountIndex := providerAccountIndex(record.GitHubID, record.Account.GetProvider(), record.Account.GetAccountKey())
	m.mu.Lock()
	if _, exists := m.byAccount[accountIndex]; exists {
		m.mu.Unlock()
		return true, nil
	}
	if len(m.pending) >= maxConcurrentProviderRefreshes {
		m.mu.Unlock()
		return false, errors.New("provider quota refresh concurrency is exhausted")
	}
	m.mu.Unlock()
	source := m.chooseSource(record.Sources)
	if source == nil {
		return false, nil
	}
	requestID := randomID("quota_")
	pending := pendingProviderRefresh{
		githubID: record.GitHubID, provider: record.Account.GetProvider(), accountKey: record.Account.GetAccountKey(),
		daemonID: source.DaemonID, startedAt: m.now().UTC(), failures: record.FailureCount,
	}
	m.mu.Lock()
	if _, exists := m.byAccount[accountIndex]; exists {
		m.mu.Unlock()
		return true, nil
	}
	if len(m.pending) >= maxConcurrentProviderRefreshes {
		m.mu.Unlock()
		return false, errors.New("provider quota refresh concurrency is exhausted")
	}
	activeForDaemon := 0
	for _, active := range m.pending {
		if active.daemonID == source.DaemonID {
			activeForDaemon++
		}
	}
	if activeForDaemon >= maxProviderRefreshesPerDaemon {
		m.mu.Unlock()
		return false, nil
	}
	m.pending[requestID], m.byAccount[accountIndex] = pending, requestID
	m.mu.Unlock()
	err := m.hub.SendProviderQuotaRefresh(source.DaemonID, requestID, &gatewayv1.ProviderQuotaRefreshRequest{
		Provider: record.Account.GetProvider(), AccountKey: record.Account.GetAccountKey(),
	})
	if err != nil {
		m.mu.Lock()
		delete(m.pending, requestID)
		delete(m.byAccount, accountIndex)
		m.mu.Unlock()
		return false, err
	}
	m.signalChanged()
	return true, nil
}

func (m *QuotaManager) chooseSource(sources []ProviderQuotaSourceRecord) *ProviderQuotaSourceRecord {
	eligible := make([]ProviderQuotaSourceRecord, 0, len(sources))
	for _, source := range sources {
		if source.RefreshSupported && source.Availability == gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE &&
			m.hub.SupportsProviderQuotas(source.DaemonID) {
			eligible = append(eligible, source)
		}
	}
	if len(eligible) == 0 {
		return nil
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		if !eligible[i].LastSuccessAt.Equal(eligible[j].LastSuccessAt) {
			return eligible[i].LastSuccessAt.After(eligible[j].LastSuccessAt)
		}
		return eligible[i].DaemonID < eligible[j].DaemonID
	})
	return &eligible[0]
}

func (m *QuotaManager) Catalog(githubID int64, provider gatewayv1.ProviderQuotaProvider) ([]*gatewayv1.ProviderQuotaGroup, error) {
	records, err := m.store.ListProviderQuotaRecords(githubID, provider)
	if err != nil {
		return nil, err
	}
	now := m.now().UTC()
	grouped := map[gatewayv1.ProviderQuotaProvider][]*gatewayv1.ProviderQuotaSnapshot{}
	for _, record := range records {
		var snapshot *gatewayv1.ProviderQuotaSnapshot
		if record.Snapshot != nil {
			snapshot = proto.Clone(record.Snapshot).(*gatewayv1.ProviderQuotaSnapshot)
		} else {
			snapshot = &gatewayv1.ProviderQuotaSnapshot{
				Provider: record.Account.GetProvider(), AccountKey: record.Account.GetAccountKey(), AccountKind: record.Account.GetAccountKind(),
				Plan: record.Account.GetPlan(), Availability: record.Account.GetAvailability(), RefreshState: gatewayv1.ProviderQuotaRefreshState_PROVIDER_QUOTA_REFRESH_STATE_IDLE,
			}
		}
		// Presence is authoritative for current account state even when the
		// last successful numeric snapshot remains useful as stale context.
		snapshot.Provider = record.Account.GetProvider()
		snapshot.AccountKey = record.Account.GetAccountKey()
		snapshot.AccountKind = record.Account.GetAccountKind()
		snapshot.Plan = record.Account.GetPlan()
		snapshot.Availability = record.Account.GetAvailability()
		online := 0
		for _, source := range record.Sources {
			if source.RefreshSupported && source.Availability == gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE &&
				m.hub.SupportsProviderQuotas(source.DaemonID) {
				online++
			}
		}
		snapshot.OnlineSourceCount = uint32(online)
		index := providerAccountIndex(githubID, snapshot.GetProvider(), snapshot.GetAccountKey())
		m.mu.Lock()
		_, refreshing := m.byAccount[index]
		m.mu.Unlock()
		if refreshing {
			snapshot.RefreshState = gatewayv1.ProviderQuotaRefreshState_PROVIDER_QUOTA_REFRESH_STATE_REFRESHING
		} else if record.LastFailureCode != "" {
			snapshot.StatusCode = record.LastFailureCode
			if record.NextAttemptAt.After(now.Add(providerQuotaRefreshInterval)) {
				snapshot.RefreshState = gatewayv1.ProviderQuotaRefreshState_PROVIDER_QUOTA_REFRESH_STATE_THROTTLED
			} else {
				snapshot.RefreshState = gatewayv1.ProviderQuotaRefreshState_PROVIDER_QUOTA_REFRESH_STATE_FAILED
			}
		}
		if !record.NextAttemptAt.IsZero() {
			snapshot.NextRefreshAt = record.NextAttemptAt.Format(time.RFC3339Nano)
		}
		grouped[snapshot.GetProvider()] = append(grouped[snapshot.GetProvider()], snapshot)
	}
	providers := []gatewayv1.ProviderQuotaProvider{
		gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE,
	}
	groups := make([]*gatewayv1.ProviderQuotaGroup, 0, len(grouped))
	for _, key := range providers {
		accounts := grouped[key]
		if len(accounts) == 0 {
			continue
		}
		summary := summarizeProviderQuotas(accounts, now)
		sort.SliceStable(accounts, func(i, j int) bool {
			if accounts[i].GetAccountKey() == summary.GetSummaryAccountKey() {
				return true
			}
			if accounts[j].GetAccountKey() == summary.GetSummaryAccountKey() {
				return false
			}
			return accounts[i].GetAccountKey() < accounts[j].GetAccountKey()
		})
		groups = append(groups, &gatewayv1.ProviderQuotaGroup{Provider: key, Accounts: accounts, Summary: summary})
	}
	return groups, nil
}

func summarizeProviderQuotas(accounts []*gatewayv1.ProviderQuotaSnapshot, now time.Time) *gatewayv1.ProviderQuotaSummary {
	summary := &gatewayv1.ProviderQuotaSummary{TotalAccountCount: uint32(len(accounts))}
	type candidate struct {
		remaining uint32
		account   *gatewayv1.ProviderQuotaSnapshot
		window    *gatewayv1.ProviderQuotaWindow
		reset     time.Time
	}
	var selected *candidate
	for _, account := range accounts {
		hasNumeric := false
		for _, window := range account.GetWindows() {
			if window.RemainingPercent == nil || window.GetRemainingPercent() > 100 {
				continue
			}
			hasNumeric = true
			value := candidate{remaining: window.GetRemainingPercent(), account: account, window: window, reset: parseStoredTime(window.GetResetsAt())}
			if selected == nil || value.remaining < selected.remaining || value.remaining == selected.remaining && quotaCandidateLess(value, *selected) {
				selected = &value
			}
		}
		if hasNumeric {
			summary.NumericAccountCount++
		}
		if !hasNumeric || account.GetAvailability() != gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE {
			summary.UnavailableAccountCount++
		}
	}
	if selected == nil {
		return summary
	}
	summary.RemainingPercent = proto.Uint32(selected.remaining)
	summary.SummaryAccountKey = selected.account.GetAccountKey()
	summary.SummaryWindowId = selected.window.GetId()
	summary.SummaryWindowKind = selected.window.GetKind()
	summary.SummaryWindowLabel = selected.window.GetLabel()
	summary.ResetsAt = selected.window.GetResetsAt()
	summary.Freshness = gatewayv1.ProviderQuotaFreshness_PROVIDER_QUOTA_FRESHNESS_FRESH
	if freshUntil := parseStoredTime(selected.account.GetFreshUntil()); freshUntil.IsZero() || !freshUntil.After(now) {
		summary.Freshness = gatewayv1.ProviderQuotaFreshness_PROVIDER_QUOTA_FRESHNESS_STALE
	}
	return summary
}

func quotaCandidateLess(left, right struct {
	remaining uint32
	account   *gatewayv1.ProviderQuotaSnapshot
	window    *gatewayv1.ProviderQuotaWindow
	reset     time.Time
}) bool {
	if !left.reset.Equal(right.reset) {
		if left.reset.IsZero() {
			return false
		}
		if right.reset.IsZero() {
			return true
		}
		return left.reset.Before(right.reset)
	}
	if left.account.GetAccountKey() != right.account.GetAccountKey() {
		return left.account.GetAccountKey() < right.account.GetAccountKey()
	}
	return left.window.GetId() < right.window.GetId()
}
