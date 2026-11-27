package memory

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/harness"
	agentmemory "github.com/dbpprt/dieter/internal/memory"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// Dream statuses.
const (
	DreamRunning   = "running"
	DreamStaged    = "staged"
	DreamApplied   = "applied"
	DreamDiscarded = "discarded"
	DreamUndone    = "undone"
	DreamEmpty     = "empty"
	DreamFailed    = "failed"
)

// MemoryLabel is the board label of dream conversations.
const MemoryLabel = "Memory"

const (
	memoryLabelColor    = "#8b5cf6"
	maxDreamsKept       = 100
	briefMemories       = 200
	briefCards          = 50
	briefTextBytes      = 300
	dreamPromptBudget   = 48 << 10
	dreamMetaLastPrefix = "dream.last."
)

// DreamProcedure is the Memory label's default instructions: the dream
// procedure. People edit the label to steer dreaming.
const DreamProcedure = `This is a memory dream: reconcile this project's saved memories with what its recent conversations found. Do not change code or files; your only output is one memory_apply batch and a short report.

1. Orient: read the brief below (the saved memories and the conversations since the last dream). Use memory_recall to look for related memories and conversations.
2. Gather: for the conversations that matter, read what was decided, corrected, fixed or abandoned with: dieter --machine MACHINE card transcript --last N CARD (MACHINE as listed below; --last N keeps it short).
3. Consolidate: keep one memory per topic or entity. Merge duplicates. Supersede outdated memories with corrected text. Add memories for durable decisions, lessons and facts the conversations established, each citing the card IDs it comes from. Write absolute dates, not "yesterday". Leave out what the code or git history already says, transient state and step-by-step narration. Do not invent blanket rules.
4. Verify: check a few existing memories against their source conversations. Mark the ones that hold with verify; retire the ones newer conversations contradict, with the reason.
5. Apply and report: call memory_apply once with all changes (it rejects a batch that breaks the limits; fix it and call again once). Then answer with a short list of what you added, merged, superseded, retired and verified, with card links. Move this card to review when you are done.`

// DreamOperation is one change a dream asks for.
type DreamOperation struct {
	Op       string   `json:"op"`
	MemoryID string   `json:"memoryId,omitempty"`
	Targets  []string `json:"targets,omitempty"`
	Kind     string   `json:"kind,omitempty"`
	Content  string   `json:"content,omitempty"`
	Files    []string `json:"files,omitempty"`
	Sources  []string `json:"sources,omitempty"`
	Reason   string   `json:"reason"`
}

// DreamChange is one saved memory a dream wrote, with its prior version (nil
// for a memory the dream created).
type DreamChange struct {
	MemoryID string               `json:"memoryId"`
	Before   *schema.MemoryRecord `json:"before,omitempty"`
	After    schema.MemoryRecord  `json:"after"`
}

// Dream is one reconciliation of a project's saved memories, kept on the
// machine that ran it (DIETER_HOME/memory/dreams).
type Dream struct {
	CardID     string           `json:"cardId"`
	ProjectID  string           `json:"projectId"`
	Status     string           `json:"status"`
	MachineID  string           `json:"machineId"`
	Apply      string           `json:"apply"`
	StartedAt  string           `json:"startedAt"`
	FinishedAt string           `json:"finishedAt,omitempty"`
	Operations []DreamOperation `json:"operations,omitempty"`
	Changes    []DreamChange    `json:"changes,omitempty"`
	Summary    string           `json:"summary,omitempty"`
	Error      string           `json:"error,omitempty"`
	Added      int              `json:"added"`
	Merged     int              `json:"merged"`
	Superseded int              `json:"superseded"`
	Retired    int              `json:"retired"`
	Verified   int              `json:"verified"`
}

func (s *Service) dreamsDir() string { return filepath.Join(s.store.Root, "memory", "dreams") }

func (s *Service) dreamPath(cardID string) string {
	return filepath.Join(s.dreamsDir(), cardID+".json")
}

func (s *Service) readDream(cardID string) (Dream, bool, error) {
	var dream Dream
	if !schema.ValidMemoryID(cardID) {
		return dream, false, nil
	}
	err := home.ReadJSON(s.dreamPath(cardID), &dream)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, home.ErrNotFound) {
		return dream, false, nil
	}
	return dream, err == nil, err
}

func (s *Service) writeDream(dream Dream) error {
	release, err := s.store.BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	if err = os.MkdirAll(s.dreamsDir(), 0o700); err != nil {
		return err
	}
	return home.WriteJSON(s.dreamPath(dream.CardID), dream)
}

