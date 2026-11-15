package accounts

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
)

// Usage cadence and bounds (plan §4.7).
const (
	claudeProbeEvery = 5 * time.Minute
	codexProbeEvery  = 2 * time.Minute
	probeJitter      = 30 * time.Second
	probeTimeout     = 45 * time.Second
	observedEvery    = 60 * time.Second
	usageKeepFresh   = 15 * time.Minute
	refreshFloor     = 30 * time.Second
	ledgerKeep       = 8 * 24 * time.Hour
	ledgerMaxBytes   = 4 << 20
	ledgerPruneEvery = time.Hour
)

// probeInterval is how often an account's usage is probed; 0 means it has no
// probe (Sign in with ChatGPT, API keys): turns report its limits.
func probeInterval(account Account) time.Duration {
	switch {
	case account.Provider == ProviderClaude && (account.Method == MethodClaudeCode || account.Method == MethodHost):
		return claudeProbeEvery
	case account.Provider == ProviderChatGPT && (account.Method == MethodCodex || account.Method == MethodHost):
		return codexProbeEvery
	}
	return 0
}

// probe reads an account's plan usage through the provider's tool.
func (s *Service) probe(ctx context.Context, account Account) (Usage, error) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	switch {
	case account.Provider == ProviderClaude && (account.Method == MethodClaudeCode || account.Method == MethodHost):
		dir := s.hostClaudeArg()
		if account.Method == MethodClaudeCode {
			var err error
			if dir, err = s.prepareClaudeHome(account.ID); err != nil {
				return Usage{}, err
			}
		}
		probe, err := s.backend.ProbeClaudeUsage(ctx, dir)
		if err != nil {
			return Usage{}, err
		}
		if !probe.LoggedIn {
			s.scheduleCheck(account.ID, 0)
			return Usage{Unavailable: "signed_out"}, nil
		}
		usage := probe.Usage
		if usage.Plan == "" {
			usage.Plan = probe.Identity.Plan
		}
		return usage, nil
	case account.Provider == ProviderChatGPT && (account.Method == MethodCodex || account.Method == MethodHost):
		home, err := s.codexHomeOf(account)
		if err != nil {
			return Usage{}, err
		}
		return s.backend.ProbeCodexUsage(ctx, home)
	}
	return Usage{}, fault.New(fault.Unimplemented, "this account's usage is known only from its turns")
}

// probeDue probes each signed-in login on this machine when no machine has
// reported the account's usage within the probe interval.
func (s *Service) probeDue(ctx context.Context) {
	r, err := s.load()
	if err != nil {
		return
	}
	daemon := s.daemonID()
	for id := range r.accounts {
		account, ok := r.account(id)
		interval := probeInterval(account)
		if !ok || interval == 0 || !r.signedIn(id, daemon) {
			continue
		}
		now := s.now()
		s.mu.Lock()
		next := s.bg.nextProbe[id]
		s.mu.Unlock()
		if now.Before(next) {
			continue
		}
		if account.Usage != nil {
			if observed, err := time.Parse(time.RFC3339Nano, account.Usage.ObservedAt); err == nil && now.Sub(observed) < interval {
				s.setNextProbe(id, observed.Add(interval))
				continue
			}
		}
		usage, err := s.probe(ctx, account)
		if err != nil {
			s.log.Debug("provider usage probe failed", "account", id, "error", err)
			s.setNextProbe(id, now.Add(interval))
			continue
		}
		if err := s.writeUsage(id, usage, "probe", false); err != nil {
			s.log.Debug("provider usage not recorded", "account", id, "error", err)
		}
		s.setNextProbe(id, now.Add(interval))
	}
}

// setNextProbe schedules the next probe with jitter, so machines and
// accounts do not probe in lockstep.
func (s *Service) setNextProbe(id string, at time.Time) {
	jitter := time.Duration(rand.Int64N(int64(2*probeJitter))) - probeJitter
	s.mu.Lock()
	s.bg.nextProbe[id] = at.Add(jitter)
	s.mu.Unlock()
}

