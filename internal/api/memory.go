package api

import (
	"context"
	"strings"

	"google.golang.org/protobuf/types/known/emptypb"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	hostmemory "github.com/dbpprt/dieter/internal/host/memory"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kv"
)

// memoryAPI is MemoryService: agent memory (docs/adr/0007-agent-memory.md).
//
// Agent turns may read the status, recall and save, always in their own
// conversation's project; everything else belongs to people. Peer daemons
// recall with local_only, answered from this daemon's index alone.
type memoryAPI struct{ server *Server }

// memoryProject is the project a memory call is about: the turn's own
// project for an agent, the requested one otherwise.
func (s *Server) memoryProject(ctx context.Context, projectID string) (string, string, string, error) {
	card, _, agent, err := s.turnCaller(ctx)
	if err != nil {
		return "", "", "", err
	}
	if agent {
		if projectID != "" {
			if project, resolveErr := s.store.Kanban.ResolveProject(projectID); resolveErr != nil || project.ID != card.ProjectID {
				return "", "", "", fault.New(fault.PermissionDenied, "an agent turn can use only its own project's memory")
			}
		}
		return card.ProjectID, card.ID, card.Provider, nil
	}
	if strings.TrimSpace(projectID) == "" {
		return "", "", "", fault.New(fault.Invalid, "project_id is required")
	}
	return projectID, "", "", nil
}

func (api *memoryAPI) GetMemoryStatus(ctx context.Context, request *dieterv1.GetMemoryStatusRequest) (*dieterv1.MemoryStatus, error) {
	projectID := request.GetProjectId()
	if card, _, agent, err := api.server.turnCaller(ctx); err != nil {
		return nil, err
	} else if agent {
		projectID = card.ProjectID
	}
	status, err := api.server.memory.Status(projectID)
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.MemoryStatus{MachineId: status.MachineID, Machine: status.Machine, IndexBytes: status.IndexBytes, LastError: status.LastError}
	for _, project := range status.Projects {
		out.Projects = append(out.Projects, &dieterv1.MemoryProjectStatus{
			ProjectId: project.ProjectID, Name: project.Name, Enabled: project.Enabled, Cards: int32(project.Cards),
			Observations: project.Observations, Saved: int32(project.Saved), LastIndexedAt: project.LastIndexed,
			Backlog: int32(project.Backlog), LastDreamAt: project.LastDreamAt, LastDreamCardId: project.LastDreamCard,
			NextDream: project.NextDream, FinishedSinceDream: int32(project.FinishedSince),
		})
	}
	return out, nil
}

func (api *memoryAPI) SearchMemory(ctx context.Context, request *dieterv1.SearchMemoryRequest) (*dieterv1.MemorySearchResult, error) {
	projectID, _, _, err := api.server.memoryProject(ctx, request.GetProjectId())
	if err != nil {
		return nil, err
	}
	result, err := api.server.memory.Search(ctx, hostmemory.SearchInput{
		Project: projectID, Query: request.GetQuery(), Limit: int(request.GetLimit()), Files: request.GetFiles(),
		Kinds: request.GetKinds(), LocalOnly: request.GetLocalOnly(),
	})
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.MemorySearchResult{Unreachable: result.Unreachable, Truncated: result.Truncated, Excluded: int32(result.Excluded)}
	for _, memory := range result.Memories {
		out.Memories = append(out.Memories, protoSavedMemory(memory))
	}
	for _, hit := range result.Hits {
		out.Hits = append(out.Hits, &dieterv1.MemoryHit{
			CardId: hit.CardID, MachineId: hit.MachineID, Machine: hit.Machine, Title: hit.Title, Lane: hit.Lane,
			Harness: hit.Harness, LastActivityAt: hit.LastActivityAt, Scope: hit.Scope, Snippets: hit.Snippets,
			FinalAnswer: hit.FinalAnswer, MessageId: hit.MessageID,
		})
	}
	return out, nil
}

func (api *memoryAPI) SaveMemory(ctx context.Context, request *dieterv1.SaveMemoryRequest) (*dieterv1.SaveMemoryResult, error) {
	projectID, cardID, harnessID, err := api.server.memoryProject(ctx, request.GetProjectId())
	if err != nil {
		return nil, err
	}
	result, err := api.server.memory.Save(hostmemory.SaveInput{
		Project: projectID, Content: request.GetContent(), Kind: request.GetKind(), Files: request.GetFiles(),
		Sources: request.GetSources(), TTLDays: int(request.GetTtlDays()), ReplacesID: request.GetReplacesId(),
		Card: cardID, Harness: harnessID,
	})
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.SaveMemoryResult{Memory: protoSavedMemory(result.Memory), SupersededId: result.SupersededID, Reinforced: result.Reinforced}
	if result.SimilarTo != nil {
		out.SimilarTo = protoSavedMemory(*result.SimilarTo)
	}
	return out, nil
}