// Dreams lists a project's dreams on this machine, newest first.
func (s *Service) Dreams(projectID string) ([]Dream, error) {
	project, err := s.store.Kanban.ResolveProject(projectID)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(s.dreamsDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Dream
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		dream, ok, err := s.readDream(strings.TrimSuffix(entry.Name(), ".json"))
		if err != nil || !ok || dream.ProjectID != project.ID {
			continue
		}
		out = append(out, dream)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].StartedAt > out[j].StartedAt })
	return out, nil
}

// Dream returns one dream by its conversation.
func (s *Service) Dream(cardID string) (Dream, error) {
	card, err := s.store.Kanban.ResolveCard(cardID)
	if err != nil {
		return Dream{}, err
	}
	dream, ok, err := s.readDream(card.ID)
	if err != nil {
		return Dream{}, err
	}
	if !ok {
		if s.store.Kanban.RequireLocalCard(card) != nil {
			return Dream{}, fault.Errorf(fault.FailedPrecondition, "dream %s ran on another machine; target its owner with --machine", card.ID)
		}
		return Dream{}, fault.Errorf(fault.NotFound, "%s is not a memory dream", card.ID)
	}
	return dream, nil
}

// dreamMachine is the daemon that runs a project's dreams: the setting's
// machine, or the one that owns most of the project's conversations. Every
// daemon computes the same answer from replicated records, so only one
// dreams.
func (s *Service) dreamMachine(settings schema.MemorySettingsRecord, projectID string) string {
	if settings.RunOn != "" {
		return settings.RunOn
	}
	cards, err := s.listProjectCards(projectID)
	if err != nil {
		return ""
	}
	counts := map[string]int{}
	for _, card := range cards {
		if card.MemoryRole != engine.MemoryRoleDreamer && card.OwnerDaemonID != "" {
			counts[card.OwnerDaemonID]++
		}
	}
	best := ""
	for daemon, count := range counts {
		if best == "" || count > counts[best] || (count == counts[best] && daemon < best) {
			best = daemon
		}
	}
	return best
}

func (s *Service) listProjectCards(projectID string) ([]model.Card, error) {
	return s.store.Kanban.ListCards(kanban.CardFilter{Project: projectID, IncludeArchived: true})
}

// DreamGate is a project's dreaming eligibility.
type DreamGate struct {
	Eligible      bool
	Reason        string
	LastDreamAt   string
	LastDreamCard string
	FinishedSince int
	Machine       string
}

// dreamGate checks whether a project may dream now on this daemon.
func (s *Service) dreamGate(settings schema.MemorySettingsRecord, project model.Project, self string) DreamGate {
	gate := DreamGate{}
	last, _ := s.index.Meta(dreamMetaLastPrefix + project.ID)
	if at, card, ok := strings.Cut(last, " "); ok {
		gate.LastDreamAt, gate.LastDreamCard = at, card
	}
	cards, _ := s.listProjectCards(project.ID)
	for _, card := range cards {
		if card.MemoryRole == engine.MemoryRoleDreamer || card.Runtime == "running" || card.InitialPromptSentAt == "" {
			continue
		}
		if later(card.LastActivityAt, gate.LastDreamAt) {
			gate.FinishedSince++
		}
	}
	gate.Machine = s.dreamMachine(settings, project.ID)
	now := s.now().UTC()
	switch {
	case !project.MemoryEnabled:
		gate.Reason = "project memory is off"
	case !settings.Dreaming:
		gate.Reason = "dreaming is off"
	case gate.Machine != self:
		gate.Reason = "dreams run on " + gate.Machine
	case s.dreamBusy(project.ID) != "":
		gate.Reason = "dream " + s.dreamBusy(project.ID) + " is running or awaiting review"
	case gate.FinishedSince < settings.MinNewTasks:
		gate.Reason = fmt.Sprintf("waiting for %d more finished conversations", settings.MinNewTasks-gate.FinishedSince)
	default:
		if gate.LastDreamAt != "" {
			if at, err := time.Parse(time.RFC3339Nano, gate.LastDreamAt); err == nil {
				if next := at.Add(time.Duration(settings.MinHours) * time.Hour); now.Before(next) {
					gate.Reason = "next dream after " + next.Format(time.RFC3339)
					return gate
				}
			}
		}
		if !inWindow(settings.Window, s.now()) {
			gate.Reason = "waiting for the dreaming window " + settings.Window
			return gate
		}
		gate.Eligible, gate.Reason = true, "eligible now"
	}
	return gate
}