// writeUsage records usage on this machine's signed-in login record: on a
// material change, when forced, or every 15 minutes to keep it fresh.
func (s *Service) writeUsage(accountID string, usage Usage, source string, force bool) error {
	usage = normalizeUsage(usage)
	usage.Source, usage.ObservedAt = source, s.timestamp()
	now := s.now()
	return s.updateLogin(accountID, func(record *schema.ProviderLoginRecord, exists bool) bool {
		if !exists || record.State != StateSignedIn {
			return false
		}
		if !force && record.Usage != nil && !materialChange(*record.Usage, usage) {
			if observed, err := time.Parse(time.RFC3339Nano, record.Usage.ObservedAt); err == nil && now.Sub(observed) < usageKeepFresh {
				return false
			}
		}
		record.Usage = &usage
		return true
	})
}

// materialChange reports a change worth replicating: a window moved by a
// point or more or got a new reset time, the windows or plan changed, or
// availability or credits changed.
func materialChange(before, after Usage) bool {
	if before.Plan != after.Plan || before.Unavailable != after.Unavailable || len(before.Windows) != len(after.Windows) {
		return true
	}
	for i := range before.Windows {
		a, b := before.Windows[i], after.Windows[i]
		if a.Kind != b.Kind || a.Label != b.Label || a.ResetsAt != b.ResetsAt || math.Abs(a.UsedPercent-b.UsedPercent) >= 1 {
			return true
		}
	}
	return !jsonSame(before.Credits, after.Credits) || !jsonSame(before.Spend, after.Spend) || !jsonSame(before.ResetCredits, after.ResetCredits)
}

func jsonSame(a, b any) bool {
	left, _ := json.Marshal(a)
	right, _ := json.Marshal(b)
	return bytes.Equal(left, right)
}

// normalizeUsage bounds provider-reported usage to the record schema.
func normalizeUsage(usage Usage) Usage {
	usage.Plan = singleLine(usage.Plan, 64)
	switch usage.Unavailable {
	case "", "signed_out", "unsupported", "rate_limited", "plan_usage_not_granted":
	default:
		usage.Unavailable = "unsupported"
	}
	windows := make([]UsageWindow, 0, len(usage.Windows))
	for _, window := range usage.Windows {
		switch window.Kind {
		case "five_hour", "weekly", "model", "other":
		default:
			window.Kind = "other"
		}
		window.Label = singleLine(window.Label, 64)
		if math.IsNaN(window.UsedPercent) {
			continue
		}
		window.UsedPercent = math.Round(math.Max(0, math.Min(100, window.UsedPercent))*10) / 10
		if window.ResetsAt != "" {
			if t, err := time.Parse(time.RFC3339Nano, window.ResetsAt); err == nil {
				window.ResetsAt = t.UTC().Format(time.RFC3339)
			} else {
				window.ResetsAt = ""
			}
		}
		if window.DurationMinutes < 0 || window.DurationMinutes > 1<<20 {
			window.DurationMinutes = 0
		}
		windows = append(windows, window)
		if len(windows) == schema.ProviderUsageWindows {
			break
		}
	}
	usage.Windows = windows
	if usage.Credits != nil {
		credits := *usage.Credits
		credits.Balance = singleLine(credits.Balance, 64)
		usage.Credits = &credits
	}
	if usage.Spend != nil {
		spend := *usage.Spend
		if math.IsNaN(spend.Used) || math.IsNaN(spend.Limit) || spend.Used < 0 || spend.Limit < 0 || spend.Used > 1e12 || spend.Limit > 1e12 {
			usage.Spend = nil
		} else {
			spend.Currency = strings.ToUpper(singleLine(spend.Currency, 8))
			usage.Spend = &spend
		}
	}
	if usage.ResetCredits != nil {
		reset := *usage.ResetCredits
		reset.Available = max(0, min(reset.Available, 10000))
		usage.ResetCredits = &reset
	}
	return usage
}

