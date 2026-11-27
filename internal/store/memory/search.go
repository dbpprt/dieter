package memory

import (
	"database/sql"
	"errors"
	"sort"
	"strings"

	agentmemory "github.com/dbpprt/dieter/internal/memory"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// Search bounds.
const (
	DefaultLimit       = 6
	MaxLimit           = 10
	maxSnippets        = 2
	snippetBytes       = 500
	finalAnswerBytes   = 600
	observationWindow  = 400
	digestWindow       = 100
	reciprocalRankBase = 60
)

// Query is a recall query against one project.
type Query struct {
	Project string
	Text    string
	Limit   int
	// Files restricts observations to those touching one of these files
	// (matched as a path suffix).
	Files []string
}

// Hit is one conversation that matches a query.
type Hit struct {
	CardID, Title, Lane, Harness, Scope, LastActivityAt, FinalAnswer, MessageID string
	Snippets                                                                    []string
	// Rank is the hit's 1-based position in this index's answer.
	Rank int
}

// Search recalls the project's conversations that best match the query. Two
// rankings are fused by reciprocal rank: individual observations (BM25 over
// title, body and files) and the conversations' digests (brief, final
// answer, files touched, commands run).
func (x *Index) Search(query Query) ([]Hit, error) {
	if !x.Exists() {
		return nil, nil
	}
	match := agentmemory.FTSQuery(query.Text)
	if match == "" {
		return nil, nil
	}
	limit := query.Limit
	if limit <= 0 {
		limit = DefaultLimit
	}
	if limit > MaxLimit {
		limit = MaxLimit
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	type candidate struct {
		score     float64
		snippets  []string
		messageID string
	}
	candidates := map[string]*candidate{}
	get := func(card string) *candidate {
		value := candidates[card]
		if value == nil {
			value = &candidate{}
			candidates[card] = value
		}
		return value
	}
	rows, err := db.Query(`SELECT card, message, files, snippet(observations, 1, '«', '»', ' … ', 40)
FROM observations WHERE observations MATCH ? AND project = ? ORDER BY bm25(observations, 2.0, 1.0, 1.0, 0.7) LIMIT ?`, match, query.Project, observationWindow)
	if err != nil {
		return nil, err
	}
	rank := 0
	seen := map[string]bool{}
	for rows.Next() {
		var card, message, files, snippet string
		if err = rows.Scan(&card, &message, &files, &snippet); err != nil {
			rows.Close()
			return nil, err
		}
		if len(query.Files) > 0 && !touches(files, query.Files) {
			continue
		}
		value := get(card)
		if !seen[card] {
			seen[card] = true
			rank++
			value.score += 1 / float64(reciprocalRankBase+rank)
			value.messageID = message
		}
		if len(value.snippets) < maxSnippets {
			value.snippets = append(value.snippets, agentmemory.Clip(strings.TrimSpace(snippet), snippetBytes))
		}
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if len(query.Files) == 0 {
		rows, err = db.Query(`SELECT card FROM digests WHERE digests MATCH ? AND project = ? ORDER BY bm25(digests, 2.0, 1.0, 0.7) LIMIT ?`, match, query.Project, digestWindow)
		if err != nil {
			return nil, err
		}
		rank = 0
		for rows.Next() {
			var card string
			if err = rows.Scan(&card); err != nil {
				rows.Close()
				return nil, err
			}
			rank++
			get(card).score += 1 / float64(reciprocalRankBase+rank)
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return nil, err
		}
	}
	var hits []Hit
	for card, value := range candidates {
		hit := Hit{CardID: card, Snippets: value.snippets, MessageID: value.messageID}
		err = db.QueryRow(`SELECT title, lane, harness, scope, last_activity_at, final_answer FROM cards WHERE card = ?`, card).
			Scan(&hit.Title, &hit.Lane, &hit.Harness, &hit.Scope, &hit.LastActivityAt, &hit.FinalAnswer)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, err
		}
		hit.FinalAnswer = agentmemory.Clip(hit.FinalAnswer, finalAnswerBytes)
		hits = append(hits, hit)
	}
	sort.SliceStable(hits, func(i, j int) bool {
		left, right := candidates[hits[i].CardID].score, candidates[hits[j].CardID].score
		if left != right {
			return left > right
		}
		return hits[i].LastActivityAt > hits[j].LastActivityAt
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	for index := range hits {
		hits[index].Rank = index + 1
	}
	return hits, nil
}

func touches(files string, wanted []string) bool {
	for _, file := range strings.Fields(files) {
		for _, candidate := range wanted {
			candidate = strings.TrimPrefix(strings.TrimSpace(candidate), "./")
			if candidate != "" && (file == candidate || strings.HasSuffix(file, "/"+candidate) || strings.HasSuffix(candidate, "/"+file)) {
				return true
			}
		}
	}
	return false
}

// RecordRecall counts that these conversations were recalled; dreams list
// often-recalled conversations first.
func (x *Index) RecordRecall(cardIDs []string) {
	if !x.Exists() || len(cardIDs) == 0 {
		return
	}
	db, err := x.open()
	if err != nil {
		return
	}
	for _, card := range cardIDs {
		_, _ = db.Exec(`UPDATE cards SET recalls = recalls + 1 WHERE card = ?`, card)
	}
}

// Recalls returns how often each of a project's conversations was recalled.
func (x *Index) Recalls(projectID string) (map[string]int, error) {
	out := map[string]int{}
	if !x.Exists() {
		return out, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT card, recalls FROM cards WHERE project = ? AND recalls > 0`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var card string
		var count int
		if err = rows.Scan(&card, &count); err != nil {
			return nil, err
		}
		out[card] = count
	}
	return out, rows.Err()
}

// SyncMemories mirrors a project's replicated saved memories into the index:
// active, unexpired memories are searchable; the rest leave the mirror. Only
// changed revisions are rewritten.
func (x *Index) SyncMemories(projectID string, memories []kv.SavedMemory, now string) error {
	db, err := x.open()
	if err != nil {
		return err
	}
	current := map[string]string{}
	rows, err := db.Query(`SELECT id, revision FROM memory_revisions WHERE project = ?`, projectID)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id, revision string
		if err = rows.Scan(&id, &revision); err != nil {
			rows.Close()
			return err
		}
		current[id] = revision
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	wanted := map[string]kv.SavedMemory{}
	for _, memory := range memories {
		if memory.Record.Status != schema.MemoryActive || (memory.Record.ExpiresAt != "" && memory.Record.ExpiresAt <= now) {
			continue
		}
		wanted[memory.ID] = memory
	}
	changed := false
	for id, memory := range wanted {
		if current[id] != memory.Revision {
			changed = true
			break
		}
	}
	for id := range current {
		if _, ok := wanted[id]; !ok {
			changed = true
			break
		}
	}
	if !changed {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for id, revision := range current {
		memory, ok := wanted[id]
		if ok && memory.Revision == revision {
			continue
		}
		if _, err = tx.Exec(`DELETE FROM memories WHERE id = ?1; DELETE FROM memory_revisions WHERE id = ?1;`, id); err != nil {
			return err
		}
	}
	for id, memory := range wanted {
		if current[id] == memory.Revision {
			continue
		}
		if _, err = tx.Exec(`INSERT INTO memories(content, files, id, project, kind) VALUES(?, ?, ?, ?, ?)`, memory.Record.Content, strings.Join(memory.Record.Files, " "), id, projectID, memory.Record.Kind); err != nil {
			return err
		}
		if _, err = tx.Exec(`INSERT INTO memory_revisions(id, project, revision) VALUES(?, ?, ?)`, id, projectID, memory.Revision); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SearchMemories ranks a project's mirrored saved memories against a query
// and returns their IDs, best first. kinds restricts the result.
func (x *Index) SearchMemories(projectID, text string, kinds []string, limit int) ([]string, error) {
	match := agentmemory.FTSQuery(text)
	if match == "" || !x.Exists() {
		return nil, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT id, kind FROM memories WHERE memories MATCH ? AND project = ? ORDER BY bm25(memories, 2.0, 1.0) LIMIT ?`, match, projectID, limit*4)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	allowed := map[string]bool{}
	for _, kind := range kinds {
		allowed[kind] = true
	}
	var out []string
	for rows.Next() {
		var id, kind string
		if err = rows.Scan(&id, &kind); err != nil {
			return nil, err
		}
		if len(allowed) > 0 && !allowed[kind] {
			continue
		}
		out = append(out, id)
		if len(out) == limit {
			break
		}
	}
	return out, rows.Err()
}