// inWindow reports whether local time t is inside "HH:MM-HH:MM" (which may
// wrap midnight); an empty window is always open.
func inWindow(window string, t time.Time) bool {
	if window == "" {
		return true
	}
	start, end, ok := strings.Cut(window, "-")
	if !ok {
		return true
	}
	parse := func(value string) int {
		parsed, err := time.Parse("15:04", value)
		if err != nil {
			return 0
		}
		return parsed.Hour()*60 + parsed.Minute()
	}
	from, to, now := parse(start), parse(end), t.Hour()*60+t.Minute()
	if from <= to {
		return now >= from && now < to
	}
	return now >= from || now < to
}

// dreamBusy returns a project's dream that is running or awaiting review on
// this machine.
func (s *Service) dreamBusy(projectID string) string {
	dreams, _ := s.Dreams(projectID)
	for _, dream := range dreams {
		if dream.Status == DreamRunning || dream.Status == DreamStaged {
			if card, err := s.store.Kanban.ResolveCard(dream.CardID); err == nil && !card.Archived {
				return dream.CardID
			}
		}
	}
	return ""
}

// checkDreams starts the dreams whose gates pass on this daemon.
func (s *Service) checkDreams(ctx context.Context) {
	entry, err := s.store.KV.MemorySettings()
	if err != nil || !entry.Record.Dreaming {
		return
	}
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return
	}
	projects, err := s.store.Kanban.ListProjects()
	if err != nil {
		return
	}
	for _, project := range projects {
		if project.Archived || !project.MemoryEnabled {
			continue
		}
		if gate := s.dreamGate(entry.Record, project, identity.DaemonID); gate.Eligible {
			if _, err := s.StartDream(ctx, project.ID); err != nil {
				s.log.Warn("agent memory could not start a dream", "project", project.ID, "error", err)
			}
		}
	}
}

// StartDream starts a dream of a project now: a running conversation on the
// project's first board with the Memory label and the dreamer role, on the
// harness, model and account of the memory setting.
func (s *Service) StartDream(ctx context.Context, projectID string) (Dream, error) {
	s.dreamMu.Lock()
	defer s.dreamMu.Unlock()
	if s.app == nil {
		return Dream{}, fault.New(fault.Unavailable, "dreams need the daemon's engine")
	}
	project, err := s.store.Kanban.ResolveProject(projectID)
	if err != nil {
		return Dream{}, err
	}
	if !project.MemoryEnabled {
		return Dream{}, fault.New(fault.FailedPrecondition, "this project does not have memory on")
	}
	if busy := s.dreamBusy(project.ID); busy != "" {
		return Dream{}, fault.Errorf(fault.FailedPrecondition, "dream %s is running or awaiting review; finish or discard it first", busy)
	}
	entry, err := s.store.KV.MemorySettings()
	if err != nil {
		return Dream{}, err
	}
	settings := entry.Record
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return Dream{}, err
	}
	board, hasBoard, err := s.dreamBoard(project.ID)
	if err != nil {
		return Dream{}, err
	}
	enabled := true
	input := engine.CardInput{
		Project: project.ID, Title: "Memory dream · " + s.now().Format("2006-01-02"),
		Provider: settings.Harness, Model: settings.Model, Effort: settings.Effort, AccountID: settings.AccountID,
		WorkspaceMode: model.WorkspaceModeWorktree, Memory: &enabled, MemoryRole: engine.MemoryRoleDreamer,
	}
	// A dream is a card labelled Memory on the project's first board, whose
	// label carries the procedure; a project without boards gets a chat
	// whose first message carries it.
	create := s.app.CreateChat
	if hasBoard {
		labelID, err := s.ensureMemoryLabel(board)
		if err != nil {
			return Dream{}, err
		}
		input.Board, input.Lane, input.LabelIDs = board.ID, model.LaneRunning, []string{labelID}
		create = s.app.CreateCard
	}
	if input.Prompt, err = s.dreamBrief(project, settings, !hasBoard); err != nil {
		return Dream{}, err
	}
	started := home.Timestamp()
	card, err := create(ctx, input)
	if card.ID == "" {
		if err == nil {
			err = errors.New("the dream conversation was not created")
		}
		return Dream{}, err
	}
	dream := Dream{CardID: card.ID, ProjectID: project.ID, Status: DreamRunning, MachineID: identity.DaemonID, Apply: settings.Apply, StartedAt: started}
	if err != nil {
		dream.Status, dream.Error, dream.FinishedAt = DreamFailed, err.Error(), home.Timestamp()
	}
	if writeErr := s.writeDream(dream); writeErr != nil {
		return dream, writeErr
	}
	_ = s.index.SetMeta(dreamMetaLastPrefix+project.ID, started+" "+card.ID)
	s.pruneDreams(project.ID)
	return dream, err
}