// ObserveUsage takes plan limits a turn reported (runner "provider-usage"
// frames). data is normalized usage JSON (with "windows"), a Claude SDK
// rate_limit_event or its rate_limit_info, or a Codex rate-limit snapshot
// or account/rateLimits/updated params. It merges into this machine's usage
// and writes at most once a minute per account. It never blocks the caller.
func (s *Service) ObserveUsage(accountID string, data json.RawMessage) {
	data = append(json.RawMessage(nil), data...)
	s.async(func() { s.observeUsage(accountID, data) })
}

func (s *Service) observeUsage(accountID string, data json.RawMessage) {
	if !schema.ValidProviderAccountID(accountID) {
		return
	}
	observed, ok := parseObservedUsage(data)
	if !ok {
		return
	}
	s.mu.Lock()
	pending, has := s.bg.pending[accountID]
	if has {
		observed = mergeUsage(pending, observed)
	}
	s.bg.pending[accountID] = observed
	due := s.now().Sub(s.bg.lastObserved[accountID]) >= observedEvery
	s.mu.Unlock()
	if due {
		s.flushObservedAccount(accountID)
	}
}

// flushObserved writes pending turn-observed usage whose throttle elapsed.
func (s *Service) flushObserved() {
	s.mu.Lock()
	var due []string
	now := s.now()
	for id := range s.bg.pending {
		if now.Sub(s.bg.lastObserved[id]) >= observedEvery {
			due = append(due, id)
		}
	}
	s.mu.Unlock()
	for _, id := range due {
		s.flushObservedAccount(id)
	}
}

func (s *Service) flushObservedAccount(accountID string) {
	s.mu.Lock()
	observed, ok := s.bg.pending[accountID]
	delete(s.bg.pending, accountID)
	s.bg.lastObserved[accountID] = s.now()
	s.mu.Unlock()
	if !ok {
		return
	}
	r, err := s.load()
	if err != nil {
		return
	}
	if current, has := r.ownLogin(accountID, s.daemonID()); has && current.Usage != nil {
		observed = mergeUsage(*current.Usage, observed)
	}
	if err := s.writeUsage(accountID, observed, "turn", false); err != nil {
		s.log.Debug("turn-observed provider usage not recorded", "account", accountID, "error", err)
	}
}

// mergeUsage overlays a partial observation on earlier usage: windows of the
// same kind and label are replaced, others kept; reported fields win.
func mergeUsage(base, update Usage) Usage {
	merged := base
	merged.Unavailable = update.Unavailable
	if update.Plan != "" {
		merged.Plan = update.Plan
	}
	if update.Credits != nil {
		merged.Credits = update.Credits
	}
	if update.Spend != nil {
		merged.Spend = update.Spend
	}
	if update.ResetCredits != nil {
		merged.ResetCredits = update.ResetCredits
	}
	merged.Windows = append([]UsageWindow(nil), base.Windows...)
	for _, window := range update.Windows {
		replaced := false
		for i := range merged.Windows {
			if merged.Windows[i].Kind == window.Kind && merged.Windows[i].Label == window.Label {
				merged.Windows[i], replaced = window, true
			}
		}
		if !replaced {
			merged.Windows = append(merged.Windows, window)
		}
	}
	return merged
}

// Claude rate-limit windows, labelled the same way usage-claude.mjs labels
// them so turn observations replace probe results.
var claudeWindows = map[string]UsageWindow{
	"five_hour":        {Kind: "five_hour", Label: "5h", DurationMinutes: 300},
	"seven_day":        {Kind: "weekly", Label: "Weekly", DurationMinutes: 10080},
	"seven_day_opus":   {Kind: "model", Label: "Opus", DurationMinutes: 10080},
	"seven_day_sonnet": {Kind: "model", Label: "Sonnet", DurationMinutes: 10080},
}