func (api *memoryAPI) ForgetMemory(ctx context.Context, request *dieterv1.ForgetMemoryRequest) (*emptypb.Empty, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot forget memory; ask the user"); err != nil {
		return nil, err
	}
	if err := api.server.memory.Forget(request.GetProjectId(), request.GetMemoryId(), request.GetCardId(), request.GetAll()); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *memoryAPI) ReindexMemory(ctx context.Context, request *dieterv1.ReindexMemoryRequest) (*dieterv1.MemoryStatus, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot reindex memory; ask the user"); err != nil {
		return nil, err
	}
	if err := api.server.memory.Reindex(request.GetProjectId()); err != nil {
		return nil, domainFailure(err)
	}
	return api.GetMemoryStatus(ctx, &dieterv1.GetMemoryStatusRequest{ProjectId: request.GetProjectId()})
}

func (api *memoryAPI) SetCardMemory(ctx context.Context, request *dieterv1.SetCardMemoryRequest) (*dieterv1.Card, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot switch memory; ask the user"); err != nil {
		return nil, err
	}
	card, err := api.server.app.SetCardMemory(request.GetCardId(), request.GetEnabled())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoCard(card), nil
}

func (api *memoryAPI) GetMemorySettings(ctx context.Context, _ *emptypb.Empty) (*dieterv1.MemorySettings, error) {
	if err := api.server.validateTurnCaller(ctx); err != nil {
		return nil, err
	}
	entry, err := api.server.store.KV.MemorySettings()
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoMemorySettings(entry), nil
}

func (api *memoryAPI) UpdateMemorySettings(ctx context.Context, request *dieterv1.UpdateMemorySettingsRequest) (*dieterv1.MemorySettings, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot change the memory setting"); err != nil {
		return nil, err
	}
	value := request.GetSettings()
	if value == nil {
		return nil, fault.New(fault.Invalid, "memory settings are required")
	}
	defaults := schema.DefaultMemorySettings()
	record := schema.MemorySettingsRecord{
		Dreaming: value.GetDreaming(), Harness: strings.TrimSpace(value.GetHarness()), Model: strings.TrimSpace(value.GetModel()),
		Effort: strings.TrimSpace(value.GetEffort()), AccountID: strings.TrimSpace(value.GetAccountId()), RunOn: strings.TrimSpace(value.GetRunOn()),
		MinHours: int(value.GetMinHours()), MinNewTasks: int(value.GetMinNewTasks()), Window: strings.TrimSpace(value.GetWindow()),
		Apply: strings.TrimSpace(value.GetApply()), MaxOperations: int(value.GetMaxOperations()), MaxRetire: int(value.GetMaxRetirePercent()),
		Instructions: strings.TrimSpace(value.GetInstructions()),
	}
	if record.Harness == "" {
		record.Harness, record.Model = defaults.Harness, defaults.Model
	}
	if record.MinHours == 0 {
		record.MinHours = defaults.MinHours
	}
	if record.MinNewTasks == 0 {
		record.MinNewTasks = defaults.MinNewTasks
	}
	if record.Apply == "" {
		record.Apply = defaults.Apply
	}
	if record.MaxOperations == 0 {
		record.MaxOperations = defaults.MaxOperations
	}
	if record.MaxRetire == 0 {
		record.MaxRetire = defaults.MaxRetire
	}
	// The harness and model must exist here; the dreaming machine checks its
	// own catalog when a dream starts.
	adapter, configured, err := api.server.app.Catalog.ResolveSelection(record.Harness, record.Model)
	if err != nil {
		return nil, err
	}
	if adapter.Runtime == "strix" {
		return nil, fault.New(fault.Invalid, "Strix cannot dream")
	}
	record.Harness, record.Model = adapter.ID, configured.ID
	if record.AccountID != "" && !schema.ValidProviderAccountID(record.AccountID) {
		return nil, fault.New(fault.Invalid, "invalid provider account ID")
	}
	entry, err := api.server.store.KV.PutMemorySettings(record, request.GetExpectedRevision())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoMemorySettings(entry), nil
}

func (api *memoryAPI) StartMemoryDream(ctx context.Context, request *dieterv1.StartMemoryDreamRequest) (*dieterv1.MemoryDream, error) {
	if err := api.server.refuseAgentTurn(ctx, "agents cannot start a dream; ask the user"); err != nil {
		return nil, err
	}
	if strings.TrimSpace(request.GetProjectId()) == "" {
		return nil, fault.New(fault.Invalid, "project_id is required")
	}
	dream, err := api.server.memory.StartDream(ctx, request.GetProjectId())
	if err != nil && dream.CardID == "" {
		return nil, domainFailure(err)
	}
	return protoDream(dream), nil
}