// dreamBoard is the project's first board, if it has one.
func (s *Service) dreamBoard(projectID string) (model.Board, bool, error) {
	if board, err := s.store.Kanban.InitialBoard(projectID); err == nil {
		return board, true, nil
	}
	boards, err := s.store.Kanban.ListBoards(projectID)
	if err != nil || len(boards) == 0 {
		return model.Board{}, false, err
	}
	return boards[0], true, nil
}

// ensureMemoryLabel returns the board's Memory label, creating it with the
// dream procedure as its instructions.
func (s *Service) ensureMemoryLabel(board model.Board) (string, error) {
	for _, label := range board.Labels {
		if strings.EqualFold(label.Name, MemoryLabel) {
			return label.ID, nil
		}
	}
	updated, err := s.store.Kanban.CreateBoardLabel(board.ID, MemoryLabel, memoryLabelColor, DreamProcedure)
	if err != nil {
		return "", err
	}
	for _, label := range updated.Labels {
		if strings.EqualFold(label.Name, MemoryLabel) {
			return label.ID, nil
		}
	}
	return "", fault.New(fault.Internal, "the Memory label was not created")
}

// dreamBrief is the dream conversation's first message: limits, the saved
// memories and the conversations since the last dream.
func (s *Service) dreamBrief(project model.Project, settings schema.MemorySettingsRecord, withProcedure bool) (string, error) {
	active, err := s.activeMemories(project.ID)
	if err != nil {
		return "", err
	}
	sort.Slice(active, func(i, j int) bool { return active[i].Record.UpdatedAt > active[j].Record.UpdatedAt })
	last, _ := s.index.Meta(dreamMetaLastPrefix + project.ID)
	lastAt, _, _ := strings.Cut(last, " ")
	cards, err := s.listProjectCards(project.ID)
	if err != nil {
		return "", err
	}
	recalls, _ := s.index.Recalls(project.ID)
	var recent []model.Card
	for _, card := range cards {
		if card.MemoryRole == engine.MemoryRoleDreamer || card.InitialPromptSentAt == "" {
			continue
		}
		if later(card.LastActivityAt, lastAt) {
			recent = append(recent, card)
		}
	}
	sort.Slice(recent, func(i, j int) bool {
		if recalls[recent[i].ID] != recalls[recent[j].ID] {
			return recalls[recent[i].ID] > recalls[recent[j].ID]
		}
		return recent[i].LastActivityAt > recent[j].LastActivityAt
	})
	limit := retireLimit(len(active), settings.MaxRetire)
	var b strings.Builder
	fmt.Fprintf(&b, "Memory dream for project %s (%s), %s.\n\n", project.Name, project.ID, s.now().Format("2006-01-02 15:04 MST"))
	if lastAt == "" {
		b.WriteString("This is the project's first dream.\n")
	} else {
		fmt.Fprintf(&b, "The last dream started %s.\n", lastAt)
	}
	fmt.Fprintf(&b, "Limits: at most %d changes in one memory_apply batch; retire or supersede at most %d of the %d active memories; every add, merge and supersede cites at least one card ID of this project. Apply mode: %s", settings.MaxOperations, limit, len(active), settings.Apply)
	if settings.Apply == "review" {
		b.WriteString(" (your batch is staged until a person applies it)")
	}
	b.WriteString(".\n")
	if extra := strings.TrimSpace(settings.Instructions); extra != "" {
		b.WriteString("\nExtra instructions for every dream:\n" + extra + "\n")
	}
	fmt.Fprintf(&b, "\n## Saved memories (%d active)\n", len(active))
	if len(active) == 0 {
		b.WriteString("None yet.\n")
	}
	for index, memory := range active {
		if index == briefMemories {
			fmt.Fprintf(&b, "… and %d more (use memory_recall).\n", len(active)-briefMemories)
			break
		}
		flags := memory.Record.Kind
		if memory.Record.Verified {
			flags += ", verified"
		}
		if memory.Reinforcements > 0 {
			flags += fmt.Sprintf(", saved %d more times", memory.Reinforcements)
		}
		line := fmt.Sprintf("- %s [%s] %s", memory.ID, flags, oneLine(agentmemory.Clip(memory.Record.Content, briefTextBytes)))
		if len(memory.Record.Sources) > 0 {
			line += " (sources: " + strings.Join(memory.Record.Sources, ", ") + ")"
		}
		b.WriteString(line + "\n")
		if b.Len() > dreamPromptBudget/2 {
			fmt.Fprintf(&b, "… and %d more (use memory_recall).\n", len(active)-index-1)
			break
		}
	}
	fmt.Fprintf(&b, "\n## Conversations since the last dream (%d, most recalled first)\n", len(recent))
	if len(recent) == 0 {
		b.WriteString("None.\n")
	}
	for index, card := range recent {
		if index == briefCards || b.Len() > dreamPromptBudget {
			fmt.Fprintf(&b, "… and %d more.\n", len(recent)-index)
			break
		}
		answer, _ := s.index.FinalAnswer(card.ID)
		line := fmt.Sprintf("- %s on machine %s: %q (%s, %s, last active %s)", card.ID, card.OwnerDaemonID, card.Title, card.Lane, card.Provider, card.LastActivityAt)
		if answer != "" {
			line += ": " + oneLine(agentmemory.Clip(answer, briefTextBytes))
		}
		b.WriteString(line + "\n")
	}
	if withProcedure {
		b.WriteString("\n## Dream procedure\n" + DreamProcedure + "\n")
		b.WriteString("\nFollow the dream procedure above. Finish with one memory_apply batch and a short report.")
	} else {
		b.WriteString("\nFollow the dream procedure in your instructions (the Memory label). Finish with one memory_apply batch and a short report.")
	}
	return b.String(), nil
}