type claudeRateLimit struct {
	Status        string   `json:"status"`
	ResetsAt      *float64 `json:"resetsAt"`
	RateLimitType string   `json:"rateLimitType"`
	Utilization   *float64 `json:"utilization"`
}

type codexWindow struct {
	UsedPercent        float64 `json:"usedPercent"`
	ResetsAt           *int64  `json:"resetsAt"`
	WindowDurationMins *int64  `json:"windowDurationMins"`
}

type codexSnapshot struct {
	LimitID   *string `json:"limitId"`
	LimitName *string `json:"limitName"`
	PlanType  *string `json:"planType"`
	Primary   *codexWindow
	Secondary *codexWindow
	Credits   *struct {
		Balance    *string `json:"balance"`
		HasCredits bool    `json:"hasCredits"`
		Unlimited  bool    `json:"unlimited"`
	} `json:"credits"`
}

// codexRateLimits is account/rateLimits/read's result.
type codexRateLimits struct {
	RateLimits            codexSnapshot            `json:"rateLimits"`
	RateLimitsByLimitID   map[string]codexSnapshot `json:"rateLimitsByLimitId"`
	RateLimitResetCredits *struct {
		AvailableCount int `json:"availableCount"`
	} `json:"rateLimitResetCredits"`
}

func parseObservedUsage(data json.RawMessage) (Usage, bool) {
	var probe map[string]json.RawMessage
	if json.Unmarshal(data, &probe) != nil {
		return Usage{}, false
	}
	if _, ok := probe["windows"]; ok {
		var usage Usage
		if json.Unmarshal(data, &usage) != nil {
			return Usage{}, false
		}
		return usage, true
	}
	if raw, ok := probe["rate_limit_info"]; ok {
		return parseObservedUsage(raw)
	}
	if _, ok := probe["rateLimitType"]; ok {
		var limit claudeRateLimit
		if json.Unmarshal(data, &limit) != nil {
			return Usage{}, false
		}
		window, known := claudeWindows[limit.RateLimitType]
		if !known || limit.Utilization == nil {
			return Usage{}, false
		}
		// The SDK reports utilization as a fraction, like Anthropic's
		// unified rate-limit headers.
		window.UsedPercent = *limit.Utilization * 100
		if limit.ResetsAt != nil {
			window.ResetsAt = time.Unix(int64(*limit.ResetsAt), 0).UTC().Format(time.RFC3339)
		}
		return Usage{Windows: []UsageWindow{window}}, true
	}
	if raw, ok := probe["rateLimits"]; ok {
		var limits codexRateLimits
		if json.Unmarshal(data, &limits) != nil {
			var snapshot codexSnapshot
			if json.Unmarshal(raw, &snapshot) != nil {
				return Usage{}, false
			}
			return codexUsage(codexRateLimits{RateLimits: snapshot}), true
		}
		return codexUsage(limits), true
	}
	if _, ok := probe["primary"]; ok {
		var snapshot codexSnapshot
		if json.Unmarshal(data, &snapshot) != nil {
			return Usage{}, false
		}
		return codexUsage(codexRateLimits{RateLimits: snapshot}), true
	}
	return Usage{}, false
}

// codexUsage normalizes Codex rate limits: primary and secondary windows by
// duration, further metered buckets as model windows, plan, credits and
// reset credits.
func codexUsage(limits codexRateLimits) Usage {
	var usage Usage
	snapshot := limits.RateLimits
	if snapshot.PlanType != nil {
		usage.Plan = *snapshot.PlanType
	}
	usage.Windows = append(usage.Windows, codexWindows(snapshot, "")...)
	ids := make([]string, 0, len(limits.RateLimitsByLimitID))
	for id := range limits.RateLimitsByLimitID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		bucket := limits.RateLimitsByLimitID[id]
		if id == "codex" || snapshot.LimitID != nil && *snapshot.LimitID == id {
			continue
		}
		name := id
		if bucket.LimitName != nil && *bucket.LimitName != "" {
			name = *bucket.LimitName
		}
		usage.Windows = append(usage.Windows, codexWindows(bucket, name)...)
	}
	if credits := snapshot.Credits; credits != nil && (credits.HasCredits || credits.Unlimited) {
		usage.Credits = &Credits{Unlimited: credits.Unlimited}
		if credits.Balance != nil {
			usage.Credits.Balance = *credits.Balance
		}
	}
	if reset := limits.RateLimitResetCredits; reset != nil {
		usage.ResetCredits = &ResetCredits{Available: reset.AvailableCount}
	}
	return usage
}

