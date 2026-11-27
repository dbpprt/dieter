package memory

import (
	"context"
	"encoding/json"
	"math"
	"sort"
	"strings"
	"sync"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	agentmemory "github.com/dbpprt/dieter/internal/memory"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/kv"
	storememory "github.com/dbpprt/dieter/internal/store/memory"
)

// Recall bounds.
const (
	maxQueryBytes   = 500
	maxFilesFilter  = 20
	maxPeers        = 8
	peerTimeout     = 2500 * time.Millisecond
	federateTimeout = 3 * time.Second
	maxMemories     = 8
	resultBudget    = 8 << 10
	memoryBytes     = 600
)

// SearchInput is a recall query.
type SearchInput struct {
	Project string
	Query   string
	Limit   int
	Files   []string
	Kinds   []string
	// LocalOnly answers from this daemon's index alone (peer daemons ask
	// with it, so a search never fans out twice).
	LocalOnly bool
}

// Hit is a conversation that matches, with the machine that owns it.
type Hit struct {
	storememory.Hit
	MachineID string
	Machine   string
}

// Memory is a saved memory with its computed confidence.
type Memory struct {
	kv.SavedMemory
	Confidence     float64
	Reinforcements int
}

// SearchResult is a recall answer.
type SearchResult struct {
	Memories    []Memory
	Hits        []Hit
	Unreachable []string
	Truncated   bool
	Excluded    int
}

// Search recalls a project's saved memories and conversations, from this
// daemon's index and, unless LocalOnly, the indexes of the other daemons that
// own conversations of the project.
func (s *Service) Search(ctx context.Context, input SearchInput) (SearchResult, error) {
	var result SearchResult
	input.Query = strings.TrimSpace(input.Query)
	if input.Project == "" {
		return result, fault.New(fault.Invalid, "a project is required")
	}
	if len(input.Query) < 2 || len(input.Query) > maxQueryBytes {
		return result, fault.New(fault.Invalid, "the query must be 2-500 bytes")
	}
	if len(input.Files) > maxFilesFilter {
		return result, fault.Invalidf("at most %d files", maxFilesFilter)
	}
	project, err := s.store.Kanban.ResolveProject(input.Project)
	if err != nil {
		return result, err
	}
	if !project.MemoryEnabled {
		return result, fault.New(fault.FailedPrecondition, "this project does not have memory on; turn it on with dieter project update --memory=true")
	}
	input.Project = project.ID
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return result, err
	}
	local, err := s.index.Search(storememory.Query{Project: project.ID, Text: input.Query, Limit: input.Limit, Files: input.Files})
	if err != nil {
		return result, err
	}
	lists := [][]Hit{s.decorateLocal(local, identity.DaemonID)}
	if !input.LocalOnly {
		peers, unreachable := s.federate(ctx, input, identity.DaemonID)
		lists = append(lists, peers...)
		result.Unreachable = unreachable
	}
	// Saved memories are replicated: every daemon answers them from its own
	// copy, local-only searches included (peers asking ignore them).
	if result.Memories, err = s.searchMemories(project.ID, input.Query, input.Kinds); err != nil {
		return result, err
	}
	result.Hits = mergeHits(lists, limitOf(input.Limit))
	var recalled []string
	for _, hit := range result.Hits {
		if hit.MachineID == identity.DaemonID {
			recalled = append(recalled, hit.CardID)
		}
	}
	s.index.RecordRecall(recalled)
	result.Truncated, result.Excluded = budget(&result)
	return result, nil
}

func limitOf(limit int) int {
	if limit <= 0 {
		return storememory.DefaultLimit
	}
	return min(limit, storememory.MaxLimit)
}

// decorateLocal adds this machine and the conversations' live lane and title.
func (s *Service) decorateLocal(hits []storememory.Hit, daemonID string) []Hit {
	out := make([]Hit, 0, len(hits))
	for _, hit := range hits {
		if card, err := s.store.Kanban.ResolveCard(hit.CardID); err == nil {
			hit.Title, hit.Lane = card.Title, card.Lane
			if card.Archived {
				hit.Lane = "archived"
			}
		}
		out = append(out, Hit{Hit: hit, MachineID: daemonID, Machine: s.name})
	}
	return out
}

// federate asks the other daemons that own conversations of the project,
// in parallel and within a fixed time budget. Peers that fail or time out
// are reported, never fatal.
func (s *Service) federate(ctx context.Context, input SearchInput, self string) ([][]Hit, []string) {
	peers := s.projectDaemons(input.Project, self)
	if len(peers) == 0 {
		return nil, nil
	}
	if s.dial == nil {
		return nil, peers
	}
	ctx, cancel := context.WithTimeout(ctx, federateTimeout)
	defer cancel()
	type answer struct {
		daemon string
		hits   []Hit
		err    error
	}
	answers := make(chan answer, len(peers))
	var wait sync.WaitGroup
	for _, daemon := range peers {
		wait.Add(1)
		go func(daemon string) {
			defer wait.Done()
			hits, err := s.askPeer(ctx, daemon, input)
			answers <- answer{daemon: daemon, hits: hits, err: err}
		}(daemon)
	}
	wait.Wait()
	close(answers)
	var lists [][]Hit
	var unreachable []string
	for value := range answers {
		if value.err != nil {
			unreachable = append(unreachable, value.daemon)
			continue
		}
		lists = append(lists, value.hits)
	}
	sort.Strings(unreachable)
	return lists, unreachable
}

