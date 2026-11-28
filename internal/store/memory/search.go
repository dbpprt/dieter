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
	// Vector is the query's embedding (internal/memory/embed); nil searches
	// by keywords only.
	Vector []float32
}

// Hit is one conversation that matches a query.
type Hit struct {
	CardID, Title, Lane, Harness, Scope, LastActivityAt, FinalAnswer, MessageID string
	Snippets                                                                    []string
	// Rank is the hit's 1-based position in this index's answer.
	Rank int
}

// Search recalls the project's conversations that best match the query.
// Keyword search fuses two BM25 rankings by reciprocal rank: individual
// observations (title, body and files) and the conversations' digests
// (brief, final answer, files touched, commands run). With a query vector,
// that ranking is fused the same way with the conversations ranked by their
// most similar title, prompt or final answer; a file filter keeps recall to
// keywords.
func (x *Index) Search(query Query) ([]Hit, error) {
	if !x.Exists() {
		return nil, nil
	}
	match := agentmemory.FTSQuery(query.Text)
	vector := query.Vector
	if len(query.Files) > 0 {
		vector = nil
	}
	if match == "" && vector == nil {
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
		keyword   float64
		keyed     bool
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
	if match != "" {
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
				value.keyword += 1 / float64(reciprocalRankBase+rank)
				value.keyed = true
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
				value := get(card)
				value.keyword += 1 / float64(reciprocalRankBase+rank)
				value.keyed = true
			}
			rows.Close()
			if err = rows.Err(); err != nil {
				return nil, err
			}
		}
	}
	var similar []vectorHit
	if vector != nil {
		if similar, err = x.vectorRanking(db, query.Project, vector); err != nil {
			return nil, err
		}
		for _, match := range similar {
			value := get(match.card)
			if value.messageID == "" {
				value.messageID = match.message
			}
			if len(value.snippets) == 0 && match.snippet != "" {
				value.snippets = append(value.snippets, match.snippet)
			}
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
	newer := func(a, b Hit) bool {
		if a.LastActivityAt != b.LastActivityAt {
			return a.LastActivityAt > b.LastActivityAt
		}
		return a.CardID < b.CardID
	}
	score := map[string]float64{}
	if len(similar) > 0 {
		// Fuse the keyword ranking with the vector ranking by reciprocal rank.
		var keyed []Hit
		for _, hit := range hits {
			if candidates[hit.CardID].keyed {
				keyed = append(keyed, hit)
			}
		}
		sort.SliceStable(keyed, func(i, j int) bool {
			left, right := candidates[keyed[i].CardID].keyword, candidates[keyed[j].CardID].keyword
			if left != right {
				return left > right
			}
			return newer(keyed[i], keyed[j])
		})
		for rank, hit := range keyed {
			score[hit.CardID] += 1 / float64(reciprocalRankBase+rank+1)
		}
		for rank, match := range similar {
			score[match.card] += 1 / float64(reciprocalRankBase+rank+1)
		}
	} else {
		for card, value := range candidates {
			score[card] = value.keyword
		}
	}
	sort.SliceStable(hits, func(i, j int) bool {
		left, right := score[hits[i].CardID], score[hits[j].CardID]
		if left != right {
			return left > right
		}
		return newer(hits[i], hits[j])
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
		if _, err = tx.Exec(`DELETE FROM memories WHERE id = ?1; DELETE FROM memory_revisions WHERE id = ?1; DELETE FROM memory_vectors WHERE id = ?1;`, id); err != nil {
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
// and returns their IDs, best first. With a query vector the BM25 ranking is
// fused with the memories' similarity (see PutMemoryVectors). kinds
// restricts the result.
func (x *Index) SearchMemories(projectID, text string, vector []float32, kinds []string, limit int) ([]string, error) {
	match := agentmemory.FTSQuery(text)
	if (match == "" && vector == nil) || !x.Exists() {
		return nil, nil
	}
	db, err := x.open()
	if err != nil {
		return nil, err
	}
	allowed := func(kind string) bool {
		if len(kinds) == 0 {
			return true
		}
		for _, wanted := range kinds {
			if wanted == kind {
				return true
			}
		}
		return false
	}
	var keyword []string
	if match != "" {
		rows, err := db.Query(`SELECT id, kind FROM memories WHERE memories MATCH ? AND project = ? ORDER BY bm25(memories, 2.0, 1.0) LIMIT ?`, match, projectID, limit*4)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id, kind string
			if err = rows.Scan(&id, &kind); err != nil {
				rows.Close()
				return nil, err
			}
			if allowed(kind) {
				keyword = append(keyword, id)
			}
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return nil, err
		}
	}
	if vector == nil {
		return keyword[:min(limit, len(keyword))], nil
	}
	similar, kindOf, err := memoryVectorRanking(db, projectID, vector)
	if err != nil {
		return nil, err
	}
	score := map[string]float64{}
	order := map[string]int{}
	add := func(list []string) {
		for rank, id := range list {
			score[id] += 1 / float64(reciprocalRankBase+rank+1)
			if _, ok := order[id]; !ok {
				order[id] = len(order)
			}
		}
	}
	add(keyword)
	var filtered []string
	for _, id := range similar {
		if allowed(kindOf[id]) {
			filtered = append(filtered, id)
		}
	}
	add(filtered)
	out := make([]string, 0, len(score))
	for id := range score {
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool {
		if score[out[i]] != score[out[j]] {
			return score[out[i]] > score[out[j]]
		}
		return order[out[i]] < order[out[j]]
	})
	return out[:min(limit, len(out))], nil
}