func codexWindows(snapshot codexSnapshot, model string) []UsageWindow {
	var windows []UsageWindow
	for _, raw := range []*codexWindow{snapshot.Primary, snapshot.Secondary} {
		if raw == nil {
			continue
		}
		window := UsageWindow{UsedPercent: raw.UsedPercent}
		if raw.WindowDurationMins != nil {
			window.DurationMinutes = int(*raw.WindowDurationMins)
		}
		if raw.ResetsAt != nil && *raw.ResetsAt > 0 {
			window.ResetsAt = time.Unix(*raw.ResetsAt, 0).UTC().Format(time.RFC3339)
		}
		switch {
		case model != "":
			window.Kind, window.Label = "model", model+" "+durationLabel(window.DurationMinutes)
		case window.DurationMinutes == 300:
			window.Kind, window.Label = "five_hour", "5h"
		case window.DurationMinutes == 10080:
			window.Kind, window.Label = "weekly", "Weekly"
		default:
			window.Kind, window.Label = "other", durationLabel(window.DurationMinutes)
		}
		windows = append(windows, window)
	}
	return windows
}

func durationLabel(minutes int) string {
	switch {
	case minutes <= 0:
		return "Limit"
	case minutes%10080 == 0:
		return fmt.Sprintf("%dw", minutes/10080)
	case minutes%1440 == 0:
		return fmt.Sprintf("%dd", minutes/1440)
	case minutes%60 == 0:
		return fmt.Sprintf("%dh", minutes/60)
	}
	return fmt.Sprintf("%dm", minutes)
}

// RefreshUsage probes an account's usage on this machine now, at most once
// every 30 seconds per account.
func (s *Service) RefreshUsage(ctx context.Context, accountID string) (Account, error) {
	account, r, err := s.signedInHere(accountID)
	if err != nil {
		return Account{}, err
	}
	_ = r
	interval := probeInterval(account)
	if interval == 0 {
		return account, nil
	}
	now := s.now()
	s.mu.Lock()
	if now.Sub(s.bg.lastRefresh[accountID]) < refreshFloor {
		s.mu.Unlock()
		return account, nil
	}
	s.bg.lastRefresh[accountID] = now
	s.mu.Unlock()
	usage, err := s.probe(ctx, account)
	if err != nil {
		return Account{}, fault.Wrap(fault.Unavailable, fmt.Errorf("could not read %s usage: %w", providerName(account.Provider), err))
	}
	if err := s.writeUsage(accountID, usage, "probe", true); err != nil {
		return Account{}, err
	}
	s.setNextProbe(accountID, now.Add(interval))
	return s.get(accountID)
}

func (s *Service) signedInHere(accountID string) (Account, registry, error) {
	r, err := s.load()
	if err != nil {
		return Account{}, r, err
	}
	account, ok := r.account(accountID)
	if !ok {
		return Account{}, r, fault.NotFoundf("provider account %s not found", accountID)
	}
	if !r.signedIn(accountID, s.daemonID()) {
		return Account{}, r, s.notSignedIn(account)
	}
	return account, r, nil
}