func oneLine(text string) string { return strings.Join(strings.Fields(text), " ") }

func retireLimit(active, percent int) int {
	if active == 0 {
		return 0
	}
	return max(1, active*percent/100)
}

// pruneDreams keeps the newest dream records of a project.
func (s *Service) pruneDreams(projectID string) {
	dreams, err := s.Dreams(projectID)
	if err != nil || len(dreams) <= maxDreamsKept {
		return
	}
	for _, dream := range dreams[maxDreamsKept:] {
		_ = os.Remove(s.dreamPath(dream.CardID))
	}
}

// dreamTurnFinished settles a dream when its conversation's turn ends:
// applied, staged for review, or empty.
func (s *Service) dreamTurnFinished(cardID string) {
	dream, ok, err := s.readDream(cardID)
	if err != nil || !ok || dream.Status != DreamRunning {
		return
	}
	switch {
	case len(dream.Changes) > 0:
		dream.Status = DreamApplied
	case len(dream.Operations) > 0:
		dream.Status = DreamStaged
	default:
		dream.Status = DreamEmpty
	}
	dream.FinishedAt = home.Timestamp()
	if err = s.writeDream(dream); err != nil {
		s.log.Warn("agent memory could not record a dream's end", "card", cardID, "error", err)
	}
}

// applyArguments are memory_apply's input.
type applyArguments struct {
	Operations []DreamOperation `json:"operations"`
	Summary    string           `json:"summary"`
}

// dreamApply answers a dreamer's memory_apply: it validates the whole batch,
// then applies it (auto) or stages it for review.
func (s *Service) dreamApply(card model.Card, harnessID string, raw json.RawMessage) (json.RawMessage, error) {
	s.dreamMu.Lock()
	defer s.dreamMu.Unlock()
	var arguments applyArguments
	if err := json.Unmarshal(raw, &arguments); err != nil {
		return nil, fault.New(fault.Invalid, "invalid memory_apply arguments")
	}
	dream, ok, err := s.readDream(card.ID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, fault.New(fault.FailedPrecondition, "this conversation is not a memory dream")
	}
	if dream.Status != DreamRunning || len(dream.Operations) > 0 || len(dream.Changes) > 0 {
		return nil, fault.New(fault.FailedPrecondition, "this dream already applied or staged its changes")
	}
	entry, err := s.store.KV.MemorySettings()
	if err != nil {
		return nil, err
	}
	plan, err := s.planDream(dream.ProjectID, card.ID, harnessID, arguments.Operations, entry.Record)
	if err != nil {
		return nil, err
	}
	dream.Operations, dream.Summary = plan.operations, agentmemory.Clip(strings.TrimSpace(arguments.Summary), 2000)
	plan.count(&dream)
	status := "staged for review"
	if dream.Apply == "review" {
		if err = s.writeDream(dream); err != nil {
			return nil, err
		}
	} else {
		if err = s.commitPlan(&dream, plan); err != nil {
			return nil, err
		}
		status = "applied"
	}
	result := map[string]any{
		"status": status, "added": dream.Added, "merged": dream.Merged, "superseded": dream.Superseded,
		"retired": dream.Retired, "verified": dream.Verified,
	}
	if dream.Apply != "review" {
		result["undo"] = "a person can undo this dream with: dieter memory dream undo " + card.ID
	}
	return json.Marshal(result)
}

