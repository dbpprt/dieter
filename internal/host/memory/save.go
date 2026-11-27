package memory

import (
	"strings"
	"time"

	agentmemory "github.com/dbpprt/dieter/internal/memory"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// Save rules: a memory this close to an existing one supersedes it; one this
// close is returned as a hint.
const (
	supersedeSimilarity = 0.9
	similarSimilarity   = 0.5
	expiryLayout        = "2006-01-02T15:04:05Z"
)

// SaveInput saves one curated memory.
type SaveInput struct {
	Project, Content, Kind, ReplacesID string
	Files, Sources                     []string
	TTLDays                            int
	// Origin: the conversation and harness that saved it (empty for people).
	Card, Harness string
}

// SaveResult reports what Save did.
type SaveResult struct {
	Memory       Memory
	SimilarTo    *Memory
	SupersededID string
	Reinforced   bool
}

// Save saves a curated memory of a project as a replicated record. Saving an
// identical lesson again reinforces it; a near-identical memory (or the one
// named by ReplacesID) is superseded by the new one; a close one is returned
// as a hint.
func (s *Service) Save(input SaveInput) (SaveResult, error) {
	var result SaveResult
	project, err := s.store.Kanban.ResolveProject(input.Project)
	if err != nil {
		return result, err
	}
	if !project.MemoryEnabled {
		return result, fault.New(fault.FailedPrecondition, "this project does not have memory on; turn it on with dieter project update --memory=true")
	}
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return result, err
	}
	content := strings.TrimSpace(agentmemory.Scrub(input.Content))
	if len(content) < 10 || len(content) > schema.MemoryContentBytes {
		return result, fault.New(fault.Invalid, "a memory must be 10 bytes to 4 KiB of text")
	}
	kind := strings.ToLower(strings.TrimSpace(input.Kind))
	if kind == "" {
		kind = schema.MemoryKindFact
	}
	if input.TTLDays < 0 || input.TTLDays > schema.MemoryMaxTTLDays {
		return result, fault.Invalidf("the time to live must be 0-%d days", schema.MemoryMaxTTLDays)
	}
	sources := cleanIDs(input.Sources)
	if len(sources) == 0 && input.Card != "" {
		sources = []string{input.Card}
	}
	active, err := s.activeMemories(project.ID)
	if err != nil {
		return result, err
	}
	now := home.Timestamp()
	record := schema.MemoryRecord{
		Project: project.ID, Kind: kind, Content: content, Files: cleanFiles(input.Files), Sources: sources,
		Status: schema.MemoryActive, CreatedBy: schema.MemoryOrigin{Daemon: identity.DaemonID, Card: input.Card, Harness: input.Harness},
		CreatedAt: now, UpdatedAt: now,
	}
	if input.TTLDays > 0 {
		record.ExpiresAt = s.now().UTC().Add(time.Duration(input.TTLDays) * 24 * time.Hour).Format(expiryLayout)
	}
	if err = schema.ValidateMemory(record); err != nil {
		return result, err
	}
	normalized := agentmemory.Normalize(content)
	var replace *Memory
	var similar *Memory
	bestSimilarity := 0.0
	for index := range active {
		memory := &active[index]
		if input.ReplacesID != "" && memory.ID == input.ReplacesID {
			replace = memory
		}
		if kind == schema.MemoryKindLesson && memory.Record.Kind == schema.MemoryKindLesson && agentmemory.Normalize(memory.Record.Content) == normalized {
			return s.reinforce(*memory, identity.DaemonID)
		}
		if similarity := agentmemory.Similarity(content, memory.Record.Content); similarity > bestSimilarity {
			bestSimilarity, similar = similarity, memory
		}
	}
	if input.ReplacesID != "" && replace == nil {
		return result, fault.Errorf(fault.NotFound, "no active saved memory %s in this project", input.ReplacesID)
	}
	if replace == nil && bestSimilarity >= supersedeSimilarity {
		replace = similar
	}
	if replace == nil && len(active) >= schema.MemoryMaxPerProject {
		return result, fault.Errorf(fault.ResourceExhausted, "this project already has %d saved memories; a dream or dieter memory forget makes room", schema.MemoryMaxPerProject)
	}
	memoryID := home.NewID("mem_")
	if err = s.store.KV.PutMemory(memoryID, record); err != nil {
		return result, err
	}
	if replace != nil {
		previous := replace.Record
		previous.Status, previous.SupersededBy, previous.UpdatedAt = schema.MemorySuperseded, memoryID, now
		if err = s.store.KV.PutMemory(replace.ID, previous); err != nil {
			return result, err
		}
		result.SupersededID = replace.ID
	} else if similar != nil && bestSimilarity >= similarSimilarity {
		hint := *similar
		result.SimilarTo = &hint
	}
	saved, _, err := s.store.KV.Memory(project.ID, memoryID)
	if err != nil {
		return result, err
	}
	result.Memory = decorate(saved)
	return result, nil
}