// ConsumeReset spends one ChatGPT rate-limit reset credit of an account
// signed in here and returns Codex's outcome, then probes usage again.
func (s *Service) ConsumeReset(ctx context.Context, accountID, idempotencyKey, creditID string) (string, Account, error) {
	account, _, err := s.signedInHere(accountID)
	if err != nil {
		return "", Account{}, err
	}
	if account.Provider != ProviderChatGPT || (account.Method != MethodCodex && account.Method != MethodHost) {
		return "", Account{}, fault.New(fault.FailedPrecondition, "only ChatGPT accounts signed in with Codex have reset credits")
	}
	if !validUUID(idempotencyKey) {
		return "", Account{}, fault.New(fault.Invalid, "the idempotency key must be a UUID")
	}
	if len(creditID) > 256 || strings.ContainsAny(creditID, "\r\n\x00") {
		return "", Account{}, fault.New(fault.Invalid, "invalid reset credit ID")
	}
	home, err := s.codexHomeOf(account)
	if err != nil {
		return "", Account{}, err
	}
	resetCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	outcome, err := s.backend.ConsumeCodexReset(resetCtx, home, idempotencyKey, creditID)
	if err != nil {
		s.audit(accountID, "reset", "failed")
		return "", Account{}, fault.Wrap(fault.Unavailable, fmt.Errorf("could not reset ChatGPT usage: %w", err))
	}
	s.audit(accountID, "reset", outcome)
	if usage, err := s.probe(ctx, account); err == nil {
		if err := s.writeUsage(accountID, usage, "probe", true); err != nil {
			s.log.Debug("provider usage not recorded after a reset", "account", accountID, "error", err)
		}
	}
	updated, err := s.get(accountID)
	return outcome, updated, err
}

func validUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, c := range value {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return false
			}
		}
	}
	return true
}

// ledgerEntry is one finished turn's tokens on an account.
type ledgerEntry struct {
	At        time.Time `json:"at"`
	AccountID string    `json:"accountId"`
	Input     int64     `json:"input"`
	Output    int64     `json:"output"`
	Total     int64     `json:"total"`
}

func (s *Service) ledgerPath() string {
	return filepath.Join(s.store.ProviderAccountsDir(), "ledger.ndjson")
}

// RecordTurnTokens appends a finished turn's tokens to the local ledger and
// updates this machine's rolling five-hour and seven-day sums. It never
// blocks the caller.
func (s *Service) RecordTurnTokens(accountID string, at time.Time, input, output, total int64) {
	s.async(func() { s.recordTurnTokens(accountID, at, input, output, total) })
}

func (s *Service) recordTurnTokens(accountID string, at time.Time, input, output, total int64) {
	if !schema.ValidProviderAccountID(accountID) || input < 0 || output < 0 || total < 0 || input+output+total == 0 {
		return
	}
	if total == 0 {
		total = input + output
	}
	raw, err := json.Marshal(ledgerEntry{At: at.UTC(), AccountID: accountID, Input: input, Output: output, Total: total})
	if err != nil {
		return
	}
	if err := s.appendLedger(raw); err != nil {
		s.log.Warn("could not record provider turn tokens", "account", accountID, "error", err)
		return
	}
	s.refreshTokens(accountID)
}

func (s *Service) appendLedger(line []byte) error {
	s.fileMu.Lock()
	defer s.fileMu.Unlock()
	if err := os.MkdirAll(s.store.ProviderAccountsDir(), 0o700); err != nil {
		return err
	}
	release, err := s.store.BeginWriteLock()
	if err != nil {
		return err
	}
	err = appendLine(s.ledgerPath(), line)
	release()
	if err != nil {
		return err
	}
	now := s.now()
	info, statErr := os.Stat(s.ledgerPath())
	s.mu.Lock()
	prune := statErr == nil && info.Size() > ledgerMaxBytes || now.Sub(s.bg.lastPrune) >= ledgerPruneEvery
	if prune {
		s.bg.lastPrune = now
	}
	s.mu.Unlock()
	if prune {
		return s.pruneLedger(now)
	}
	return nil
}