// dreamPlan is a validated batch: the records to write, in order.
type dreamPlan struct {
	operations []DreamOperation
	writes     []DreamChange
}

func (p dreamPlan) count(dream *Dream) {
	dream.Added, dream.Merged, dream.Superseded, dream.Retired, dream.Verified = 0, 0, 0, 0, 0
	for _, operation := range p.operations {
		switch operation.Op {
		case "add":
			dream.Added++
		case "merge":
			dream.Merged++
		case "supersede":
			dream.Superseded++
		case "retire":
			dream.Retired += len(operation.Targets)
		case "verify":
			dream.Verified += len(operation.Targets)
		}
	}
}

// planDream validates a batch against the project's current memories and
// the setting's limits, all or nothing, and computes every record it writes.
func (s *Service) planDream(projectID, dreamCard, harnessID string, operations []DreamOperation, settings schema.MemorySettingsRecord) (dreamPlan, error) {
	var plan dreamPlan
	var problems []string
	if len(operations) == 0 {
		return plan, fault.New(fault.Invalid, "memory_apply needs at least one operation")
	}
	if len(operations) > settings.MaxOperations {
		problems = append(problems, fmt.Sprintf("%d operations is more than the limit of %d", len(operations), settings.MaxOperations))
	}
	active, err := s.activeMemories(projectID)
	if err != nil {
		return plan, err
	}
	byID := map[string]Memory{}
	for _, memory := range active {
		byID[memory.ID] = memory
	}
	cards, err := s.listProjectCards(projectID)
	if err != nil {
		return plan, err
	}
	projectCards := map[string]bool{}
	for _, card := range cards {
		projectCards[card.ID] = true
	}
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return plan, err
	}
	now := home.Timestamp()
	used := map[string]bool{}
	removed := 0
	targetChanges := map[string]schema.MemoryRecord{}
	var targetOrder []string
	for index, operation := range operations {
		label := fmt.Sprintf("operation %d (%s)", index+1, operation.Op)
		operation.Reason = strings.TrimSpace(agentmemory.Scrub(operation.Reason))
		if len(operation.Reason) < 3 {
			problems = append(problems, label+": a reason is required")
		}
		targets := cleanIDs(operation.Targets)
		for _, target := range targets {
			if _, ok := byID[target]; !ok {
				problems = append(problems, fmt.Sprintf("%s: %s is not an active memory of this project", label, target))
			} else if used[target] {
				problems = append(problems, fmt.Sprintf("%s: %s is changed by more than one operation", label, target))
			}
			used[target] = true
		}
		operation.Targets = targets
		creates := operation.Op == "add" || operation.Op == "merge" || operation.Op == "supersede"
		switch operation.Op {
		case "add":
			if len(targets) > 0 {
				problems = append(problems, label+": add takes no targets")
			}
		case "merge":
			if len(targets) < 2 {
				problems = append(problems, label+": merge needs at least two targets")
			}
		case "supersede":
			if len(targets) != 1 {
				problems = append(problems, label+": supersede needs exactly one target")
			}
		case "retire", "verify":
			if len(targets) == 0 {
				problems = append(problems, label+": needs targets")
			}
		default:
			problems = append(problems, label+": unknown operation")
			continue
		}
		if operation.Op == "merge" || operation.Op == "supersede" || operation.Op == "retire" {
			removed += len(targets)
		}
		var newRecord schema.MemoryRecord
		if creates {
			operation.Kind = strings.ToLower(strings.TrimSpace(operation.Kind))
			operation.Content = strings.TrimSpace(agentmemory.Scrub(operation.Content))
			operation.Sources = cleanIDs(operation.Sources)
			operation.Files = cleanFiles(operation.Files)
			cited := 0
			for _, source := range operation.Sources {
				if projectCards[source] {
					cited++
				}
			}
			if cited == 0 {
				problems = append(problems, label+": cite at least one card ID of this project in sources")
			}
			newRecord = schema.MemoryRecord{
				Project: projectID, Kind: operation.Kind, Content: operation.Content, Files: operation.Files, Sources: operation.Sources,
				Status: schema.MemoryActive, CreatedBy: schema.MemoryOrigin{Daemon: identity.DaemonID, Card: dreamCard, Harness: harnessID},
				DreamCard: dreamCard, Reason: agentmemory.Clip(operation.Reason, schema.MemoryReasonBytes), CreatedAt: now, UpdatedAt: now,
			}
			if err := schema.ValidateMemory(newRecord); err != nil {
				problems = append(problems, label+": "+err.Error())
			}
			operation.MemoryID = home.NewID("mem_")
		}
		for _, target := range targets {
			memory, ok := byID[target]
			if !ok {
				continue
			}
			record := memory.Record
			record.UpdatedAt, record.DreamCard = now, dreamCard
			switch operation.Op {
			case "merge", "supersede":
				record.Status, record.SupersededBy = schema.MemorySuperseded, operation.MemoryID
			case "retire":
				record.Status, record.Reason = schema.MemoryRetired, agentmemory.Clip(operation.Reason, schema.MemoryReasonBytes)
			case "verify":
				record.Verified = true
			}
			targetChanges[target] = record
			targetOrder = append(targetOrder, target)
		}
		if creates {
			plan.writes = append(plan.writes, DreamChange{MemoryID: operation.MemoryID, After: newRecord})
		}
		plan.operations = append(plan.operations, operation)
	}
	if limit := retireLimit(len(active), settings.MaxRetire); removed > limit {
		problems = append(problems, fmt.Sprintf("the batch retires or supersedes %d memories; the limit is %d of %d active (%d%%)", removed, limit, len(active), settings.MaxRetire))
	}
	added := 0
	for _, write := range plan.writes {
		if write.Before == nil {
			added++
		}
	}
	if len(active)+added-removed > schema.MemoryMaxPerProject {
		problems = append(problems, fmt.Sprintf("the project would exceed %d saved memories", schema.MemoryMaxPerProject))
	}
	if len(problems) > 0 {
		return dreamPlan{}, fault.Invalidf("memory_apply rejected the whole batch; fix these and call it again: %s", strings.Join(problems, "; "))
	}
	for _, target := range targetOrder {
		before := byID[target].Record
		plan.writes = append(plan.writes, DreamChange{MemoryID: target, Before: &before, After: targetChanges[target]})
	}
	return plan, nil
}

