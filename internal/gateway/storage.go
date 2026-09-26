package gateway

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	Root string
	DB   *sql.DB
	mu   sync.Mutex
}

type Session struct {
	TokenHash string    `json:"tokenHash"`
	GitHubID  int64     `json:"githubId"`
	Login     string    `json:"login"`
	CreatedAt time.Time `json:"createdAt"`
	ExpiresAt time.Time `json:"expiresAt"`
}

type OAuthPending struct {
	StateHash       string    `json:"stateHash"`
	Verifier        string    `json:"verifier"`
	NativeRedirect  string    `json:"nativeRedirect,omitempty"`
	NativeChallenge string    `json:"nativeChallenge,omitempty"`
	EnrollmentID    string    `json:"enrollmentId,omitempty"`
	EnrollmentCode  string    `json:"enrollmentCode,omitempty"`
	CreatedAt       time.Time `json:"createdAt"`
	ExpiresAt       time.Time `json:"expiresAt"`
}

type NativeCode struct {
	CodeHash  string    `json:"codeHash"`
	Challenge string    `json:"challenge"`
	GitHubID  int64     `json:"githubId"`
	Login     string    `json:"login"`
	ExpiresAt time.Time `json:"expiresAt"`
}

type AuthState struct {
	Sessions  []Session            `json:"sessions,omitempty"`
	Pending   []OAuthPending       `json:"pending,omitempty"`
	Codes     []NativeCode         `json:"codes,omitempty"`
	Approvals []EnrollmentApproval `json:"approvals,omitempty"`
}

type EnrollmentApproval struct {
	TokenHash    string    `json:"tokenHash"`
	EnrollmentID string    `json:"enrollmentId"`
	UserCode     string    `json:"userCode"`
	GitHubID     int64     `json:"githubId"`
	Login        string    `json:"login"`
	ExpiresAt    time.Time `json:"expiresAt"`
}

type EnrollmentRecord struct {
	ID         string
	SecretHash string
	UserCode   string
	Name       string
	PublicKey  []byte
	Approved   bool
	GitHubID   int64
	Login      string
	ExpiresAt  time.Time
	ConsumedAt *time.Time
	DaemonID   string
}

type DaemonRecord struct {
	ID                string
	Name              string
	GitHubID          int64
	Login             string
	PublicKey         []byte
	Certificate       []byte
	Generation        uint64
	Revoked           bool
	CreatedAt         time.Time
	LastSeenAt        time.Time
	Version           string
	RoutesJSON        []byte
	RemoteDesktopJSON []byte
}

func DefaultRoot() string {
	if value := strings.TrimSpace(os.Getenv("DIETER_GATEWAY_HOME")); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".dieter-gateway"
	}
	return filepath.Join(home, ".dieter-gateway")
}