// pruneLedger drops entries older than 8 days and, past 4 MiB, the oldest
// until half that remains. Call with fileMu held.
func (s *Service) pruneLedger(now time.Time) error {
	entries, err := s.readLedger()
	if err != nil {
		return err
	}
	var kept [][]byte
	size := 0
	for i := len(entries) - 1; i >= 0; i-- {
		if now.Sub(entries[i].At) > ledgerKeep {
			continue
		}
		raw, _ := json.Marshal(entries[i])
		if size+len(raw)+1 > ledgerMaxBytes/2 {
			break
		}
		size += len(raw) + 1
		kept = append(kept, raw)
	}
	var buffer bytes.Buffer
	for i := len(kept) - 1; i >= 0; i-- {
		buffer.Write(kept[i])
		buffer.WriteByte('\n')
	}
	return s.writePrivate(s.ledgerPath(), buffer.Bytes())
}

func (s *Service) readLedger() ([]ledgerEntry, error) {
	file, err := os.Open(s.ledgerPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var entries []ledgerEntry
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 64<<10)
	for scanner.Scan() {
		var entry ledgerEntry
		if json.Unmarshal(scanner.Bytes(), &entry) == nil && entry.AccountID != "" {
			entries = append(entries, entry)
		}
	}
	return entries, scanner.Err()
}

// tokenSums is the rolling five-hour and seven-day token totals per account.
func (s *Service) tokenSums(now time.Time) (map[string][2]TokenTotals, error) {
	s.fileMu.Lock()
	entries, err := s.readLedger()
	s.fileMu.Unlock()
	if err != nil {
		return nil, err
	}
	sums := map[string][2]TokenTotals{}
	for _, entry := range entries {
		age := now.Sub(entry.At)
		if age > 7*24*time.Hour || age < -time.Hour {
			continue
		}
		totals := sums[entry.AccountID]
		turn := TokenTotals{Input: entry.Input, Output: entry.Output, Total: entry.Total}
		totals[1] = addTotals(totals[1], turn)
		if age <= 5*time.Hour {
			totals[0] = addTotals(totals[0], turn)
		}
		sums[entry.AccountID] = totals
	}
	return sums, nil
}

// refreshTokens writes an account's current token sums to this machine's
// login record when they changed.
func (s *Service) refreshTokens(accountID string) {
	sums, err := s.tokenSums(s.now())
	if err != nil {
		return
	}
	s.writeTokens(accountID, sums[accountID])
}

func (s *Service) writeTokens(accountID string, totals [2]TokenTotals) {
	err := s.updateLogin(accountID, func(record *schema.ProviderLoginRecord, exists bool) bool {
		if !exists {
			return false
		}
		if record.DieterTokens == nil && totals == [2]TokenTotals{} {
			return false
		}
		if record.DieterTokens != nil && record.DieterTokens.FiveHour == totals[0] && record.DieterTokens.SevenDay == totals[1] {
			return false
		}
		record.DieterTokens = &TokenUsage{FiveHour: totals[0], SevenDay: totals[1], ObservedAt: s.timestamp()}
		return true
	})
	if err != nil {
		s.log.Debug("provider token sums not recorded", "account", accountID, "error", err)
	}
}

// sweepTokens keeps the rolling sums current as turns age out of them.
func (s *Service) sweepTokens() {
	r, err := s.load()
	if err != nil {
		return
	}
	sums, err := s.tokenSums(s.now())
	if err != nil {
		return
	}
	daemon := s.daemonID()
	for id := range r.logins {
		if login, ok := r.ownLogin(id, daemon); ok && (login.DieterTokens != nil || sums[id] != [2]TokenTotals{}) {
			s.writeTokens(id, sums[id])
		}
	}
}

// appendLine appends one line to a private file and syncs it.
func appendLine(path string, line []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(append(line, '\n')); err != nil {
		file.Close()
		return err
	}
	if err = file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}
