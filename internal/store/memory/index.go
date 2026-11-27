// Package memory is the daemon's machine-local agent memory index: an SQLite
// full-text index (FTS5) of the conversations this daemon owns, rebuilt from
// their transcripts and never replicated, plus a mirror of the project's
// replicated saved memories for ranking. It lives in
// DIETER_HOME/memory/memory.db and is created when the first project switches
// memory on.
package memory

import (
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"

	agentmemory "github.com/dbpprt/dieter/internal/memory"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
)

// Index bounds.
const (
	// MaxObservations and MaxBytes bound the index; the oldest observations of
	// archived conversations are evicted first, then the oldest overall.
	MaxObservations = 2_000_000
	MaxBytes        = 1 << 30
	schemaVersion   = "1"
)

const schemaSQL = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS observations USING fts5(
  title, body, files, terms,
  card UNINDEXED, project UNINDEXED, kind UNINDEXED, tool UNINDEXED, message UNINDEXED, part UNINDEXED, seq UNINDEXED,
  tokenize = 'porter unicode61'
);
CREATE VIRTUAL TABLE IF NOT EXISTS digests USING fts5(
  title, body, terms, card UNINDEXED, project UNINDEXED,
  tokenize = 'porter unicode61'
);
CREATE TABLE IF NOT EXISTS cards (
  card TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  title TEXT NOT NULL,
  lane TEXT NOT NULL,
  harness TEXT NOT NULL,
  scope TEXT NOT NULL,
  last_activity_at TEXT NOT NULL,
  archived INTEGER NOT NULL,
  brief TEXT NOT NULL,
  final_answer TEXT NOT NULL,
  files TEXT NOT NULL,
  commands TEXT NOT NULL,
  failures INTEGER NOT NULL,
  messages INTEGER NOT NULL,
  last_message TEXT NOT NULL,
  observations INTEGER NOT NULL,
  recalls INTEGER NOT NULL DEFAULT 0,
  indexed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS cards_project ON cards(project);
CREATE VIRTUAL TABLE IF NOT EXISTS memories USING fts5(
  content, files, id UNINDEXED, project UNINDEXED, kind UNINDEXED,
  tokenize = 'porter unicode61'
);
CREATE TABLE IF NOT EXISTS memory_revisions (id TEXT PRIMARY KEY, project TEXT NOT NULL, revision TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS memory_revisions_project ON memory_revisions(project);
`

// Index is the machine-local memory index. It opens its database lazily: a
// daemon without any project with memory on has no database file.
type Index struct {
	path string
	mu   sync.Mutex
	db   *sql.DB
}

// New returns the index of the DIETER_HOME root.
func New(root string) *Index {
	return &Index{path: filepath.Join(root, "memory", "memory.db")}
}

// Path is the database file.
func (x *Index) Path() string { return x.path }

// Exists reports whether the database file exists.
func (x *Index) Exists() bool {
	_, err := os.Stat(x.path)
	return err == nil
}

// Size is the database size in bytes, WAL included.
func (x *Index) Size() int64 {
	var total int64
	for _, suffix := range []string{"", "-wal"} {
		if info, err := os.Stat(x.path + suffix); err == nil {
			total += info.Size()
		}
	}
	return total
}

// Close closes the database.
func (x *Index) Close() error {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.db == nil {
		return nil
	}
	err := x.db.Close()
	x.db = nil
	return err
}

func (x *Index) open() (*sql.DB, error) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.db != nil {
		return x.db, nil
	}
	if err := os.MkdirAll(filepath.Dir(x.path), 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(x.path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	db, err := home.OpenSQLite(x.path)
	if err != nil {
		return nil, err
	}
	// One connection: the indexer and recall serialize through it. The index
	// is derived data, so a crash may lose the last writes and a reindex
	// restores them.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err = db.Exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=10000; PRAGMA synchronous=NORMAL;" + schemaSQL); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err = db.Exec(`INSERT INTO meta(key, value) VALUES('schema', ?) ON CONFLICT(key) DO NOTHING`, schemaVersion); err != nil {
		_ = db.Close()
		return nil, err
	}
	x.db = db
	return db, nil
}

// Card describes a conversation being indexed.
type Card struct {
	ID, Project, Title, Lane, Harness, Scope, LastActivityAt, Brief string
	Archived                                                        bool
}

// IndexResult reports what IndexCard did.
type IndexResult struct {
	Added int
	Full  bool
}

// IndexCard indexes a conversation's messages. It is incremental: messages
// already indexed (same count prefix, same last message) are skipped; any
// other history, such as a merge, reindexes the conversation from scratch.
// The digest row is rebuilt every time.
func (x *Index) IndexCard(card Card, messages []model.UIMessage) (IndexResult, error) {
	db, err := x.open()
	if err != nil {
		return IndexResult{}, err
	}
	tx, err := db.Begin()
	if err != nil {
		return IndexResult{}, err
	}
	defer func() { _ = tx.Rollback() }()
	var indexedMessages, observationCount, failures int
	_ = failures
	var lastMessage, filesJSON, commandsJSON, finalAnswer string
	err = tx.QueryRow(`SELECT messages, last_message, observations, files, commands, failures, final_answer FROM cards WHERE card = ?`, card.ID).
		Scan(&indexedMessages, &lastMessage, &observationCount, &filesJSON, &commandsJSON, &failures, &finalAnswer)
	known := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return IndexResult{}, err
	}
	start := 0
	full := true
	if known && indexedMessages > 0 && indexedMessages <= len(messages) && messages[indexedMessages-1].ID == lastMessage {
		start, full = indexedMessages, false
		// The last indexed message may have grown (a reply that continued);
		// reindex it.
		start--
		if _, err = tx.Exec(`DELETE FROM observations WHERE card = ? AND message = ?`, card.ID, lastMessage); err != nil {
			return IndexResult{}, err
		}
	}
	var files, commands []string
	if full {
		if _, err = tx.Exec(`DELETE FROM observations WHERE card = ?`, card.ID); err != nil {
			return IndexResult{}, err
		}
		observationCount, failures, finalAnswer = 0, 0, ""
	} else {
		_ = json.Unmarshal([]byte(filesJSON), &files)
		_ = json.Unmarshal([]byte(commandsJSON), &commands)
	}
	if !full {
		// Recount what remains after dropping the last message's rows.
		if err = tx.QueryRow(`SELECT count(*) FROM observations WHERE card = ?`, card.ID).Scan(&observationCount); err != nil {
			return IndexResult{}, err
		}
	}
	title := agentmemory.Clip(agentmemory.Scrub(card.Title), agentmemory.MaxTitleBytes)
	observations := agentmemory.Observations(messages[start:])
	insert, err := tx.Prepare(`INSERT INTO observations(title, body, files, terms, card, project, kind, tool, message, part, seq) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return IndexResult{}, err
	}
	defer insert.Close()
	for _, observation := range observations {
		observationCount++
		files := strings.Join(observation.Files, " ")
		if _, err = insert.Exec(title, observation.Body, files, agentmemory.IdentifierTerms(title, observation.Body, files), card.ID, card.Project, observation.Kind, observation.Tool, observation.MessageID, observation.Part, observationCount); err != nil {
			return IndexResult{}, err
		}
	}
	digest := agentmemory.Summarize(card.Brief, observations)
	if digest.FinalAnswer == "" {
		digest.FinalAnswer = finalAnswer
	}
	digest.Files = mergeStrings(files, digest.Files, 50)
	digest.Commands = mergeStrings(commands, digest.Commands, 20)
	if err = tx.QueryRow(`SELECT count(*) FROM observations WHERE card = ? AND kind = ?`, card.ID, agentmemory.KindError).Scan(&digest.Failures); err != nil {
		return IndexResult{}, err
	}
	filesRaw, _ := json.Marshal(digest.Files)
	commandsRaw, _ := json.Marshal(digest.Commands)
	last := ""
	if len(messages) > 0 {
		last = messages[len(messages)-1].ID
	}
	if _, err = tx.Exec(`INSERT INTO cards(card, project, title, lane, harness, scope, last_activity_at, archived, brief, final_answer, files, commands, failures, messages, last_message, observations, indexed_at)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(card) DO UPDATE SET project=excluded.project, title=excluded.title, lane=excluded.lane, harness=excluded.harness, scope=excluded.scope,
 last_activity_at=excluded.last_activity_at, archived=excluded.archived, brief=excluded.brief, final_answer=excluded.final_answer, files=excluded.files,
 commands=excluded.commands, failures=excluded.failures, messages=excluded.messages, last_message=excluded.last_message, observations=excluded.observations,
 indexed_at=excluded.indexed_at`,
		card.ID, card.Project, title, card.Lane, card.Harness, card.Scope, card.LastActivityAt, boolInt(card.Archived), digest.Brief,
		digest.FinalAnswer, string(filesRaw), string(commandsRaw), digest.Failures, len(messages), last, observationCount, home.Timestamp()); err != nil {
		return IndexResult{}, err
	}
	if _, err = tx.Exec(`DELETE FROM digests WHERE card = ?`, card.ID); err != nil {
		return IndexResult{}, err
	}
	body := strings.Join([]string{digest.Brief, digest.FinalAnswer, strings.Join(digest.Files, " "), strings.Join(digest.Commands, "\n")}, "\n")
	if _, err = tx.Exec(`INSERT INTO digests(title, body, terms, card, project) VALUES(?, ?, ?, ?, ?)`, title, body, agentmemory.IdentifierTerms(title, body), card.ID, card.Project); err != nil {
		return IndexResult{}, err
	}
	if err = tx.Commit(); err != nil {
		return IndexResult{}, err
	}
	return IndexResult{Added: len(observations), Full: full}, nil
}