func (api *memoryAPI) ListMemoryDreams(ctx context.Context, request *dieterv1.ListMemoryDreamsRequest) (*dieterv1.MemoryDreamsResponse, error) {
	projectID, _, _, err := api.server.memoryProject(ctx, request.GetProjectId())
	if err != nil {
		return nil, err
	}
	dreams, err := api.server.memory.Dreams(projectID)
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.MemoryDreamsResponse{}
	for _, dream := range dreams {
		out.Dreams = append(out.Dreams, protoDream(dream))
	}
	return out, nil
}

func (api *memoryAPI) ApplyMemoryDream(ctx context.Context, request *dieterv1.MemoryDreamRef) (*dieterv1.MemoryDream, error) {
	return api.dreamAction(ctx, request, "agents cannot apply a dream; ask the user", api.server.memory.ApplyDream)
}

func (api *memoryAPI) DiscardMemoryDream(ctx context.Context, request *dieterv1.MemoryDreamRef) (*dieterv1.MemoryDream, error) {
	return api.dreamAction(ctx, request, "agents cannot discard a dream; ask the user", api.server.memory.DiscardDream)
}

func (api *memoryAPI) UndoMemoryDream(ctx context.Context, request *dieterv1.MemoryDreamRef) (*dieterv1.MemoryDream, error) {
	return api.dreamAction(ctx, request, "agents cannot undo a dream; ask the user", api.server.memory.UndoDream)
}

func (api *memoryAPI) dreamAction(ctx context.Context, request *dieterv1.MemoryDreamRef, refusal string, action func(string) (hostmemory.Dream, error)) (*dieterv1.MemoryDream, error) {
	if err := api.server.refuseAgentTurn(ctx, refusal); err != nil {
		return nil, err
	}
	if strings.TrimSpace(request.GetCardId()) == "" {
		return nil, fault.New(fault.Invalid, "card_id is required")
	}
	dream, err := action(request.GetCardId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoDream(dream), nil
}

func protoSavedMemory(memory hostmemory.Memory) *dieterv1.SavedMemory {
	record := memory.Record
	return &dieterv1.SavedMemory{
		Id: memory.ID, ProjectId: record.Project, Kind: record.Kind, Content: record.Content,
		Files: append([]string(nil), record.Files...), Sources: append([]string(nil), record.Sources...),
		Status: record.Status, SupersededBy: record.SupersededBy, Verified: record.Verified,
		Confidence: memory.Confidence, Reinforcements: int32(memory.Reinforcements), ExpiresAt: record.ExpiresAt,
		CreatedByMachineId: record.CreatedBy.Daemon, CreatedByCardId: record.CreatedBy.Card, CreatedByHarness: record.CreatedBy.Harness,
		DreamCardId: record.DreamCard, CreatedAt: record.CreatedAt, UpdatedAt: record.UpdatedAt, Reason: record.Reason,
	}
}

func protoMemorySettings(entry kv.MemorySettingsEntry) *dieterv1.MemorySettings {
	record := entry.Record
	return &dieterv1.MemorySettings{
		Dreaming: record.Dreaming, Harness: record.Harness, Model: record.Model, Effort: record.Effort,
		AccountId: record.AccountID, RunOn: record.RunOn, MinHours: int32(record.MinHours), MinNewTasks: int32(record.MinNewTasks),
		Window: record.Window, Apply: record.Apply, MaxOperations: int32(record.MaxOperations), MaxRetirePercent: int32(record.MaxRetire),
		Instructions: record.Instructions, Configured: entry.Configured, Revision: entry.Revision, UpdatedAt: record.UpdatedAt,
	}
}

func protoDream(dream hostmemory.Dream) *dieterv1.MemoryDream {
	out := &dieterv1.MemoryDream{
		CardId: dream.CardID, ProjectId: dream.ProjectID, Status: dream.Status, MachineId: dream.MachineID,
		StartedAt: dream.StartedAt, FinishedAt: dream.FinishedAt, Added: int32(dream.Added), Merged: int32(dream.Merged),
		Superseded: int32(dream.Superseded), Retired: int32(dream.Retired), Verified: int32(dream.Verified), Error: dream.Error,
	}
	for _, operation := range dream.Operations {
		out.Operations = append(out.Operations, &dieterv1.MemoryDreamOperation{
			Op: operation.Op, MemoryId: operation.MemoryID, TargetIds: append([]string(nil), operation.Targets...),
			Kind: operation.Kind, Content: operation.Content, Sources: append([]string(nil), operation.Sources...), Reason: operation.Reason,
		})
	}
	return out
}
