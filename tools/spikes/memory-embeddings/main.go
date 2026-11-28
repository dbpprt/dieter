// Command memory-embeddings evaluates agent memory recall as the daemon runs
// it: the production index (internal/store/memory) and embeddings
// (internal/memory/embed), keyword-only against hybrid, on the recall
// fixture and on real conversations read with the Dieter CLI. See README.md
// and RESULTS.md (the spike that chose the model).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/memory/embed"
	"github.com/dbpprt/dieter/internal/model"
	storememory "github.com/dbpprt/dieter/internal/store/memory"
)

const project = "p_eval"

type conversation struct {
	id, title, brief, updated string
	messages                  []model.UIMessage
}

type query struct {
	Text     string   `json:"query"`
	Expected []string `json:"expected"`
}

type corpus struct {
	name          string
	conversations []conversation
	queries       []query
}

// The real-history questions (tools/spikes/memory-index, tools/spikes/agentmemory).
var historyQueries = []query{
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
	// Set B (2026-11-28): one question per randomly sampled conversation,
	// written from its title and first prompt only, before any ranking.
	{"make the diff view header match the boards header and show more per row", []string{"c_796faa71d6c2a27f0b8ba163"}},
	{"AI code review of pull requests built into Dieter", []string{"c_20f6911184ef22d7cc1f8add"}},
	{"verify the worktree changes on macOS after pulling", []string{"c_cf7da56849d343d41792a895"}},
	{"Android usage screen looks ugly and wastes space", []string{"c_ed7dd62281583ac43a22522d"}},
	{"copy-on-write filesystem instead of git worktrees for agents", []string{"c_da5fc287565aef86b9d58c8f"}},
	{"swipe to archive in the mobile inbox and list running work before pinned", []string{"c_1d54cbc12d83b14c129ad10c"}},
	{"Mac chat shows stale state instead of updating live", []string{"c_04f996ac51c4540a554050e9", "c_e0deebade8aa42afae023f81"}},
	{"what is missing for Dieter to be a commercial product", []string{"c_af44e9874be29c4d414a5025"}},
	{"daemon unavailable until someone logs in after a Mac reboot", []string{"c_695647dfd8716417f55d5c47"}},
	{"per-platform layouts while keeping iOS and Android at feature parity", []string{"c_61e7b2288616a5db2994da4b"}},
	{"replace the slow device test suites with Maestro flows", []string{"c_9b23720d82733947e0c8731b"}},
	{"share a screenshot from another Android app into a new task", []string{"c_439b42811bde20e59ee70ace"}},
	{"keep a folder in sync between the Mac and the phone", []string{"c_d3faf74dae33725f7a9a1d08"}},
	{"sign in to a provider account on a remote machine from the Dieter app", []string{"c_615f7f33bf8349d3c617888d"}},
	{"add people as internal TestFlight testers for every build", []string{"c_f399c6cecbeaa67eda3ad5e6"}},
	// Both maintenance conversations answer it (label widened after the first run).
	{"update all dependencies to their latest versions", []string{"c_b1f63038130cadd1032e2ccb", "c_5327c9462a83d854a42d728d"}},
	{"VPN makes the gateway connection unstable", []string{"c_90ae6886716d8809baaf56e1"}},
	{"replace the separate iOS and Android apps with one shared Compose UI", []string{"c_7d8bb20207a8e0559f964773", "c_2294a169cad78c68973c52b4"}},
	{"chats that don't belong to a project but still show up in the inbox", []string{"c_49b9d4b5e5195841d95f3ff2"}},
	{"why did an Oh My Pi task hang and how to prevent it", []string{"c_c34669649ec088bca180a9b0"}},
	{"every CI job failing on a pull request", []string{"c_07cd1bb84eac7fbd38204355"}},
	{"Claude keeps returning authentication errors", []string{"c_91dcb0d3715e860e7ff284fc"}},
	{"Android inbox rows only refresh after tapping them, no live change feed", []string{"c_e0deebade8aa42afae023f81", "c_04f996ac51c4540a554050e9"}},
}

// historySetA is the number of questions from the earlier spikes.
const historySetA = 18