func (s *Service) askPeer(ctx context.Context, daemon string, input SearchInput) ([]Hit, error) {
	ctx, cancel := context.WithTimeout(ctx, peerTimeout)
	defer cancel()
	client, closePeer, err := s.dial(ctx, daemon)
	if err != nil {
		return nil, err
	}
	defer closePeer()
	answer, err := client.SearchMemory(ctx, &dieterv1.SearchMemoryRequest{
		ProjectId: input.Project, Query: input.Query, Limit: int32(limitOf(input.Limit)), Files: input.Files, LocalOnly: true,
	})
	if err != nil {
		return nil, err
	}
	var hits []Hit
	for index, value := range answer.GetHits() {
		if index == storememory.MaxLimit {
			break
		}
		machineID := value.GetMachineId()
		if machineID == "" {
			machineID = daemon
		}
		hits = append(hits, Hit{Hit: storememory.Hit{
			CardID: value.GetCardId(), Title: value.GetTitle(), Lane: value.GetLane(), Harness: value.GetHarness(),
			Scope: value.GetScope(), LastActivityAt: value.GetLastActivityAt(), FinalAnswer: agentmemory.Clip(value.GetFinalAnswer(), 600),
			MessageID: value.GetMessageId(), Snippets: clipAll(value.GetSnippets(), 2, 500), Rank: index + 1,
		}, MachineID: machineID, Machine: value.GetMachine()})
	}
	return hits, nil
}

func clipAll(values []string, count, limit int) []string {
	var out []string
	for _, value := range values {
		if len(out) == count {
			break
		}
		out = append(out, agentmemory.Clip(value, limit))
	}
	return out
}

// projectDaemons are the other daemons that own conversations of a project,
// most conversations first, at most maxPeers.
func (s *Service) projectDaemons(projectID, self string) []string {
	cards, err := s.store.Kanban.ListCards(kanban.CardFilter{Project: projectID, IncludeArchived: true})
	if err != nil {
		return nil
	}
	counts := map[string]int{}
	for _, card := range cards {
		if card.OwnerDaemonID != "" && card.OwnerDaemonID != self {
			counts[card.OwnerDaemonID]++
		}
	}
	daemons := make([]string, 0, len(counts))
	for daemon := range counts {
		daemons = append(daemons, daemon)
	}
	sort.Slice(daemons, func(i, j int) bool {
		if counts[daemons[i]] != counts[daemons[j]] {
			return counts[daemons[i]] > counts[daemons[j]]
		}
		return daemons[i] < daemons[j]
	})
	if len(daemons) > maxPeers {
		daemons = daemons[:maxPeers]
	}
	return daemons
}

// mergeHits fuses ranked lists from several daemons by reciprocal rank: BM25
// scores of different indexes are not comparable, ranks are.
func mergeHits(lists [][]Hit, limit int) []Hit {
	scores := map[string]float64{}
	best := map[string]Hit{}
	for _, list := range lists {
		for index, hit := range list {
			key := hit.MachineID + "/" + hit.CardID
			scores[key] += 1 / float64(60+index+1)
			if _, ok := best[key]; !ok {
				best[key] = hit
			}
		}
	}
	keys := make([]string, 0, len(best))
	for key := range best {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if scores[keys[i]] != scores[keys[j]] {
			return scores[keys[i]] > scores[keys[j]]
		}
		if best[keys[i]].LastActivityAt != best[keys[j]].LastActivityAt {
			return best[keys[i]].LastActivityAt > best[keys[j]].LastActivityAt
		}
		return keys[i] < keys[j]
	})
	var out []Hit
	for _, key := range keys {
		if len(out) == limit {
			break
		}
		hit := best[key]
		hit.Rank = len(out) + 1
		out = append(out, hit)
	}
	return out
}

// searchMemories ranks the project's saved memories (mirrored from the
// replicated records) against the query.
func (s *Service) searchMemories(projectID, query string, kinds []string) ([]Memory, error) {
	all, err := s.activeMemories(projectID)
	if err != nil {
		return nil, err
	}
	byID := map[string]Memory{}
	var saved []kv.SavedMemory
	for _, memory := range all {
		byID[memory.ID] = memory
		saved = append(saved, memory.SavedMemory)
	}
	if err = s.index.SyncMemories(projectID, saved, s.timestamp()); err != nil {
		return nil, err
	}
	ids, err := s.index.SearchMemories(projectID, query, kinds, maxMemories)
	if err != nil {
		return nil, err
	}
	var out []Memory
	for _, id := range ids {
		if memory, ok := byID[id]; ok {
			out = append(out, memory)
		}
	}
	return out, nil
}

