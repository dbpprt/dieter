// Command memory-index prototypes a memory layer built into the Dieter daemon:
// the same observation mapping as the agentmemory and OpenViking spikes, an
// SQLite FTS5 index (modernc.org/sqlite, already a Dieter dependency, pure
// Go) and BM25 recall grouped by card. No extra process, runtime download or
// model.
//
//	go run . -transcripts DIR [-dieter dieter] -db FILE -out eval.json CARD_ID...
//
// Transcripts are `dieter card transcript CARD` JSON files (DIR/CARD.json); a
// missing one is fetched with the CLI and cached.
package main

import (
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type part struct {
	Type          string          `json:"type"`
	Text          string          `json:"text"`
	State         string          `json:"state"`
	ToolName      string          `json:"toolName"`
	Input         json.RawMessage `json:"input"`
	Output        json.RawMessage `json:"output"`
	InputPreview  string          `json:"inputPreview"`
	OutputPreview string          `json:"outputPreview"`
	ErrorText     string          `json:"errorText"`
}

type message struct {
	ID    string `json:"id"`
	Role  string `json:"role"`
	Parts []part `json:"parts"`
}

type transcript struct {
	Detail struct {
		Card struct {
			ID       string `json:"id"`
			Title    string `json:"title"`
			Provider string `json:"provider"`
		} `json:"card"`
	} `json:"detail"`
	Conversation struct {
		Messages []message `json:"messages"`
	} `json:"conversation"`
}

type observation struct{ kind, body string }

func clip(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "…"
}

func payload(raw json.RawMessage, preview string) string {
	if len(raw) > 0 && string(raw) != "null" {
		return string(raw)
	}
	return preview
}

// observations is the mapping from the agentmemory spike: prompts, tool
// results, failures and the last answer of each reply; never reasoning.
func observations(messages []message) []observation {
	var out []observation
	for _, m := range messages {
		if m.Role == "user" {
			var texts []string
			for _, p := range m.Parts {
				if p.Type == "text" && strings.TrimSpace(p.Text) != "" {
					texts = append(texts, p.Text)
				}
			}
			if len(texts) > 0 {
				out = append(out, observation{"prompt", clip(strings.Join(texts, "\n"), 4000)})
			}
			continue
		}
		if m.Role != "assistant" {
			continue
		}
		last := ""
		for _, p := range m.Parts {
			if p.Type == "text" && strings.TrimSpace(p.Text) != "" {
				last = p.Text
			}
			if p.Type != "dynamic-tool" && !strings.HasPrefix(p.Type, "tool-") {
				continue
			}
			name := p.ToolName
			if name == "" {
				name = strings.TrimPrefix(p.Type, "tool-")
			}
			input := clip(payload(p.Input, p.InputPreview), 4000)
			switch p.State {
			case "output-error":
				out = append(out, observation{"failure", name + " " + input + "\n" + clip(p.ErrorText+p.OutputPreview, 4000)})
			case "output-available":
				out = append(out, observation{"tool", name + " " + input + "\n" + clip(payload(p.Output, p.OutputPreview), 4000)})
			}
		}
		if strings.TrimSpace(last) != "" {
			out = append(out, observation{"answer", clip(last, 8000)})
		}
	}
	return out
}

var wordPattern = regexp.MustCompile(`[\p{L}\p{N}_]+`)

var stopwords = map[string]bool{
	"a": true, "an": true, "and": true, "are": true, "as": true, "at": true, "be": true, "but": true, "by": true,
	"do": true, "does": true, "for": true, "from": true, "how": true, "i": true, "in": true, "into": true, "is": true,
	"it": true, "its": true, "my": true, "of": true, "on": true, "or": true, "our": true, "so": true, "that": true,
	"the": true, "their": true, "them": true, "then": true, "there": true, "this": true, "to": true, "until": true,
	"was": true, "we": true, "what": true, "when": true, "where": true, "which": true, "why": true, "with": true,
	"you": true, "instead": true, "every": true, "again": true, "one": true, "after": true,
}

// ftsQuery turns free text into an OR query of quoted terms: FTS5's default
// AND would drop every paraphrase that misses one word.
func ftsQuery(text string) string {
	var terms []string
	seen := map[string]bool{}
	for _, word := range wordPattern.FindAllString(strings.ToLower(text), -1) {
		if stopwords[word] || len(word) < 2 || seen[word] {
			continue
		}
		seen[word] = true
		terms = append(terms, `"`+word+`"`)
	}
	return strings.Join(terms, " OR ")
}

type evalCase struct {
	Query    string
	Expected []string
}

// Same 18 cases as tools/spikes/agentmemory/eval.mjs.
var cases = []evalCase{
	{"Mac stays disconnected after waking from sleep", []string{"c_2c968e12cbcb9b753c743eda"}},
	{"card snaps back to its old lane after dragging until sync finishes", []string{"c_f655dd266c6bf6aa379543df", "c_9e3d656aa4b3f2d131fca4f8"}},
	{"typing lag and lost characters in the Android chat composer", []string{"c_4bc088a8ee14bc855ffa1bc6"}},
	{"make the gateway unable to read relayed traffic", []string{"c_f696fe71ce67323d7741f6ec"}},
	{"store passwords and one-time codes that agents can request", []string{"c_6a2336d6bad3fefbe6ae5256"}},
	{"conversation fails but works again when I send another message", []string{"c_d41d7d280d689caeef578e1f"}},
	{"screen share should reconnect instead of opening new connections on a flaky network", []string{"c_8c78397d41fe38c53be91c22"}},
	{"presented file opens again every time I return to the chat", []string{"c_3fc6bf8294de8e0d0721d3ab"}},
	{"notch covers the status badges in the top bar", []string{"c_bed9938a20d5a1217d47640e"}},
	{"background waiters never come back in Claude and Oh My Pi", []string{"c_37b6ecbfda981defda3292cc"}},
	{"quick task text disappears when opening more options on Android", []string{"c_a575740181cb5475bbd3ee31"}},
	{"do workflow runs or the repository leak credentials", []string{"c_610916ddd1068bae9cfed9c1"}},
	{"deploy the gateway from the main repository instead of the vps repo", []string{"c_6a6c24215b4b15574f9e8ecc"}},
	{"high CPU usage and slow clicks in the native Mac app", []string{"c_2abfac4aea13510623a02eff"}},
	{"move business rules into one shared Kotlin multiplatform layer", []string{"c_110345b8db323582a785d65c", "c_a86c9cfda23f3832fa62d8a6", "c_4bc088a8ee14bc855ffa1bc6"}},
	{"right click to delete a board on macOS", []string{"c_f99f060f1f5a34f598de4ec9"}},
	{"why are builds and emulator tests so slow", []string{"c_36e66b736dc63012924ecc47", "c_430635f7cbcff66f819c54fc", "c_30a95bc6b452a27db6712f01"}},
	{"remove board comments from the daemon and every client", []string{"c_e809195040376175efa46dd0"}},
}

// recall is what a memory_recall host tool would get from the daemon: the
// best cards for a query, each with its title and up to two matching
// snippets (FTS5 snippet(), bounded), as JSON on stdout.
func recall(dbPath, query string, limit int) {
	db, err := sql.Open("sqlite", "file:"+dbPath+"?mode=ro")
	if err != nil {
		panic(err)
	}
	defer db.Close()
	started := time.Now()
	rows, err := db.Query(`SELECT card, title, kind, snippet(observations, 3, '«', '»', ' … ', 40)
		FROM observations WHERE observations MATCH ? ORDER BY bm25(observations, 2.0, 1.0) LIMIT 200`, ftsQuery(query))
	if err != nil {
		panic(err)
	}
	type hit struct {
		Card     string   `json:"card"`
		Title    string   `json:"title"`
		Snippets []string `json:"snippets"`
	}
	var hits []*hit
	byCard := map[string]*hit{}
	for rows.Next() {
		var card, title, kind, snippet string
		_ = rows.Scan(&card, &title, &kind, &snippet)
		h := byCard[card]
		if h == nil {
			if len(hits) == limit {
				continue
			}
			h = &hit{Card: card, Title: title}
			byCard[card] = h
			hits = append(hits, h)
		}
		if len(h.Snippets) < 2 {
			h.Snippets = append(h.Snippets, kind+": "+clip(snippet, 500))
		}
	}
	rows.Close()
	encoded, _ := json.Marshal(map[string]any{"hits": hits, "ms": time.Since(started).Milliseconds()})
	fmt.Println(string(encoded))
}

func load(dir, dieter, card string) (transcript, error) {
	var t transcript
	path := filepath.Join(dir, card+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		raw, err = exec.Command(dieter, "card", "transcript", card).Output()
		if err != nil {
			return t, fmt.Errorf("transcript %s: %w", card, err)
		}
		_ = os.WriteFile(path, raw, 0o600)
	}
	err = json.Unmarshal(raw, &t)
	return t, err
}

func main() {
	transcripts := flag.String("transcripts", "", "directory of cached transcripts")
	dieter := flag.String("dieter", "dieter", "Dieter CLI")
	dbPath := flag.String("db", "", "index file (recreated)")
	out := flag.String("out", "", "eval result JSON")
	query := flag.String("query", "", "answer one recall query from an existing -db and exit")
	limit := flag.Int("limit", 6, "cards returned by -query")
	flag.Parse()
	if *query != "" {
		recall(*dbPath, *query, *limit)
		return
	}
	if err := os.MkdirAll(*transcripts, 0o700); err != nil {
		panic(err)
	}
	_ = os.Remove(*dbPath)
	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		panic(err)
	}
	defer db.Close()
	if _, err := db.Exec(`PRAGMA journal_mode=WAL;
		CREATE VIRTUAL TABLE observations USING fts5(card UNINDEXED, kind UNINDEXED, title, body, tokenize='porter unicode61');`); err != nil {
		panic(err)
	}

	started := time.Now()
	total := 0
	for _, card := range flag.Args() {
		t, err := load(*transcripts, *dieter, card)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			continue
		}
		tx, err := db.Begin()
		if err != nil {
			panic(err)
		}
		insert, err := tx.Prepare(`INSERT INTO observations(card, kind, title, body) VALUES (?, ?, ?, ?)`)
		if err != nil {
			panic(err)
		}
		for _, o := range observations(t.Conversation.Messages) {
			if _, err := insert.Exec(card, o.kind, t.Detail.Card.Title, o.body); err != nil {
				panic(err)
			}
			total++
		}
		insert.Close()
		if err := tx.Commit(); err != nil {
			panic(err)
		}
	}
	indexDuration := time.Since(started)
	if _, err := db.Exec(`INSERT INTO observations(observations) VALUES ('optimize')`); err != nil {
		panic(err)
	}
	info, _ := os.Stat(*dbPath)

	type row struct {
		Query string   `json:"query"`
		Rank  *int     `json:"rank"`
		Ms    float64  `json:"ms"`
		Top3  []string `json:"top3"`
	}
	var rows []row
	var latencies []float64
	// Title weight 2, body 1: the card title is a strong, short signal.
	search, err := db.Prepare(`SELECT card FROM observations WHERE observations MATCH ? ORDER BY bm25(observations, 2.0, 1.0) LIMIT 60`)
	if err != nil {
		panic(err)
	}
	for _, c := range cases {
		begin := time.Now()
		result, err := search.Query(ftsQuery(c.Query))
		if err != nil {
			panic(err)
		}
		var cards []string
		seen := map[string]bool{}
		for result.Next() {
			var card string
			_ = result.Scan(&card)
			if !seen[card] {
				seen[card] = true
				cards = append(cards, card)
			}
		}
		result.Close()
		ms := float64(time.Since(begin).Microseconds()) / 1000
		latencies = append(latencies, ms)
		r := row{Query: c.Query, Ms: ms}
		for index, card := range cards {
			for _, expected := range c.Expected {
				if card == expected && r.Rank == nil {
					rank := index + 1
					r.Rank = &rank
				}
			}
		}
		if len(cards) > 3 {
			cards = cards[:3]
		}
		r.Top3 = cards
		rows = append(rows, r)
	}
	hit := func(k int) int {
		n := 0
		for _, r := range rows {
			if r.Rank != nil && *r.Rank <= k {
				n++
			}
		}
		return n
	}
	mrr := 0.0
	for _, r := range rows {
		if r.Rank != nil {
			mrr += 1 / float64(*r.Rank)
		}
	}
	sort.Float64s(latencies)
	summary := map[string]any{
		"label":        "dieter-builtin-fts5-bm25",
		"cards":        len(flag.Args()),
		"observations": total,
		"indexSeconds": indexDuration.Seconds(),
		"msPerObs":     indexDuration.Seconds() * 1000 / float64(max(total, 1)),
		"dbBytes":      info.Size(),
		"cases":        len(rows),
		"hitAt1":       hit(1),
		"hitAt3":       hit(3),
		"hitAt5":       hit(5),
		"mrr":          float64(int(mrr/float64(len(rows))*1000)) / 1000,
		"p50ms":        latencies[len(latencies)/2],
		"maxMs":        latencies[len(latencies)-1],
	}
	for _, r := range rows {
		rank := "-"
		if r.Rank != nil {
			rank = fmt.Sprint(*r.Rank)
		}
		fmt.Fprintf(os.Stderr, "%s\t%.1fms\t%s\n", rank, r.Ms, r.Query)
	}
	encoded, _ := json.MarshalIndent(map[string]any{"summary": summary, "rows": rows}, "", "  ")
	if *out != "" {
		_ = os.WriteFile(*out, encoded, 0o644)
	}
	compact, _ := json.Marshal(summary)
	fmt.Println(string(compact))
}