func fixtureCorpus(path string) corpus {
	raw, err := os.ReadFile(path)
	check(err)
	var fixture struct {
		Conversations []struct {
			ID, Title, Prompt, Tool, Answer string
			Files                           []string
		}
		Queries []struct{ Query, Answer string }
	}
	check(json.Unmarshal(raw, &fixture))
	c := corpus{name: "fixture"}
	for _, f := range fixture.Conversations {
		input := map[string]string{"command": "go test ./..."}
		if len(f.Files) > 0 {
			input = map[string]string{"file_path": f.Files[0]}
		}
		in, _ := json.Marshal(input)
		out, _ := json.Marshal(f.Tool)
		c.conversations = append(c.conversations, conversation{id: f.ID, title: f.Title, brief: f.Prompt, messages: []model.UIMessage{
			{ID: f.ID + "_u", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: f.Prompt}}},
			{ID: f.ID + "_a", Role: "assistant", Parts: []model.UIMessagePart{
				{Type: "dynamic-tool", ToolName: "Read", State: "output-available", Input: in, Output: out},
				{Type: "text", Text: f.Answer},
			}},
		}})
	}
	for _, q := range fixture.Queries {
		c.queries = append(c.queries, query{Text: q.Query, Expected: []string{q.Answer}})
	}
	return c
}

// historyCorpus reads conversations with the Dieter CLI (read-only), caching
// each transcript.
func historyCorpus(cardsFile, cache, dieter string, exclude map[string]bool) corpus {
	raw, err := os.ReadFile(cardsFile)
	check(err)
	check(os.MkdirAll(cache, 0o700))
	c := corpus{name: "history", queries: historyQueries}
	for _, id := range strings.Fields(string(raw)) {
		if exclude[id] {
			continue
		}
		path := filepath.Join(cache, id+".json")
		data, err := os.ReadFile(path)
		if err != nil {
			data, err = exec.Command(dieter, "card", "transcript", id).Output()
			if err != nil {
				fmt.Fprintln(os.Stderr, "skip", id, err)
				continue
			}
			_ = os.WriteFile(path, data, 0o600)
		}
		var t struct {
			Detail struct {
				Card struct{ Title, InitialPrompt string } `json:"card"`
			} `json:"detail"`
			Conversation struct {
				UpdatedAt string `json:"updatedAt"`
				Messages  []struct {
					ID    string `json:"id"`
					Role  string `json:"role"`
					Parts []struct {
						Type          string `json:"type"`
						Text          string `json:"text"`
						State         string `json:"state"`
						ToolName      string `json:"toolName"`
						InputPreview  string `json:"inputPreview"`
						OutputPreview string `json:"outputPreview"`
						ErrorText     string `json:"errorText"`
					} `json:"parts"`
				} `json:"messages"`
			} `json:"conversation"`
		}
		if json.Unmarshal(data, &t) != nil {
			continue
		}
		conv := conversation{id: id, title: t.Detail.Card.Title, brief: t.Detail.Card.InitialPrompt, updated: t.Conversation.UpdatedAt}
		for _, m := range t.Conversation.Messages {
			msg := model.UIMessage{ID: m.ID, Role: m.Role}
			for _, p := range m.Parts {
				part := model.UIMessagePart{Type: p.Type, Text: p.Text, State: p.State, ToolName: p.ToolName, ErrorText: p.ErrorText}
				if p.InputPreview != "" {
					part.Input, _ = json.Marshal(p.InputPreview)
				}
				if p.OutputPreview != "" {
					part.Output, _ = json.Marshal(p.OutputPreview)
				}
				msg.Parts = append(msg.Parts, part)
			}
			conv.messages = append(conv.messages, msg)
		}
		c.conversations = append(c.conversations, conv)
	}
	return c
}

type metrics struct {
	Mode  string  `json:"mode"`
	Hit1  float64 `json:"hitAt1"`
	Hit3  float64 `json:"hitAt3"`
	Hit5  float64 `json:"hitAt5"`
	MRR   float64 `json:"mrr"`
	Ranks []int   `json:"ranks"`
	P50Ms float64 `json:"queryMsP50"`
}