// UpdateCard refreshes a conversation's metadata (title, lane, archived)
// without reindexing its messages.
func (x *Index) UpdateCard(card Card) error {
	if !x.Exists() {
		return nil
	}
	db, err := x.open()
	if err != nil {
		return err
	}
	_, err = db.Exec(`UPDATE cards SET title = ?, lane = ?, archived = ?, last_activity_at = ? WHERE card = ?`,
		agentmemory.Clip(card.Title, agentmemory.MaxTitleBytes), card.Lane, boolInt(card.Archived), card.LastActivityAt, card.ID)
	return err
}

// ForgetCard deletes a conversation's rows.
func (x *Index) ForgetCard(cardID string) error {
	if !x.Exists() {
		return nil
	}
	db, err := x.open()
	if err != nil {
		return err
	}
	_, err = db.Exec(`DELETE FROM observations WHERE card = ?1; DELETE FROM digests WHERE card = ?1; DELETE FROM cards WHERE card = ?1;`, cardID)
	return err
}

// ForgetProject deletes a project's conversation rows (not its saved
// memories, which replicate).
func (x *Index) ForgetProject(projectID string) error {
	if !x.Exists() {
		return nil
	}
	db, err := x.open()
	if err != nil {
		return err
	}
	_, err = db.Exec(`DELETE FROM observations WHERE project = ?1; DELETE FROM digests WHERE project = ?1; DELETE FROM cards WHERE project = ?1;`, projectID)
	return err
}

