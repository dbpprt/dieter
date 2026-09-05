package gateway

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
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
	Sessions []Session      `json:"sessions,omitempty"`
	Pending  []OAuthPending `json:"pending,omitempty"`
	Codes    []NativeCode   `json:"codes,omitempty"`
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
	APIVersion        string
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
	db, err := sql.Open("sqlite", filepath.Join(absolute, "gateway.db"))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	store := &Store{Root: absolute, DB: db}
	if err := store.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error { return s.DB.Close() }

func (s *Store) migrate() error {
	_, err := s.DB.Exec(`
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
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
`)
	if err != nil {
		return fmt.Errorf("initialize gateway database: %w", err)
	}
	if err := s.ensureDaemonColumn("remote_desktop_json", `BLOB NOT NULL DEFAULT '{}'`); err != nil {
		return fmt.Errorf("migrate gateway database: %w", err)
	}
	if err := s.ensureDaemonColumn("api_version", `TEXT NOT NULL DEFAULT ''`); err != nil {
		return fmt.Errorf("migrate gateway database: %w", err)
	}
	if info, statErr := os.Stat(filepath.Join(s.Root, "gateway.db")); statErr == nil && info.Mode().Perm() != 0o600 {
		_ = os.Chmod(filepath.Join(s.Root, "gateway.db"), 0o600)
	}
	return nil
}

func (s *Store) ensureDaemonColumn(name, declaration string) error {
	rows, err := s.DB.Query(`PRAGMA table_info(daemons)`)
	if err != nil {
		return err
	}
	found := false
	for rows.Next() {
		var index int
		var column, columnType string
		var notNull, primaryKey int
		var defaultValue sql.NullString
		if err := rows.Scan(&index, &column, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			rows.Close()
			return err
		}
		if column == name {
			found = true
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if found {
		return nil
	}
	// name and declaration are internal constants, never request data.
	_, err = s.DB.Exec(`ALTER TABLE daemons ADD COLUMN ` + name + ` ` + declaration)
	return err
}

func (s *Store) AuthState() (AuthState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.authStateLocked()
}

func (s *Store) authStateLocked() (AuthState, error) {
	var raw []byte
	err := s.DB.QueryRow(`SELECT value FROM gateway_state WHERE key = 'auth'`).Scan(&raw)
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
	state, err := s.authStateLocked()
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
	_, err = s.DB.Exec(`INSERT INTO gateway_state(key, value) VALUES('auth', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, raw)
	return err
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
	var created, lastSeen string
	err := s.DB.QueryRow(`SELECT id, name, github_id, login, public_key, certificate, generation, revoked, created_at, last_seen_at, version, api_version, routes_json, remote_desktop_json FROM daemons WHERE id=?`, id).
		Scan(&record.ID, &record.Name, &record.GitHubID, &record.Login, &record.PublicKey, &record.Certificate, &generation, &revoked, &created, &lastSeen, &record.Version, &record.APIVersion, &record.RoutesJSON, &record.RemoteDesktopJSON)
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
	_, err = s.DB.Exec(`UPDATE daemons SET revoked=1, generation=? WHERE id=?`, next, id)
	return next, err
}

func (s *Store) MarkDaemonSeen(id, version, apiVersion string, routes, remoteDesktop []byte) error {
	result, err := s.DB.Exec(`UPDATE daemons SET last_seen_at=?, version=?, api_version=?, routes_json=?, remote_desktop_json=? WHERE id=? AND revoked=0`, time.Now().UTC().Format(time.RFC3339Nano), version, apiVersion, routes, remoteDesktop, id)
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count != 1 {
		return errors.New("daemon not found or revoked")
	}
	return nil
}