func main() {
	fixture := flag.String("fixture", "tests/fixtures/memory/recall.json", "recall fixture")
	cards := flag.String("cards", "", "file of conversation ids for the history corpus")
	cache := flag.String("transcripts", "", "transcript cache directory")
	dieter := flag.String("dieter", "dieter", "Dieter CLI")
	exclude := flag.String("exclude", "", "comma-separated ids left out of the history corpus")
	out := flag.String("out", "", "result JSON")
	flag.Parse()

	corpora := []corpus{fixtureCorpus(*fixture)}
	if *cards != "" {
		skip := map[string]bool{}
		for _, id := range strings.Split(*exclude, ",") {
			skip[strings.TrimSpace(id)] = true
		}
		corpora = append(corpora, historyCorpus(*cards, *cache, *dieter, skip))
	}
	encoder, err := embed.Load()
	check(err)
	report := map[string]any{"date": time.Now().UTC().Format(time.RFC3339), "model": embed.ID, "backend": embed.Backend()}
	for _, c := range corpora {
		dir, err := os.MkdirTemp("", "memory-eval-")
		check(err)
		index := storememory.New(dir)
		var indexing, embedding time.Duration
		texts := 0
		for _, conv := range c.conversations {
			started := time.Now()
			result, err := index.IndexCard(storememory.Card{ID: conv.id, Project: project, Title: conv.title, Lane: "done", Harness: "claude-code", Scope: "board", LastActivityAt: conv.updated, Brief: conv.brief}, conv.messages, false)
			check(err)
			indexing += time.Since(started)
			started = time.Now()
			vectors := make([][]float32, len(result.Texts))
			for i, text := range result.Texts {
				vectors[i] = encoder.Embed(text.Body)
			}
			embedding += time.Since(started)
			texts += len(result.Texts)
			check(index.PutVectors(conv.id, project, result.Texts, vectors))
		}
		section := map[string]any{
			"conversations": len(c.conversations), "texts": texts,
			"indexSeconds": seconds(indexing), "embedSeconds": seconds(embedding),
			"embedMsPerText": seconds(embedding) * 1000 / float64(max(texts, 1)),
		}
		fmt.Printf("\n== %s: %d conversations, %d texts embedded in %.1f s (%s, %.1f ms/text, one core)\n",
			c.name, len(c.conversations), texts, seconds(embedding), embed.Backend(), seconds(embedding)*1000/float64(max(texts, 1)))
		for _, hybrid := range []bool{false, true} {
			m := metrics{Mode: "keyword"}
			if hybrid {
				m.Mode = "hybrid"
			}
			var latencies []float64
			for _, q := range c.queries {
				started := time.Now()
				search := storememory.Query{Project: project, Text: q.Text, Limit: storememory.MaxLimit}
				if hybrid {
					search.Vector = encoder.Embed(q.Text)
				}
				hits, err := index.Search(search)
				check(err)
				latencies = append(latencies, float64(time.Since(started).Microseconds())/1000)
				rank := 0
				for i, hit := range hits {
					for _, want := range q.Expected {
						if hit.CardID == want && rank == 0 {
							rank = i + 1
						}
					}
				}
				m.Ranks = append(m.Ranks, rank)
			}
			m.Hit1, m.Hit3, m.Hit5, m.MRR = rates(m.Ranks, 0, len(m.Ranks))
			sort.Float64s(latencies)
			m.P50Ms = latencies[len(latencies)/2]
			line := fmt.Sprintf("%-8s hit@1 %.2f  hit@3 %.2f  hit@5 %.2f  MRR %.3f  query p50 %.1f ms", m.Mode, m.Hit1, m.Hit3, m.Hit5, m.MRR, m.P50Ms)
			if c.name == "history" && len(m.Ranks) > historySetA {
				a1, _, _, am := rates(m.Ranks, 0, historySetA)
				b1, _, _, bm := rates(m.Ranks, historySetA, len(m.Ranks))
				line += fmt.Sprintf("  | A %.2f/%.3f  B %.2f/%.3f", a1, am, b1, bm)
			}
			fmt.Printf("%s\n         ranks %v\n", line, m.Ranks)
			section[m.Mode] = m
		}
		report[c.name] = section
		_ = index.Close()
		_ = os.RemoveAll(dir)
	}
	if *out != "" {
		raw, _ := json.MarshalIndent(report, "", "  ")
		check(os.WriteFile(*out, raw, 0o644))
	}
}

// rates are hit@1, hit@3, hit@5 and MRR of ranks[from:to].
func rates(ranks []int, from, to int) (float64, float64, float64, float64) {
	var hit1, hit3, hit5, mrr float64
	for _, r := range ranks[from:to] {
		if r == 1 {
			hit1++
		}
		if r > 0 && r <= 3 {
			hit3++
		}
		if r > 0 && r <= 5 {
			hit5++
		}
		if r > 0 {
			mrr += 1 / float64(r)
		}
	}
	n := float64(to - from)
	return round(hit1 / n), round(hit3 / n), round(hit5 / n), round(mrr / n)
}

func round(v float64) float64 { return float64(int(v*1000+0.5)) / 1000 }

func seconds(d time.Duration) float64 { return round(d.Seconds()) }

func check(err error) {
	if err != nil {
		panic(err)
	}
}