// activeMemories lists a project's active, unexpired saved memories.
func (s *Service) activeMemories(projectID string) ([]Memory, error) {
	now := s.timestamp()
	var out []Memory
	err := s.store.KV.EachMemory(projectID, func(saved kv.SavedMemory) error {
		if saved.Record.Status != schema.MemoryActive || (saved.Record.ExpiresAt != "" && saved.Record.ExpiresAt <= now) {
			return nil
		}
		out = append(out, decorate(saved))
		return nil
	})
	return out, err
}

func decorate(saved kv.SavedMemory) Memory {
	total := 0
	for _, count := range saved.Record.Reinforcements {
		total += count
	}
	return Memory{SavedMemory: saved, Reinforcements: total, Confidence: confidence(saved.Record, total)}
}

// confidence is 0-1: a lesson starts at 0.5 and gains 10% of the remaining
// distance each time it is saved again; a verified memory starts higher.
func confidence(record schema.MemoryRecord, reinforcements int) float64 {
	base := 0.6
	if record.Kind == schema.MemoryKindLesson {
		base = 0.5
	}
	if record.Verified {
		base = 0.8
	}
	value := 1 - (1-base)*math.Pow(0.9, float64(reinforcements))
	return math.Round(value*100) / 100
}

// budget trims a result to the response budget, conversations first from the
// end, and reports what was left out.
func budget(result *SearchResult) (bool, int) {
	size := func() int {
		total := 0
		for _, memory := range result.Memories {
			total += len(memory.Record.Content) + 120
		}
		for _, hit := range result.Hits {
			total += len(hit.Title) + len(hit.FinalAnswer) + 160
			for _, snippet := range hit.Snippets {
				total += len(snippet)
			}
		}
		return total
	}
	excluded := 0
	for size() > resultBudget && len(result.Hits) > 1 {
		result.Hits = result.Hits[:len(result.Hits)-1]
		excluded++
	}
	for size() > resultBudget && len(result.Memories) > 1 {
		result.Memories = result.Memories[:len(result.Memories)-1]
		excluded++
	}
	return excluded > 0, excluded
}

// recallToolResult is what memory_recall returns to the agent.
func recallToolResult(result SearchResult, cli string) json.RawMessage {
	type memoryView struct {
		ID         string   `json:"id"`
		Kind       string   `json:"kind"`
		Content    string   `json:"content"`
		Files      []string `json:"files,omitempty"`
		Sources    []string `json:"sources,omitempty"`
		Verified   bool     `json:"verified,omitempty"`
		Confidence float64  `json:"confidence"`
		UpdatedAt  string   `json:"updatedAt"`
	}
	type hitView struct {
		Card         string   `json:"card"`
		Machine      string   `json:"machine"`
		Title        string   `json:"title"`
		Lane         string   `json:"lane,omitempty"`
		Harness      string   `json:"harness,omitempty"`
		LastActivity string   `json:"lastActivity,omitempty"`
		Passages     []string `json:"passages,omitempty"`
		FinalAnswer  string   `json:"finalAnswer,omitempty"`
	}
	view := struct {
		Note          string       `json:"note"`
		Memories      []memoryView `json:"memories"`
		Conversations []hitView    `json:"conversations"`
		Unreachable   []string     `json:"unreachableMachines,omitempty"`
		Truncated     bool         `json:"truncated,omitempty"`
	}{
		Note:          "Earlier work from this project's memory: may be out of date. Verify against the code; read a conversation with `" + cli + " --machine MACHINE card transcript --last 40 CARD`.",
		Memories:      []memoryView{},
		Conversations: []hitView{},
		Unreachable:   result.Unreachable,
		Truncated:     result.Truncated,
	}
	for _, memory := range result.Memories {
		view.Memories = append(view.Memories, memoryView{
			ID: memory.ID, Kind: memory.Record.Kind, Content: agentmemory.Clip(memory.Record.Content, 1200), Files: memory.Record.Files,
			Sources: memory.Record.Sources, Verified: memory.Record.Verified, Confidence: memory.Confidence, UpdatedAt: memory.Record.UpdatedAt,
		})
	}
	for _, hit := range result.Hits {
		machine := hit.Machine
		if machine == "" {
			machine = hit.MachineID
		}
		view.Conversations = append(view.Conversations, hitView{
			Card: hit.CardID, Machine: machine, Title: hit.Title, Lane: hit.Lane, Harness: hit.Harness,
			LastActivity: hit.LastActivityAt, Passages: hit.Snippets, FinalAnswer: hit.FinalAnswer,
		})
	}
	raw, _ := json.Marshal(view)
	return raw
}

func (s *Service) timestamp() string { return s.now().UTC().Format(expiryLayout) }
