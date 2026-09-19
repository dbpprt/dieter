package gateway

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

const providerQuotaSchemaVersion = 1

type ProviderQuotaSourceRecord struct {
	DaemonID         string
	RefreshSupported bool
	Availability     gatewayv1.ProviderQuotaAvailability
	LastSeenAt       time.Time
	LastSuccessAt    time.Time
	LastFailureCode  string
}

type ProviderQuotaRecord struct {
	GitHubID        int64
	Account         *gatewayv1.ProviderAccountPresence
	Snapshot        *gatewayv1.ProviderQuotaSnapshot
	Sources         []ProviderQuotaSourceRecord
	FirstSeenAt     time.Time
	LastSeenAt      time.Time
	NextAttemptAt   time.Time
	FailureCount    int
	LastFailureCode string
}

func parseStoredTime(value string) time.Time {
	parsed, _ := time.Parse(time.RFC3339Nano, value)
	return parsed
}

func (s *Store) ProviderCorrelationKey(githubID int64) ([]byte, error) {
	if githubID <= 0 {
		return nil, errors.New("provider quota owner is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var existing []byte
	err = tx.QueryRow(`SELECT correlation_key FROM provider_account_keys WHERE github_id=?`, githubID).Scan(&existing)
	if err == nil {
		if len(existing) != 32 {
			return nil, errors.New("stored provider account correlation key is invalid")
		}
		return append([]byte(nil), existing...), tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`INSERT INTO provider_account_keys(github_id, correlation_key, created_at) VALUES(?, ?, ?)`,
		githubID, key, time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return key, nil
}

func (s *Store) ReplaceProviderAccountPresence(githubID int64, daemonID string, accounts []*gatewayv1.ProviderAccountPresence, now time.Time) error {
	if githubID <= 0 || daemonID == "" {
		return errors.New("provider account source identity is required")
	}
	now = now.UTC()
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var owner int64
	var revoked int
	if err := tx.QueryRow(`SELECT github_id, revoked FROM daemons WHERE id=?`, daemonID).Scan(&owner, &revoked); err != nil || owner != githubID || revoked != 0 {
		return errors.New("provider account source is not enrolled for this owner")
	}
	if _, err := tx.Exec(`DELETE FROM provider_account_sources WHERE daemon_id=?`, daemonID); err != nil {
		return err
	}
	seen := make(map[string]struct{}, len(accounts))
	providerCounts := map[gatewayv1.ProviderQuotaProvider]int{}
	for _, account := range accounts {
		if err := validateProviderAccountPresence(account); err != nil {
			return err
		}
		providerCounts[account.GetProvider()]++
		if providerCounts[account.GetProvider()] > maxProviderAccountsPerDaemon {
			return fmt.Errorf("too many %s provider accounts", account.GetProvider())
		}
		key := fmt.Sprintf("%d:%s", account.GetProvider(), account.GetAccountKey())
		if _, duplicate := seen[key]; duplicate {
			return errors.New("duplicate provider account presence")
		}
		seen[key] = struct{}{}
		stamp := now.Format(time.RFC3339Nano)
		if _, err := tx.Exec(`INSERT INTO provider_accounts(
			github_id, provider, account_key, account_kind, plan, availability, first_seen_at, last_seen_at
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(github_id, provider, account_key) DO UPDATE SET
			account_kind=excluded.account_kind, plan=excluded.plan,
			availability=excluded.availability, last_seen_at=excluded.last_seen_at`,
			githubID, account.GetProvider(), account.GetAccountKey(), account.GetAccountKind(), account.GetPlan(), account.GetAvailability(), stamp, stamp); err != nil {
			return err
		}
		if _, err := tx.Exec(`INSERT INTO provider_account_sources(
			github_id, provider, account_key, daemon_id, refresh_supported, availability, last_seen_at
		) VALUES(?, ?, ?, ?, ?, ?, ?)`, githubID, account.GetProvider(), account.GetAccountKey(), daemonID,
			boolToInt(account.GetRefreshSupported()), account.GetAvailability(), stamp); err != nil {
			return err
		}
	}
	// Presence can arrive independently from several enrolled daemons. Keep an
	// account available whenever any current source can refresh it instead of
	// letting the most recent (possibly transiently unavailable) source win.
	if _, err := tx.Exec(`UPDATE provider_accounts SET availability=(
		SELECT MIN(sources.availability) FROM provider_account_sources sources
		WHERE sources.github_id=provider_accounts.github_id
		  AND sources.provider=provider_accounts.provider
		  AND sources.account_key=provider_accounts.account_key
	) WHERE github_id=? AND EXISTS (
		SELECT 1 FROM provider_account_sources sources
		WHERE sources.github_id=provider_accounts.github_id
		  AND sources.provider=provider_accounts.provider
		  AND sources.account_key=provider_accounts.account_key
	)`, githubID); err != nil {
		return err
	}
	// A full presence frame is authoritative for this daemon. Once an account
	// has no enrolled source left (for example after sign-out), delete its
	// normalized snapshot immediately instead of retaining unreachable usage.
	if _, err := tx.Exec(`DELETE FROM provider_accounts
		WHERE github_id=? AND NOT EXISTS (
			SELECT 1 FROM provider_account_sources sources
			WHERE sources.github_id=provider_accounts.github_id
			  AND sources.provider=provider_accounts.provider
			  AND sources.account_key=provider_accounts.account_key
		)`, githubID); err != nil {
		return err
	}
	return tx.Commit()
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func (s *Store) RemoveProviderAccountSources(daemonID string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM provider_account_sources WHERE daemon_id=?`, daemonID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM provider_accounts WHERE NOT EXISTS (
		SELECT 1 FROM provider_account_sources sources
		WHERE sources.github_id=provider_accounts.github_id
		  AND sources.provider=provider_accounts.provider
		  AND sources.account_key=provider_accounts.account_key
	)`); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ListProviderQuotaOwners() ([]int64, error) {
	rows, err := s.DB.Query(`SELECT DISTINCT github_id FROM provider_accounts ORDER BY github_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var owners []int64
	for rows.Next() {
		var owner int64
		if err := rows.Scan(&owner); err != nil {
			return nil, err
		}
		owners = append(owners, owner)
	}
	return owners, rows.Err()
}

func (s *Store) ListProviderQuotaRecords(githubID int64, provider gatewayv1.ProviderQuotaProvider) ([]ProviderQuotaRecord, error) {
	query := `SELECT github_id, provider, account_key, account_kind, plan, availability,
		first_seen_at, last_seen_at, next_attempt_at, failure_count, last_failure_code
		FROM provider_accounts WHERE github_id=?`
	args := []any{githubID}
	if provider != gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_UNSPECIFIED {
		query += ` AND provider=?`
		args = append(args, provider)
	}
	query += ` ORDER BY provider, account_key`
	rows, err := s.DB.Query(query, args...)
	if err != nil {
		return nil, err
	}
	var records []ProviderQuotaRecord
	for rows.Next() {
		var record ProviderQuotaRecord
		var providerValue, kindValue, availabilityValue int32
		var accountKey, plan, firstSeen, lastSeen, nextAttempt string
		if err := rows.Scan(&record.GitHubID, &providerValue, &accountKey, &kindValue, &plan, &availabilityValue,
			&firstSeen, &lastSeen, &nextAttempt, &record.FailureCount, &record.LastFailureCode); err != nil {
			rows.Close()
			return nil, err
		}
		record.Account = &gatewayv1.ProviderAccountPresence{
			Provider: gatewayv1.ProviderQuotaProvider(providerValue), AccountKey: accountKey,
			AccountKind: gatewayv1.ProviderAccountKind(kindValue), Plan: plan,
			Availability: gatewayv1.ProviderQuotaAvailability(availabilityValue),
		}
		record.FirstSeenAt, record.LastSeenAt, record.NextAttemptAt = parseStoredTime(firstSeen), parseStoredTime(lastSeen), parseStoredTime(nextAttempt)
		records = append(records, record)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for index := range records {
		record := &records[index]
		var raw []byte
		err := s.DB.QueryRow(`SELECT snapshot FROM provider_quota_snapshots WHERE github_id=? AND provider=? AND account_key=?`,
			record.GitHubID, record.Account.GetProvider(), record.Account.GetAccountKey()).Scan(&raw)
		if err == nil {
			var snapshot gatewayv1.ProviderQuotaSnapshot
			if err := proto.Unmarshal(raw, &snapshot); err != nil {
				return nil, fmt.Errorf("decode provider quota snapshot: %w", err)
			}
			record.Snapshot = &snapshot
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		sourceRows, err := s.DB.Query(`SELECT daemon_id, refresh_supported, availability, last_seen_at, last_success_at, last_failure_code
			FROM provider_account_sources WHERE github_id=? AND provider=? AND account_key=? ORDER BY daemon_id`,
			record.GitHubID, record.Account.GetProvider(), record.Account.GetAccountKey())
		if err != nil {
			return nil, err
		}
		for sourceRows.Next() {
			var source ProviderQuotaSourceRecord
			var refreshSupported int
			var availability int32
			var lastSeenAt, lastSuccessAt string
			if err := sourceRows.Scan(&source.DaemonID, &refreshSupported, &availability, &lastSeenAt, &lastSuccessAt, &source.LastFailureCode); err != nil {
				sourceRows.Close()
				return nil, err
			}
			source.RefreshSupported = refreshSupported != 0
			source.Availability = gatewayv1.ProviderQuotaAvailability(availability)
			source.LastSeenAt, source.LastSuccessAt = parseStoredTime(lastSeenAt), parseStoredTime(lastSuccessAt)
			record.Sources = append(record.Sources, source)
		}
		if err := sourceRows.Close(); err != nil {
			return nil, err
		}
	}
	return records, nil
}

func (s *Store) SaveProviderQuotaSnapshot(githubID int64, daemonID string, snapshot *gatewayv1.ProviderQuotaSnapshot, now time.Time) error {
	if err := validateProviderQuotaSnapshot(snapshot); err != nil {
		return err
	}
	now = now.UTC()
	copy := proto.Clone(snapshot).(*gatewayv1.ProviderQuotaSnapshot)
	copy.RefreshedAt = now.Format(time.RFC3339Nano)
	copy.LastSuccessAt = copy.RefreshedAt
	copy.NextRefreshAt = now.Add(providerQuotaRefreshInterval).Format(time.RFC3339Nano)
	copy.FreshUntil = copy.NextRefreshAt
	copy.RefreshState = gatewayv1.ProviderQuotaRefreshState_PROVIDER_QUOTA_REFRESH_STATE_IDLE
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(copy)
	if err != nil {
		return err
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var sourceCount int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM provider_account_sources WHERE github_id=? AND provider=? AND account_key=? AND daemon_id=? AND refresh_supported=1`,
		githubID, copy.GetProvider(), copy.GetAccountKey(), daemonID).Scan(&sourceCount); err != nil || sourceCount != 1 {
		return errors.New("provider quota result source is not eligible")
	}
	stamp, freshUntil := now.Format(time.RFC3339Nano), now.Add(providerQuotaRefreshInterval).Format(time.RFC3339Nano)
	// Presence is authoritative for availability. A refresh result can arrive
	// after a newer presence frame marks its source unavailable, so do not let
	// the older in-flight result make the account appear available again.
	if _, err := tx.Exec(`UPDATE provider_accounts SET account_kind=?, plan=?, last_seen_at=?, next_attempt_at=?, failure_count=0, last_failure_code=''
		WHERE github_id=? AND provider=? AND account_key=?`, copy.GetAccountKind(), copy.GetPlan(), stamp, freshUntil,
		githubID, copy.GetProvider(), copy.GetAccountKey()); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO provider_quota_snapshots(
		github_id, provider, account_key, schema_version, snapshot, source_daemon_id, refreshed_at, fresh_until
	) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(github_id, provider, account_key) DO UPDATE SET schema_version=excluded.schema_version,
		snapshot=excluded.snapshot, source_daemon_id=excluded.source_daemon_id,
		refreshed_at=excluded.refreshed_at, fresh_until=excluded.fresh_until`, githubID, copy.GetProvider(), copy.GetAccountKey(),
		providerQuotaSchemaVersion, raw, daemonID, stamp, freshUntil); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE provider_account_sources SET last_success_at=?, last_failure_code=''
		WHERE github_id=? AND provider=? AND account_key=? AND daemon_id=?`, stamp, githubID, copy.GetProvider(), copy.GetAccountKey(), daemonID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) MarkProviderQuotaFailure(githubID int64, daemonID string, provider gatewayv1.ProviderQuotaProvider, accountKey, code string, next time.Time) error {
	if len(code) > maxProviderStatusCodeBytes {
		code = code[:maxProviderStatusCodeBytes]
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE provider_accounts SET next_attempt_at=?, failure_count=failure_count+1, last_failure_code=?
		WHERE github_id=? AND provider=? AND account_key=?`, next.UTC().Format(time.RFC3339Nano), code, githubID, provider, accountKey); err != nil {
		return err
	}
	if daemonID != "" {
		if _, err := tx.Exec(`UPDATE provider_account_sources SET last_failure_code=?
			WHERE github_id=? AND provider=? AND account_key=? AND daemon_id=?`, code, githubID, provider, accountKey, daemonID); err != nil {
			return err
		}
	}
	return tx.Commit()
}