func (s *Service) reinforce(memory Memory, daemonID string) (SaveResult, error) {
	record := memory.Record
	counts := map[string]int{}
	for daemon, count := range record.Reinforcements {
		counts[daemon] = count
	}
	counts[daemonID]++
	record.Reinforcements, record.UpdatedAt = counts, home.Timestamp()
	if err := s.store.KV.PutMemory(memory.ID, record); err != nil {
		return SaveResult{}, err
	}
	saved, _, err := s.store.KV.Memory(record.Project, memory.ID)
	if err != nil {
		return SaveResult{}, err
	}
	return SaveResult{Memory: decorate(saved), Reinforced: true}, nil
}

// Forget deletes a saved memory everywhere, or this daemon's index rows of a
// conversation or of a whole project.
func (s *Service) Forget(projectID, memoryID, cardID string, all bool) error {
	chosen := 0
	for _, set := range []bool{memoryID != "", cardID != "", all} {
		if set {
			chosen++
		}
	}
	if chosen != 1 {
		return fault.New(fault.Invalid, "choose exactly one: a saved memory, a conversation, or all of the project's index rows")
	}
	switch {
	case memoryID != "":
		project, err := s.store.Kanban.ResolveProject(projectID)
		if err != nil {
			return err
		}
		if _, found, err := s.store.KV.Memory(project.ID, memoryID); err != nil {
			return err
		} else if !found {
			return fault.Errorf(fault.NotFound, "no saved memory %s in this project", memoryID)
		}
		return s.store.KV.DeleteMemory(project.ID, memoryID)
	case cardID != "":
		card, err := s.store.Kanban.ResolveCard(cardID)
		if err != nil {
			return err
		}
		return s.index.ForgetCard(card.ID)
	default:
		project, err := s.store.Kanban.ResolveProject(projectID)
		if err != nil {
			return err
		}
		return s.index.ForgetProject(project.ID)
	}
}

// Reindex rebuilds this daemon's index rows of a project from its
// conversations.
func (s *Service) Reindex(projectID string) error {
	project, err := s.store.Kanban.ResolveProject(projectID)
	if err != nil {
		return err
	}
	if !project.MemoryEnabled {
		return fault.New(fault.FailedPrecondition, "this project does not have memory on")
	}
	if err = s.index.ForgetProject(project.ID); err != nil {
		return err
	}
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return err
	}
	cards, err := s.listProjectCards(project.ID)
	if err != nil {
		return err
	}
	for _, card := range cards {
		if card.OwnerDaemonID == identity.DaemonID {
			if err = s.indexCard(card.ID); err != nil {
				s.log.Warn("agent memory could not reindex a conversation", "card", card.ID, "error", err)
			}
		}
	}
	return nil
}

// expireMemories deletes the saved memories this daemon wrote whose time has
// come. Each daemon expires only its own, so expiry has one writer.
func (s *Service) expireMemories() {
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return
	}
	projects, err := s.store.Kanban.ListProjects()
	if err != nil {
		return
	}
	now := s.now().UTC().Format(expiryLayout)
	for _, project := range projects {
		var expired []string
		_ = s.store.KV.EachMemory(project.ID, func(saved kv.SavedMemory) error {
			if saved.Record.ExpiresAt != "" && saved.Record.ExpiresAt <= now && saved.Record.CreatedBy.Daemon == identity.DaemonID {
				expired = append(expired, saved.ID)
			}
			return nil
		})
		for _, id := range expired {
			_ = s.store.KV.DeleteMemory(project.ID, id)
		}
	}
}

func cleanIDs(values []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] || !schema.ValidMemoryID(value) || len(out) == schema.MemoryMaxSources {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}

func cleanFiles(values []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] || len(value) > 512 || strings.ContainsAny(value, "\n\r\x00") || len(out) == schema.MemoryMaxFiles {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}