// commitPlan writes a validated plan's records and records the changes with
// their prior versions, so undo can restore them.
func (s *Service) commitPlan(dream *Dream, plan dreamPlan) error {
	for _, change := range plan.writes {
		if err := s.store.KV.PutMemory(change.MemoryID, change.After); err != nil {
			dream.Error = err.Error()
			_ = s.writeDream(*dream)
			return err
		}
		dream.Changes = append(dream.Changes, change)
	}
	if dream.Status == DreamStaged {
		dream.Status = DreamApplied
	}
	return s.writeDream(*dream)
}

// ApplyDream applies a staged dream after a person reviewed it. The batch is
// validated again against the memories as they are now.
func (s *Service) ApplyDream(cardID string) (Dream, error) {
	s.dreamMu.Lock()
	defer s.dreamMu.Unlock()
	dream, err := s.Dream(cardID)
	if err != nil {
		return Dream{}, err
	}
	if dream.Status != DreamStaged && !(dream.Status == DreamRunning && len(dream.Operations) > 0 && len(dream.Changes) == 0) {
		return dream, fault.Errorf(fault.FailedPrecondition, "dream %s has no staged changes (it is %s)", dream.CardID, dream.Status)
	}
	entry, err := s.store.KV.MemorySettings()
	if err != nil {
		return dream, err
	}
	card, _ := s.store.Kanban.ResolveCard(dream.CardID)
	plan, err := s.planDream(dream.ProjectID, dream.CardID, card.Provider, dream.Operations, entry.Record)
	if err != nil {
		return dream, err
	}
	dream.Operations = plan.operations
	dream.Status = DreamStaged
	if dream.FinishedAt == "" {
		dream.FinishedAt = home.Timestamp()
	}
	if err = s.commitPlan(&dream, plan); err != nil {
		return dream, err
	}
	return dream, nil
}

