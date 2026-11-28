package memory

import (
	"database/sql"
	"errors"
	"fmt"
	"hash/fnv"
	"sort"
	"strings"

	agentmemory "github.com/dbpprt/dieter/internal/memory"
	"github.com/dbpprt/dieter/internal/memory/embed"
)

// Vector search bounds.
const (
	// vectorWindow is how many conversations the vector ranking contributes.
	vectorWindow = 50
	// vectorFloor drops vector matches that are no real match: unrelated
	// texts score about 0–0.15 with this model.
	vectorFloor = 0.2
	// vectorModelKey records which model computed the stored vectors.
	vectorModelKey = "vector_model"
)

const vectorSchemaSQL = `
CREATE TABLE IF NOT EXISTS vectors (
  card TEXT NOT NULL,
  project TEXT NOT NULL,
  message TEXT NOT NULL,
  part INTEGER NOT NULL,
  hash TEXT NOT NULL,
  snippet TEXT NOT NULL,
  vector BLOB NOT NULL,
  PRIMARY KEY (card, message, part)
);
CREATE INDEX IF NOT EXISTS vectors_project ON vectors(project);
CREATE TABLE IF NOT EXISTS memory_vectors (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  revision TEXT NOT NULL,
  vector BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_vectors_project ON memory_vectors(project);
`

// Text is a conversation text that recall embeds: the title (Message "") or
// a prompt or final answer observation. Tool calls and outputs are left to
// keyword search; embedding them costs about thirty times more for no better
// recall (tools/spikes/memory-embeddings).
type Text struct {
	Message string
	Part    int
	Body    string
}

func (t Text) hash() string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(t.Body))
	return fmt.Sprintf("%016x", h.Sum64())
}

// checkVectorModel discards the stored vectors when another model computed
// them (on open); the indexer recomputes them.
func checkVectorModel(db *sql.DB) error {
	var current string
	err := db.QueryRow(`SELECT value FROM meta WHERE key = ?`, vectorModelKey).Scan(&current)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if current == embed.ID {
		return nil
	}
	_, err = db.Exec(`DELETE FROM vectors; DELETE FROM memory_vectors;
INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;`, vectorModelKey, embed.ID)
	return err
}

// HasVectors reports whether a conversation's texts were embedded.
func (x *Index) HasVectors(cardID string) (bool, error) {
	if !x.Exists() {
		return false, nil
	}
	db, err := x.open()
	if err != nil {
		return false, err
	}
	var found int
	err = db.QueryRow(`SELECT count(*) FROM (SELECT 1 FROM vectors WHERE card = ? LIMIT 1)`, cardID).Scan(&found)
	return found > 0, err
}