func OpenStore(root string) (*Store, error) {
	if strings.TrimSpace(root) == "" {
		root = DefaultRoot()
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(absolute, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(absolute, 0o700); err != nil {
		return nil, err
	}
	databaseURL := url.URL{Scheme: "file", Path: filepath.Join(absolute, "gateway.db")}
	// Reserve the SQLite writer before any read-modify-write operation. The
	// database lock protects sessions across processes, including sign-out.
	databaseURL.RawQuery = url.Values{"_txlock": {"immediate"}, "_busy_timeout": {"5000"}}.Encode()
	db, err := sql.Open("sqlite", databaseURL.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	store := &Store{Root: absolute, DB: db}
	if err := store.initializeSchema(); err != nil {
		db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error { return s.DB.Close() }

func (s *Store) initializeSchema() error {
	var version, tables int
	if err := s.DB.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if err := s.DB.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").Scan(&tables); err != nil {
		return err
	}
	if version != 1 && (version != 0 || tables != 0) {
		return errors.New("unsupported Dieter gateway storage schema; use a fresh DIETER_GATEWAY_HOME for this pre-release baseline")
	}
	_, err := s.DB.Exec(`
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS gateway_state (
  key TEXT PRIMARY KEY,
  value BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS enrollments (
  id TEXT PRIMARY KEY,
  secret_hash TEXT NOT NULL,
  user_code TEXT NOT NULL,
  name TEXT NOT NULL,
  public_key BLOB NOT NULL,
  approved INTEGER NOT NULL DEFAULT 0,
  github_id INTEGER NOT NULL DEFAULT 0,
  login TEXT NOT NULL DEFAULT '',
  expires_at TEXT NOT NULL,
  consumed_at TEXT,
  daemon_id TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS enrollments_user_code ON enrollments(user_code);
CREATE TABLE IF NOT EXISTS daemons (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  github_id INTEGER NOT NULL,
  login TEXT NOT NULL,
  public_key BLOB NOT NULL,
  certificate BLOB NOT NULL,
  generation INTEGER NOT NULL DEFAULT 1,
  revoked INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL DEFAULT '',
  version TEXT NOT NULL DEFAULT '',
  api_version TEXT NOT NULL DEFAULT '',
  routes_json BLOB NOT NULL DEFAULT '[]',
  remote_desktop_json BLOB NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS provider_account_keys (
  github_id INTEGER PRIMARY KEY,
  correlation_key BLOB NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS provider_accounts (
  github_id INTEGER NOT NULL,
  provider INTEGER NOT NULL,
  account_key TEXT NOT NULL,
  account_kind INTEGER NOT NULL,
  plan TEXT NOT NULL DEFAULT '',
  availability INTEGER NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  next_attempt_at TEXT NOT NULL DEFAULT '',
  failure_count INTEGER NOT NULL DEFAULT 0,
  last_failure_code TEXT NOT NULL DEFAULT '',
  summary_included INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY(github_id, provider, account_key)
);
CREATE TABLE IF NOT EXISTS provider_account_sources (
  github_id INTEGER NOT NULL,
  provider INTEGER NOT NULL,
  account_key TEXT NOT NULL,
  daemon_id TEXT NOT NULL,
  refresh_supported INTEGER NOT NULL DEFAULT 0,
  availability INTEGER NOT NULL,
  last_seen_at TEXT NOT NULL,
  last_success_at TEXT NOT NULL DEFAULT '',
  last_failure_code TEXT NOT NULL DEFAULT '',
  PRIMARY KEY(github_id, provider, account_key, daemon_id),
  FOREIGN KEY(github_id, provider, account_key)
    REFERENCES provider_accounts(github_id, provider, account_key)
    ON DELETE CASCADE,
  FOREIGN KEY(daemon_id) REFERENCES daemons(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS provider_account_sources_daemon
  ON provider_account_sources(daemon_id);
CREATE TABLE IF NOT EXISTS provider_account_preferences (
  github_id INTEGER NOT NULL,
  provider INTEGER NOT NULL,
  account_key TEXT NOT NULL,
  summary_included INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(github_id, provider, account_key)
);
CREATE TABLE IF NOT EXISTS provider_quota_snapshots (
  github_id INTEGER NOT NULL,
  provider INTEGER NOT NULL,
  account_key TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  snapshot BLOB NOT NULL,
  source_daemon_id TEXT NOT NULL,
  refreshed_at TEXT NOT NULL,
  fresh_until TEXT NOT NULL,
  PRIMARY KEY(github_id, provider, account_key),
  FOREIGN KEY(github_id, provider, account_key)
    REFERENCES provider_accounts(github_id, provider, account_key)
    ON DELETE CASCADE
);
PRAGMA user_version=1;
COMMIT;
`)
	if err != nil {
		return fmt.Errorf("initialize gateway database: %w", err)
	}
	if info, statErr := os.Stat(filepath.Join(s.Root, "gateway.db")); statErr == nil && info.Mode().Perm() != 0o600 {
		_ = os.Chmod(filepath.Join(s.Root, "gateway.db"), 0o600)
	}
	return nil
}

func (s *Store) AuthState() (AuthState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.authStateLocked()
}

func (s *Store) authStateLocked() (AuthState, error) {
	return readAuthState(s.DB.QueryRow)
}

func readAuthState(queryRow func(string, ...any) *sql.Row) (AuthState, error) {
	var raw []byte
	err := queryRow(`SELECT value FROM gateway_state WHERE key = 'auth'`).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return AuthState{}, nil
	}
	if err != nil {
		return AuthState{}, err
	}
	var state AuthState
	if err := json.Unmarshal(raw, &state); err != nil {
		return AuthState{}, fmt.Errorf("decode gateway authentication state: %w", err)
	}
	return state, nil
}

func (s *Store) UpdateAuthState(update func(*AuthState) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	state, err := readAuthState(tx.QueryRow)
	if err != nil {
		return err
	}
	if err := update(&state); err != nil {
		return err
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO gateway_state(key, value) VALUES('auth', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, raw); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) CreateEnrollment(record EnrollmentRecord) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`DELETE FROM enrollments WHERE expires_at<=?`, now); err != nil {
		return err
	}
	var active int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM enrollments`).Scan(&active); err != nil {
		return err
	}
	if active >= 1000 {
		return errors.New("too many pending daemon enrollments")
	}
	if _, err := tx.Exec(`INSERT INTO enrollments(id, secret_hash, user_code, name, public_key, expires_at) VALUES(?, ?, ?, ?, ?, ?)`,
		record.ID, record.SecretHash, record.UserCode, record.Name, record.PublicKey, record.ExpiresAt.UTC().Format(time.RFC3339Nano)); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) ApproveEnrollment(id, userCode string, githubID int64, login string) error {
	result, err := s.DB.Exec(`UPDATE enrollments SET approved=1, github_id=?, login=? WHERE id=? AND user_code=? AND approved=0 AND consumed_at IS NULL AND expires_at>?`,
		githubID, login, id, strings.ToUpper(strings.TrimSpace(userCode)), time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		return errors.New("daemon enrollment is invalid or expired")
	}
	return nil
}

func (s *Store) Enrollment(id string) (EnrollmentRecord, error) {
	var record EnrollmentRecord
	var approved int
	var expires, consumed sql.NullString
	err := s.DB.QueryRow(`SELECT id, secret_hash, user_code, name, public_key, approved, github_id, login, expires_at, consumed_at, daemon_id FROM enrollments WHERE id=?`, id).
		Scan(&record.ID, &record.SecretHash, &record.UserCode, &record.Name, &record.PublicKey, &approved, &record.GitHubID, &record.Login, &expires, &consumed, &record.DaemonID)
	if errors.Is(err, sql.ErrNoRows) {
		return record, errors.New("daemon enrollment not found")
	}
	if err != nil {
		return record, err
	}
	record.Approved = approved != 0
	record.ExpiresAt, _ = time.Parse(time.RFC3339Nano, expires.String)
	if consumed.Valid {
		value, _ := time.Parse(time.RFC3339Nano, consumed.String)
		record.ConsumedAt = &value
	}
	return record, nil
}

func (s *Store) FinishEnrollment(record DaemonRecord, enrollmentID string) error {
	tx, err := s.DB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.Exec(`INSERT INTO daemons(id, name, github_id, login, public_key, certificate, generation, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		record.ID, record.Name, record.GitHubID, record.Login, record.PublicKey, record.Certificate, record.Generation, record.CreatedAt.UTC().Format(time.RFC3339Nano)); err != nil {
		return err
	}
	result, err := tx.Exec(`UPDATE enrollments SET consumed_at=?, daemon_id=? WHERE id=? AND consumed_at IS NULL`, now, record.ID, enrollmentID)
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		return errors.New("daemon enrollment was already consumed")
	}
	return tx.Commit()
}

func (s *Store) Daemon(id string) (DaemonRecord, error) {
	var record DaemonRecord
	var generation int64
	var revoked int
	var legacyAPIVersion string
	var created, lastSeen string
	err := s.DB.QueryRow(`SELECT id, name, github_id, login, public_key, certificate, generation, revoked, created_at, last_seen_at, version, api_version, routes_json, remote_desktop_json FROM daemons WHERE id=?`, id).
		Scan(&record.ID, &record.Name, &record.GitHubID, &record.Login, &record.PublicKey, &record.Certificate, &generation, &revoked, &created, &lastSeen, &record.Version, &legacyAPIVersion, &record.RoutesJSON, &record.RemoteDesktopJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return record, errors.New("daemon not found")
	}
	if err != nil {
		return record, err
	}
	record.Generation = uint64(generation)
	record.Revoked = revoked != 0
	record.CreatedAt, _ = time.Parse(time.RFC3339Nano, created)
	record.LastSeenAt, _ = time.Parse(time.RFC3339Nano, lastSeen)
	return record, nil
}

func (s *Store) ListDaemons(githubID int64) ([]DaemonRecord, error) {
	rows, err := s.DB.Query(`SELECT id FROM daemons WHERE github_id=? AND revoked=0 ORDER BY name COLLATE NOCASE, id`, githubID)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	result := make([]DaemonRecord, 0, len(ids))
	for _, id := range ids {
		record, err := s.Daemon(id)
		if err != nil {
			return nil, err
		}
		result = append(result, record)
	}
	return result, nil
}

func (s *Store) RenameDaemon(id, name string, githubID int64) error {
	result, err := s.DB.Exec(`UPDATE daemons SET name=? WHERE id=? AND github_id=? AND revoked=0`, strings.TrimSpace(name), id, githubID)
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		return errors.New("daemon not found")
	}
	return nil
}