// DiscardDream discards a dream's staged changes.
func (s *Service) DiscardDream(cardID string) (Dream, error) {
	s.dreamMu.Lock()
	defer s.dreamMu.Unlock()
	dream, err := s.Dream(cardID)
	if err != nil {
		return Dream{}, err
	}
	if len(dream.Changes) > 0 || (dream.Status != DreamStaged && dream.Status != DreamRunning && dream.Status != DreamEmpty) {
		return dream, fault.Errorf(fault.FailedPrecondition, "dream %s is %s; only staged changes can be discarded (use undo for applied ones)", dream.CardID, dream.Status)
	}
	dream.Status = DreamDiscarded
	if dream.FinishedAt == "" {
		dream.FinishedAt = home.Timestamp()
	}
	return dream, s.writeDream(dream)
}

// UndoDream restores every saved memory an applied dream changed to its
// prior version and deletes the memories it created.
func (s *Service) UndoDream(cardID string) (Dream, error) {
	s.dreamMu.Lock()
	defer s.dreamMu.Unlock()
	dream, err := s.Dream(cardID)
	if err != nil {
		return Dream{}, err
	}
	if dream.Status != DreamApplied || len(dream.Changes) == 0 {
		return dream, fault.Errorf(fault.FailedPrecondition, "dream %s is %s; only an applied dream can be undone", dream.CardID, dream.Status)
	}
	for index := len(dream.Changes) - 1; index >= 0; index-- {
		change := dream.Changes[index]
		if change.Before == nil {
			if err = s.store.KV.DeleteMemory(dream.ProjectID, change.MemoryID); err != nil {
				return dream, err
			}
			continue
		}
		restored := *change.Before
		restored.UpdatedAt = home.Timestamp()
		if err = s.store.KV.PutMemory(change.MemoryID, restored); err != nil {
			return dream, err
		}
	}
	dream.Status = DreamUndone
	return dream, s.writeDream(dream)
}

// ToolCall answers a memory host call of a turn (engine.MemoryHooks).
func (s *Service) ToolCall(ctx context.Context, card model.Card, harnessID string, call harness.ProcessCall) (json.RawMessage, error) {
	switch call.Operation {
	case "recall":
		var arguments struct {
			Query string   `json:"query"`
			Limit int      `json:"limit"`
			Files []string `json:"files"`
		}
		if err := json.Unmarshal(call.Arguments, &arguments); err != nil {
			return nil, fault.New(fault.Invalid, "invalid memory_recall arguments")
		}
		result, err := s.Search(ctx, SearchInput{Project: card.ProjectID, Query: arguments.Query, Limit: arguments.Limit, Files: arguments.Files})
		if err != nil {
			return nil, err
		}
		return recallToolResult(result, s.cliWord()), nil
	case "save":
		var arguments struct {
			Content  string   `json:"content"`
			Kind     string   `json:"kind"`
			Files    []string `json:"files"`
			Sources  []string `json:"sources"`
			TTLDays  int      `json:"ttlDays"`
			Replaces string   `json:"replaces"`
		}
		if err := json.Unmarshal(call.Arguments, &arguments); err != nil {
			return nil, fault.New(fault.Invalid, "invalid memory_save arguments")
		}
		result, err := s.Save(SaveInput{
			Project: card.ProjectID, Content: arguments.Content, Kind: arguments.Kind, Files: arguments.Files,
			Sources: arguments.Sources, TTLDays: arguments.TTLDays, ReplacesID: arguments.Replaces, Card: card.ID, Harness: harnessID,
		})
		if err != nil {
			return nil, err
		}
		return saveToolResult(result), nil
	case "apply":
		if card.MemoryRole != engine.MemoryRoleDreamer {
			return nil, fault.New(fault.PermissionDenied, "only a memory dream can apply changes to saved memories")
		}
		return s.dreamApply(card, harnessID, call.Arguments)
	}
	return nil, fault.New(fault.Invalid, "unknown memory call")
}

func saveToolResult(result SaveResult) json.RawMessage {
	view := map[string]any{"id": result.Memory.ID, "kind": result.Memory.Record.Kind}
	switch {
	case result.Reinforced:
		view["status"] = "reinforced an identical lesson"
		view["confidence"] = result.Memory.Confidence
	case result.SupersededID != "":
		view["status"] = "saved; it supersedes " + result.SupersededID
	default:
		view["status"] = "saved"
	}
	if result.SimilarTo != nil {
		view["similarTo"] = map[string]string{"id": result.SimilarTo.ID, "content": agentmemory.Clip(result.SimilarTo.Record.Content, 400)}
		view["hint"] = "A close memory exists; if yours replaces it, save again with replaces set to its ID."
	}
	raw, _ := json.Marshal(view)
	return raw
}