// CardsWithVectors lists a project's conversations whose texts were
// embedded.
func (x *Index) CardsWithVectors(projectID string) (map[string]bool, error) {
	out := map[string]bool{}
	if !x.Exists() {
		return out, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT DISTINCT card FROM vectors WHERE project = ?`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var card string
		if err = rows.Scan(&card); err != nil {
			return nil, err
		}
		out[card] = true
	}
	return out, rows.Err()
}

// MissingVectors returns the texts of a conversation that have no stored
// vector for their current content.
func (x *Index) MissingVectors(cardID string, texts []Text) ([]Text, error) {
	if len(texts) == 0 {
		return nil, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT message, part, hash FROM vectors WHERE card = ?`, cardID)
	if err != nil {
		return nil, err
	}
	stored := map[string]string{}
	for rows.Next() {
		var message, hash string
		var part int
		if err = rows.Scan(&message, &part, &hash); err != nil {
			rows.Close()
			return nil, err
		}
		stored[fmt.Sprintf("%s\x00%d", message, part)] = hash
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	var out []Text
	for _, text := range texts {
		if strings.TrimSpace(text.Body) == "" {
			continue
		}
		if stored[fmt.Sprintf("%s\x00%d", text.Message, text.Part)] != text.hash() {
			out = append(out, text)
		}
	}
	return out, nil
}

// PutVectors stores the vectors of a conversation's texts. A conversation
// that was forgotten meanwhile stays forgotten.
func (x *Index) PutVectors(cardID, projectID string, texts []Text, vectors [][]float32) error {
	if len(texts) != len(vectors) {
		return fmt.Errorf("%d texts, %d vectors", len(texts), len(vectors))
	}
	if len(texts) == 0 {
		return nil
	}
	db, err := x.open()
	if err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var known int
	if err = tx.QueryRow(`SELECT count(*) FROM cards WHERE card = ?`, cardID).Scan(&known); err != nil || known == 0 {
		return err
	}
	insert, err := tx.Prepare(`INSERT INTO vectors(card, project, message, part, hash, snippet, vector) VALUES(?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(card, message, part) DO UPDATE SET project = excluded.project, hash = excluded.hash, snippet = excluded.snippet, vector = excluded.vector`)
	if err != nil {
		return err
	}
	defer insert.Close()
	for i, text := range texts {
		if _, err = insert.Exec(cardID, projectID, text.Message, text.Part, text.hash(), agentmemory.Clip(strings.TrimSpace(text.Body), snippetBytes), embed.Quantize(vectors[i])); err != nil {
			return err
		}
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	x.invalidateVectors(projectID)
	return nil
}

type storedVector struct {
	card, message, snippet string
	vector                 []byte
}

type vectorHit struct {
	card, message, snippet string
	score                  float32
}

func (x *Index) invalidateVectors(projectID string) {
	x.vectorMu.Lock()
	defer x.vectorMu.Unlock()
	if projectID == "" {
		x.vectorCache = nil
		return
	}
	delete(x.vectorCache, projectID)
}

// projectVectors returns a project's stored vectors, cached until they
// change.
func (x *Index) projectVectors(db *sql.DB, projectID string) ([]storedVector, error) {
	x.vectorMu.Lock()
	cached, ok := x.vectorCache[projectID]
	x.vectorMu.Unlock()
	if ok {
		return cached, nil
	}
	rows, err := db.Query(`SELECT card, message, snippet, vector FROM vectors WHERE project = ?`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []storedVector
	for rows.Next() {
		var stored storedVector
		if err = rows.Scan(&stored.card, &stored.message, &stored.snippet, &stored.vector); err != nil {
			return nil, err
		}
		out = append(out, stored)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	x.vectorMu.Lock()
	if x.vectorCache == nil {
		x.vectorCache = map[string][]storedVector{}
	}
	x.vectorCache[projectID] = out
	x.vectorMu.Unlock()
	return out, nil
}

// vectorRanking ranks a project's conversations by their best matching
// text, best first.
func (x *Index) vectorRanking(db *sql.DB, projectID string, query []float32) ([]vectorHit, error) {
	stored, err := x.projectVectors(db, projectID)
	if err != nil {
		return nil, err
	}
	best := map[string]vectorHit{}
	for _, entry := range stored {
		score := embed.Dot(query, entry.vector)
		if score < vectorFloor {
			continue
		}
		if current, ok := best[entry.card]; !ok || score > current.score {
			best[entry.card] = vectorHit{card: entry.card, message: entry.message, snippet: entry.snippet, score: score}
		}
	}
	out := make([]vectorHit, 0, len(best))
	for _, hit := range best {
		out = append(out, hit)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].score != out[j].score {
			return out[i].score > out[j].score
		}
		return out[i].card < out[j].card
	})
	if len(out) > vectorWindow {
		out = out[:vectorWindow]
	}
	return out, nil
}

// pruneVectors drops the vectors whose observations were evicted.
func (x *Index) pruneVectors(db *sql.DB) error {
	rows, err := db.Query(`SELECT DISTINCT card, message FROM observations`)
	if err != nil {
		return err
	}
	present := map[string]bool{}
	for rows.Next() {
		var card, message string
		if err = rows.Scan(&card, &message); err != nil {
			rows.Close()
			return err
		}
		present[card+"\x00"+message] = true
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	rows, err = db.Query(`SELECT DISTINCT card, message FROM vectors WHERE message != ''`)
	if err != nil {
		return err
	}
	var stale [][2]string
	for rows.Next() {
		var card, message string
		if err = rows.Scan(&card, &message); err != nil {
			rows.Close()
			return err
		}
		if !present[card+"\x00"+message] {
			stale = append(stale, [2]string{card, message})
		}
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, key := range stale {
		if _, err = db.Exec(`DELETE FROM vectors WHERE card = ? AND message = ?`, key[0], key[1]); err != nil {
			return err
		}
	}
	if len(stale) > 0 {
		x.invalidateVectors("")
	}
	return nil
}

// MemoryText is a saved memory that has no vector for its revision.
type MemoryText struct {
	ID, Revision, Content string
}

// MissingMemoryVectors returns a project's mirrored saved memories that have
// no vector for their current revision.
func (x *Index) MissingMemoryVectors(projectID string) ([]MemoryText, error) {
	if !x.Exists() {
		return nil, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT m.id, r.revision, m.content FROM memories m JOIN memory_revisions r ON r.id = m.id
LEFT JOIN memory_vectors v ON v.id = m.id AND v.revision = r.revision
WHERE m.project = ? AND v.id IS NULL`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MemoryText
	for rows.Next() {
		var text MemoryText
		if err = rows.Scan(&text.ID, &text.Revision, &text.Content); err != nil {
			return nil, err
		}
		out = append(out, text)
	}
	return out, rows.Err()
}

// PutMemoryVectors stores saved memories' vectors.
func (x *Index) PutMemoryVectors(projectID string, texts []MemoryText, vectors [][]float32) error {
	if len(texts) != len(vectors) {
		return fmt.Errorf("%d memories, %d vectors", len(texts), len(vectors))
	}
	if len(texts) == 0 {
		return nil
	}
	db, err := x.open()
	if err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for i, text := range texts {
		if _, err = tx.Exec(`INSERT INTO memory_vectors(id, project, revision, vector) VALUES(?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET project = excluded.project, revision = excluded.revision, vector = excluded.vector`,
			text.ID, projectID, text.Revision, embed.Quantize(vectors[i])); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// memoryVectorRanking ranks a project's saved memories by similarity, best
// first, with their kinds.
func memoryVectorRanking(db *sql.DB, projectID string, query []float32) ([]string, map[string]string, error) {
	rows, err := db.Query(`SELECT v.id, m.kind, v.vector FROM memory_vectors v JOIN memories m ON m.id = v.id WHERE v.project = ?`, projectID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	type scored struct {
		id    string
		score float32
	}
	var all []scored
	kinds := map[string]string{}
	for rows.Next() {
		var id, kind string
		var vector []byte
		if err = rows.Scan(&id, &kind, &vector); err != nil {
			return nil, nil, err
		}
		if score := embed.Dot(query, vector); score >= vectorFloor {
			all = append(all, scored{id, score})
			kinds[id] = kind
		}
	}
	if err = rows.Err(); err != nil {
		return nil, nil, err
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].score != all[j].score {
			return all[i].score > all[j].score
		}
		return all[i].id < all[j].id
	})
	out := make([]string, len(all))
	for i, entry := range all {
		out[i] = entry.id
	}
	return out, kinds, nil
}