// IndexedCard is a conversation's index state.
type IndexedCard struct {
	ID, Project, LastMessage, IndexedAt, LastActivityAt, Lane, Title string
	Archived                                                         bool
	Messages, Observations                                           int
}

// Cards lists a project's indexed conversations.
func (x *Index) Cards(projectID string) ([]IndexedCard, error) {
	if !x.Exists() {
		return nil, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT card, project, last_message, indexed_at, last_activity_at, lane, title, archived, messages, observations FROM cards WHERE project = ? ORDER BY card`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []IndexedCard
	for rows.Next() {
		var card IndexedCard
		var archived int
		if err = rows.Scan(&card.ID, &card.Project, &card.LastMessage, &card.IndexedAt, &card.LastActivityAt, &card.Lane, &card.Title, &archived, &card.Messages, &card.Observations); err != nil {
			return nil, err
		}
		card.Archived = archived == 1
		out = append(out, card)
	}
	return out, rows.Err()
}

// ProjectStats summarizes a project's index.
type ProjectStats struct {
	Cards        int
	Observations int64
	LastIndexed  string
}

// Stats summarizes a project's index rows.
func (x *Index) Stats(projectID string) (ProjectStats, error) {
	var stats ProjectStats
	if !x.Exists() {
		return stats, nil
	}
	db, err := x.open()
	if err != nil {
		return stats, err
	}
	var last sql.NullString
	err = db.QueryRow(`SELECT count(*), coalesce(sum(observations), 0), max(indexed_at) FROM cards WHERE project = ?`, projectID).Scan(&stats.Cards, &stats.Observations, &last)
	stats.LastIndexed = last.String
	return stats, err
}

// Meta reads a value of the index's metadata (per-project dream state).
func (x *Index) Meta(key string) (string, error) {
	if !x.Exists() {
		return "", nil
	}
	db, err := x.open()
	if err != nil {
		return "", err
	}
	var value string
	err = db.QueryRow(`SELECT value FROM meta WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return value, err
}

// SetMeta writes a metadata value.
func (x *Index) SetMeta(key, value string) error {
	db, err := x.open()
	if err != nil {
		return err
	}
	_, err = db.Exec(`INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

// Enforce applies the index bounds: while over MaxObservations or MaxBytes it
// evicts the oldest observations, archived conversations first.
func (x *Index) Enforce() (int, error) {
	if !x.Exists() {
		return 0, nil
	}
	db, err := x.open()
	if err != nil {
		return 0, err
	}
	var count int64
	if err = db.QueryRow(`SELECT count(*) FROM observations`).Scan(&count); err != nil {
		return 0, err
	}
	excess := count - MaxObservations
	if x.Size() > MaxBytes && excess < count/10 {
		excess = count / 10
	}
	if excess <= 0 {
		return 0, nil
	}
	result, err := db.Exec(`DELETE FROM observations WHERE rowid IN (
  SELECT o.rowid FROM observations o JOIN cards c ON c.card = o.card
  ORDER BY c.archived DESC, c.last_activity_at ASC, o.seq ASC LIMIT ?)`, excess)
	if err != nil {
		return 0, err
	}
	removed, _ := result.RowsAffected()
	return int(removed), nil
}

func mergeStrings(current, next []string, limit int) []string {
	seen := map[string]bool{}
	var out []string
	for _, list := range [][]string{current, next} {
		for _, value := range list {
			if !seen[value] && len(out) < limit {
				seen[value] = true
				out = append(out, value)
			}
		}
	}
	return out
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

// FinalAnswer is a conversation's latest final answer as indexed.
func (x *Index) FinalAnswer(cardID string) (string, error) {
	if !x.Exists() {
		return "", nil
	}
	db, err := x.open()
	if err != nil {
		return "", err
	}
	var answer string
	err = db.QueryRow(`SELECT final_answer FROM cards WHERE card = ?`, cardID).Scan(&answer)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return answer, err
}