func (s *Store) RevokeDaemon(id string, githubID int64) (uint64, error) {
	record, err := s.Daemon(id)
	if err != nil || record.GitHubID != githubID || record.Revoked {
		return 0, errors.New("daemon not found")
	}
	next := record.Generation + 1
	tx, err := s.DB.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM provider_account_sources WHERE daemon_id=?`, id); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM provider_accounts WHERE NOT EXISTS (
		SELECT 1 FROM provider_account_sources sources
		WHERE sources.github_id=provider_accounts.github_id
		  AND sources.provider=provider_accounts.provider
		  AND sources.account_key=provider_accounts.account_key
	)`); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`UPDATE daemons SET revoked=1, generation=? WHERE id=?`, next, id); err != nil {
		return 0, err
	}
	return next, tx.Commit()
}

// RecoverDaemon restores only the verified snapshot of a revoked identity while
// its same-key replacement remains active. The transaction also makes retries
// safe without changing the original certificate or generation.
func (s *Store) RecoverDaemon(old, replacement DaemonRecord, githubID int64) (DaemonRecord, bool, error) {
	var empty DaemonRecord
	if old.ID == "" || replacement.ID == "" || old.ID == replacement.ID || githubID <= 0 ||
		old.Generation < 2 || len(old.PublicKey) == 0 || !bytes.Equal(old.PublicKey, replacement.PublicKey) ||
		len(old.Certificate) == 0 || len(replacement.Certificate) == 0 {
		return empty, false, errors.New("daemon recovery conditions changed")
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return empty, false, err
	}
	defer tx.Rollback()
	var currentOld, currentReplacement DaemonRecord
	var oldGeneration, replacementGeneration int64
	var oldRevoked, replacementRevoked int
	if err := tx.QueryRow(`SELECT id, name, github_id, login, public_key, certificate, generation, revoked FROM daemons WHERE id=?`, old.ID).
		Scan(&currentOld.ID, &currentOld.Name, &currentOld.GitHubID, &currentOld.Login, &currentOld.PublicKey, &currentOld.Certificate, &oldGeneration, &oldRevoked); err != nil {
		return empty, false, errors.New("daemon recovery conditions changed")
	}
	if err := tx.QueryRow(`SELECT id, github_id, public_key, certificate, generation, revoked FROM daemons WHERE id=?`, replacement.ID).
		Scan(&currentReplacement.ID, &currentReplacement.GitHubID, &currentReplacement.PublicKey, &currentReplacement.Certificate, &replacementGeneration, &replacementRevoked); err != nil {
		return empty, false, errors.New("daemon recovery conditions changed")
	}
	if currentOld.GitHubID != githubID || currentReplacement.GitHubID != githubID ||
		currentOld.ID != old.ID || currentReplacement.ID != replacement.ID ||
		oldGeneration < 2 || uint64(oldGeneration) != old.Generation ||
		uint64(replacementGeneration) != replacement.Generation ||
		(oldRevoked != 0) != old.Revoked || replacementRevoked != 0 ||
		!bytes.Equal(currentOld.PublicKey, old.PublicKey) ||
		!bytes.Equal(currentReplacement.PublicKey, replacement.PublicKey) ||
		!bytes.Equal(currentOld.Certificate, old.Certificate) ||
		!bytes.Equal(currentReplacement.Certificate, replacement.Certificate) {
		return empty, false, errors.New("daemon recovery conditions changed")
	}
	if oldRevoked != 0 {
		result, err := tx.Exec(`UPDATE daemons SET revoked=0 WHERE id=? AND github_id=? AND revoked=1 AND generation=? AND public_key=? AND certificate=?
			AND EXISTS (SELECT 1 FROM daemons WHERE id=? AND github_id=? AND revoked=0 AND generation=? AND public_key=? AND certificate=?)`,
			old.ID, githubID, oldGeneration, old.PublicKey, old.Certificate,
			replacement.ID, githubID, replacementGeneration, replacement.PublicKey, replacement.Certificate)
		if err != nil {
			return empty, false, err
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return empty, false, err
		}
		if affected != 1 {
			return empty, false, errors.New("daemon recovery conditions changed")
		}
	}
	if err := tx.Commit(); err != nil {
		return empty, false, err
	}
	old.Revoked = false
	return old, oldRevoked != 0, nil
}

func (s *Store) MarkDaemonSeen(id, version string, routes, remoteDesktop []byte) error {
	result, err := s.DB.Exec(`UPDATE daemons SET last_seen_at=?, version=?, routes_json=?, remote_desktop_json=? WHERE id=? AND revoked=0`, time.Now().UTC().Format(time.RFC3339Nano), version, routes, remoteDesktop, id)
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		return errors.New("daemon not found or revoked")
	}
	return nil
}
