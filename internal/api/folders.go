package api

import (
	"context"
	"slices"
	"strings"
	"time"

	core "github.com/dbpprt/dieter/internal/folders"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	sf "github.com/dbpprt/dieter/internal/store/folders"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Synced folder rules:
//   - Agent turns never change folders, membership, held deletions or the
//     trash: those calls refuse a turn token (the CLI refuses them inside a
//     turn before it reaches any daemon, also with --machine).
//   - A remote device registers only itself as a client member.
//   - Member paths stay on their daemon; only this daemon reports its own.

type foldersAPI struct{ server *Server }

// folderOperator refuses changes from agent turns.
func folderOperator(ctx context.Context) error {
	if requestHeader(ctx, turnTokenMetadata) != "" {
		return fault.New(fault.PermissionDenied, "agent turns cannot change synced folders; ask the user")
	}
	return nil
}

func (api *foldersAPI) engine() *hostfolders.Engine { return api.server.folders }

func folderMode(mode dieterv1.FolderMode) core.Mode {
	switch mode {
	case dieterv1.FolderMode_FOLDER_MODE_SEND_ONLY:
		return core.ModeSendOnly
	case dieterv1.FolderMode_FOLDER_MODE_RECEIVE_ONLY:
		return core.ModeReceiveOnly
	case dieterv1.FolderMode_FOLDER_MODE_TWO_WAY:
		return core.ModeTwoWay
	}
	return ""
}

func protoFolderMode(mode core.Mode) dieterv1.FolderMode {
	switch mode {
	case core.ModeSendOnly:
		return dieterv1.FolderMode_FOLDER_MODE_SEND_ONLY
	case core.ModeReceiveOnly:
		return dieterv1.FolderMode_FOLDER_MODE_RECEIVE_ONLY
	case core.ModeTwoWay:
		return dieterv1.FolderMode_FOLDER_MODE_TWO_WAY
	}
	return dieterv1.FolderMode_FOLDER_MODE_UNSPECIFIED
}

func protoFolderState(state string) dieterv1.FolderState {
	switch state {
	case "idle":
		return dieterv1.FolderState_FOLDER_STATE_IDLE
	case "scanning":
		return dieterv1.FolderState_FOLDER_STATE_SCANNING
	case "syncing":
		return dieterv1.FolderState_FOLDER_STATE_SYNCING
	case "paused":
		return dieterv1.FolderState_FOLDER_STATE_PAUSED
	case "attention":
		return dieterv1.FolderState_FOLDER_STATE_ATTENTION
	case "error":
		return dieterv1.FolderState_FOLDER_STATE_ERROR
	}
	return dieterv1.FolderState_FOLDER_STATE_UNSPECIFIED
}

func folderGuard(guard dieterv1.FolderDeleteGuard) core.Guard {
	switch guard {
	case dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_STRICT:
		return core.GuardStrict
	case dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_OFF:
		return core.GuardOff
	}
	return core.GuardDefault
}

func protoFolderGuard(guard core.Guard) dieterv1.FolderDeleteGuard {
	switch guard {
	case core.GuardStrict:
		return dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_STRICT
	case core.GuardOff:
		return dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_OFF
	}
	return dieterv1.FolderDeleteGuard_FOLDER_DELETE_GUARD_DEFAULT
}

func folderTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}

// folderMembers lists every member from the membership records, adding this
// daemon's local details.
func (api *foldersAPI) folderMembers(folderID string) []*dieterv1.FolderMember {
	var members []*dieterv1.FolderMember
	self, _ := api.engine().DaemonID()
	_ = api.server.store.KV.FolderMembers(folderID+".", func(record schema.FolderMemberRecord) error {
		if record.FolderID != folderID {
			return nil
		}
		member := &dieterv1.FolderMember{
			FolderId: folderID, MemberId: record.DaemonID, Kind: dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_DAEMON, Name: record.Name,
			Mode: protoFolderMode(core.Mode(record.Mode)), Paused: record.Paused, State: protoFolderState(record.State), HomeDaemonId: record.DaemonID,
			Sequence: record.Sequence, LastSyncAt: record.LastSyncAt, StateDetail: record.StateDetail, NeedFiles: record.NeedFiles, NeedBytes: record.NeedBytes, Conflicts: int32(record.Conflicts),
		}
		if record.DaemonID == self {
			if local, err := api.server.store.Folders.Member(folderID); err == nil {
				api.addLocalMember(member, local)
			}
		}
		members = append(members, member)
		for _, client := range record.Clients {
			members = append(members, &dieterv1.FolderMember{
				FolderId: folderID, MemberId: client.DeviceID, Kind: dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_CLIENT, Name: client.Name,
				Mode: protoFolderMode(core.Mode(client.Mode)), HomeDaemonId: record.DaemonID, Sequence: client.Acknowledged, LastSyncAt: client.LastSeenAt,
				State: dieterv1.FolderState_FOLDER_STATE_IDLE,
			})
		}
		return nil
	})
	return members
}

func (api *foldersAPI) addLocalMember(member *dieterv1.FolderMember, local sf.Member) {
	status := api.engine().StatusOf(local.FolderID)
	member.Path, member.RescanSeconds, member.BandwidthLimit, member.Concurrency, member.Quarantine, member.Watch =
		local.Path, int32(local.RescanSeconds), local.Bandwidth, int32(local.Concurrency), local.Quarantine, local.Watch
	member.Mode, member.Paused = protoFolderMode(local.Mode), local.Paused
	member.State, member.StateDetail = protoFolderState(status.State), status.Detail
	if local.Paused {
		member.State = dieterv1.FolderState_FOLDER_STATE_PAUSED
	}
	member.NeedFiles, member.NeedBytes, member.LastSyncAt = status.NeedFiles, status.NeedBytes, folderTime(status.LastSyncAt)
	if index, err := api.server.store.Folders.Index(local.FolderID); err == nil {
		member.Sequence = index.Head()
	}
}

func (api *foldersAPI) localMember(folderID string) (*dieterv1.FolderMember, error) {
	local, err := api.server.store.Folders.Member(folderID)
	if err != nil {
		return nil, err
	}
	self, err := api.engine().DaemonID()
	if err != nil {
		return nil, err
	}
	member := &dieterv1.FolderMember{FolderId: folderID, MemberId: self, Kind: dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_DAEMON, HomeDaemonId: self, Name: api.engine().Name()}
	api.addLocalMember(member, local)
	return member, nil
}

func (api *foldersAPI) folder(definition hostfolders.Definition) *dieterv1.Folder {
	return &dieterv1.Folder{
		Id: definition.ID, Name: definition.Name, Rules: slices.Clone(definition.Rules), TrashDays: int32(definition.TrashDays),
		DeleteGuard: protoFolderGuard(definition.DeleteGuard), ProjectId: definition.ProjectID, Archived: definition.Archived, CreatedAt: definition.CreatedAt,
		Members: api.folderMembers(definition.ID), ConflictFields: definition.ConflictFields,
	}
}

func (api *foldersAPI) resolve(ref string) (hostfolders.Definition, error) {
	if strings.TrimSpace(ref) == "" {
		return hostfolders.Definition{}, fault.Invalidf("folder required")
	}
	return api.engine().Resolve(ref)
}

func (api *foldersAPI) CreateFolder(ctx context.Context, r *dieterv1.CreateFolderRequest) (*dieterv1.Folder, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	name := r.GetName()
	change := hostfolders.DefinitionChange{Name: &name}
	rules := slices.Clone(r.GetRules())
	if !r.GetNoDefaultRules() {
		rules = append(slices.Clone(core.DefaultRules), rules...)
	}
	change.Rules = &rules
	days := int(r.GetTrashDays())
	switch {
	case days == 0:
		days = 30
	case days < 0:
		days = 0
	}
	change.TrashDays = &days
	guard := folderGuard(r.GetDeleteGuard())
	change.DeleteGuard = &guard
	project := r.GetProjectId()
	change.ProjectID = &project
	definition, err := api.engine().CreateFolder(change)
	if err != nil {
		return nil, domainFailure(err)
	}
	return api.folder(definition), nil
}

func (api *foldersAPI) UpdateFolder(ctx context.Context, r *dieterv1.UpdateFolderRequest) (*dieterv1.Folder, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	change := hostfolders.DefinitionChange{Name: r.Name, ProjectID: r.ProjectId}
	if r.GetSetRules() {
		rules := slices.Clone(r.GetRules())
		change.Rules = &rules
	}
	if r.TrashDays != nil {
		days := max(int(r.GetTrashDays()), 0)
		change.TrashDays = &days
	}
	if r.DeleteGuard != nil {
		guard := folderGuard(r.GetDeleteGuard())
		change.DeleteGuard = &guard
	}
	definition, err = api.engine().UpdateFolder(definition.ID, change)
	if err != nil {
		return nil, domainFailure(err)
	}
	return api.folder(definition), nil
}

func (api *foldersAPI) ArchiveFolder(ctx context.Context, r *dieterv1.FolderRef) (*dieterv1.Folder, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	archived := true
	definition, err = api.engine().UpdateFolder(definition.ID, hostfolders.DefinitionChange{Archived: &archived})
	if err != nil {
		return nil, domainFailure(err)
	}
	return api.folder(definition), nil
}

func (api *foldersAPI) ListFolders(_ context.Context, r *dieterv1.ListFoldersRequest) (*dieterv1.FolderList, error) {
	definitions, err := api.engine().Definitions(r.GetIncludeArchived())
	if err != nil {
		return nil, err
	}
	list := &dieterv1.FolderList{}
	for _, definition := range definitions {
		list.Folders = append(list.Folders, api.folder(definition))
	}
	return list, nil
}

func (api *foldersAPI) AttachFolder(ctx context.Context, r *dieterv1.AttachFolderRequest) (*dieterv1.AttachFolderResult, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	join := "merge"
	if r.GetJoin() == dieterv1.FolderJoin_FOLDER_JOIN_ADOPT {
		join = "adopt"
	}
	result, err := api.engine().Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: r.GetPath(), Mode: folderMode(r.GetMode()), Join: join, DryRun: r.GetDryRun()})
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.AttachFolderResult{DryRun: result.DryRun, Adopt: result.Adopt, NewFiles: result.New, Conflicts: result.Conflicts, Trash: result.Trash}
	for _, entry := range result.Plan {
		out.Plan = append(out.Plan, &dieterv1.FolderPlanEntry{Path: entry.Path, Action: entry.Action})
	}
	if result.DryRun {
		out.Member = &dieterv1.FolderMember{FolderId: definition.ID, Path: result.Member.Path, Mode: protoFolderMode(result.Member.Mode), Kind: dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_DAEMON}
		return out, nil
	}
	if out.Member, err = api.localMember(definition.ID); err != nil {
		return nil, err
	}
	return out, nil
}

func (api *foldersAPI) UpdateFolderMember(ctx context.Context, r *dieterv1.UpdateFolderMemberRequest) (*dieterv1.FolderMember, error) {
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	// Without changes this is a read of the membership: no write, and allowed
	// for agent turns.
	if r.Mode == nil && r.Paused == nil && r.RescanSeconds == nil && r.BandwidthLimit == nil && r.Concurrency == nil && r.Quarantine == nil && r.Watch == nil {
		return api.localMember(definition.ID)
	}
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	change := hostfolders.MemberChange{Paused: r.Paused, Quarantine: r.Quarantine, Watch: r.Watch, Bandwidth: r.BandwidthLimit}
	if r.Mode != nil {
		mode := folderMode(r.GetMode())
		change.Mode = &mode
	}
	if r.RescanSeconds != nil {
		value := int(r.GetRescanSeconds())
		change.RescanSeconds = &value
	}
	if r.Concurrency != nil {
		value := int(r.GetConcurrency())
		change.Concurrency = &value
	}
	if _, err := api.engine().UpdateMember(ctx, definition.ID, change); err != nil {
		return nil, domainFailure(err)
	}
	return api.localMember(definition.ID)
}

func (api *foldersAPI) DetachFolder(ctx context.Context, r *dieterv1.FolderRef) (*emptypb.Empty, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	if err := api.engine().Detach(ctx, definition.ID); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}

// clientDevice is the device a client registration may name.
func clientDevice(ctx context.Context, requested string) (string, error) {
	if requestHeader(ctx, operatorSubjectMetadata) == "" {
		return requested, nil
	}
	caller := requestHeader(ctx, deviceIDMetadata)
	if requested != "" && requested != caller {
		return "", fault.New(fault.PermissionDenied, "a device registers only itself")
	}
	return caller, nil
}

func (api *foldersAPI) RegisterFolderClient(ctx context.Context, r *dieterv1.RegisterFolderClientRequest) (*dieterv1.FolderMember, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	device, err := clientDevice(ctx, r.GetDeviceId())
	if err != nil {
		return nil, err
	}
	client, err := api.engine().RegisterClient(ctx, definition.ID, device, r.GetName(), folderMode(r.GetMode()))
	if err != nil {
		return nil, domainFailure(err)
	}
	self, _ := api.engine().DaemonID()
	return &dieterv1.FolderMember{FolderId: definition.ID, MemberId: client.DeviceID, Kind: dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_CLIENT, Name: client.Name,
		Mode: protoFolderMode(client.Mode), HomeDaemonId: self, LastSyncAt: client.LastSeenAt, State: dieterv1.FolderState_FOLDER_STATE_IDLE}, nil
}

func (api *foldersAPI) UnregisterFolderClient(ctx context.Context, r *dieterv1.FolderClientRef) (*emptypb.Empty, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	device, err := clientDevice(ctx, r.GetDeviceId())
	if err != nil {
		return nil, err
	}
	if err := api.engine().UnregisterClient(ctx, definition.ID, device); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *foldersAPI) GetFolderIndex(ctx context.Context, r *dieterv1.GetFolderIndexRequest) (*dieterv1.FolderIndexPage, error) {
	if !sf.ValidID(r.GetFolderId()) {
		return nil, fault.Invalidf("folder ID required")
	}
	if r.GetPageSize() < 0 || r.GetPageSize() > 512 {
		return nil, fault.Invalidf("page size must be 1..512")
	}
	page, err := api.engine().IndexPage(ctx, r.GetFolderId(), r.GetIndexId(), r.GetAfterSequence(), int(r.GetPageSize()), r.GetMemberId(), r.GetAcknowledgedSequence())
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.FolderIndexPage{IndexId: page.IndexID, Reset_: page.Reset, Sequence: page.Sequence, HeadSequence: page.Head, More: page.More}
	for _, entry := range page.Entries {
		out.Entries = append(out.Entries, hostfolders.EntryToProto(entry))
	}
	return out, nil
}

func (api *foldersAPI) ApplyFolderEntry(ctx context.Context, r *dieterv1.ApplyFolderEntryRequest) (*dieterv1.FolderEntry, error) {
	if r.GetEntry() == nil || !sf.ValidID(r.GetFolderId()) {
		return nil, fault.Invalidf("folder and entry required")
	}
	entry, err := api.engine().ApplyEntry(ctx, r.GetFolderId(), hostfolders.EntryFromProto(r.GetEntry()))
	if err != nil {
		return nil, domainFailure(err)
	}
	return hostfolders.EntryToProto(entry), nil
}

func (api *foldersAPI) GetFolderBlocks(ctx context.Context, r *dieterv1.GetFolderBlocksRequest) (*dieterv1.FolderBlockPage, error) {
	if !sf.ValidID(r.GetFolderId()) || r.GetAfter() < 0 || r.GetPageSize() < 0 || r.GetPageSize() > 4096 {
		return nil, fault.Invalidf("folder ID and a page within bounds required")
	}
	if err := core.ValidatePath(r.GetPath()); err != nil {
		return nil, err
	}
	blocks, err := api.engine().Blocks(ctx, r.GetFolderId(), r.GetPath(), r.GetSha256())
	if err != nil {
		return nil, domainFailure(err)
	}
	limit := int(r.GetPageSize())
	if limit == 0 {
		limit = 4096
	}
	start := min(int(r.GetAfter()), len(blocks))
	end := min(start+limit, len(blocks))
	out := &dieterv1.FolderBlockPage{Sha256: r.GetSha256(), BlockSize: core.BlockSize, Total: int32(len(blocks)), Blocks: blocks[start:end]}
	if end < len(blocks) {
		out.Next = int32(end)
	}
	return out, nil
}

func (api *foldersAPI) status(folderID string) (*dieterv1.FolderStatus, error) {
	member, err := api.localMember(folderID)
	if err != nil {
		return nil, err
	}
	index, err := api.server.store.Folders.Index(folderID)
	if err != nil {
		return nil, err
	}
	status := api.engine().StatusOf(folderID)
	entries, filesCount, bytes := index.Stats()
	out := &dieterv1.FolderStatus{Member: member, IndexId: index.ID(), Sequence: index.Head(), Entries: entries, Files: filesCount, Bytes: bytes,
		LastScanAt: folderTime(status.LastScanAt), LocalChanges: status.LocalChanges, OutOfSync: status.OutOfSync}
	for path, entry := range index.Snapshot() {
		if entry.Kind == core.KindFile && strings.Contains(path, " (conflict, ") {
			out.Conflicts = append(out.Conflicts, path)
		}
	}
	slices.Sort(out.Conflicts)
	for _, problem := range status.Errors {
		out.Errors = append(out.Errors, &dieterv1.FolderProblem{Path: problem.Path, Message: problem.Message, At: folderTime(problem.At)})
	}
	for _, problem := range status.Unsyncable {
		out.Unsyncable = append(out.Unsyncable, &dieterv1.FolderProblem{Path: problem.Path, Message: problem.Message, At: folderTime(problem.At)})
	}
	if pending := status.Pending; pending != nil {
		out.PendingDeletions = &dieterv1.FolderPendingDeletions{Count: int64(len(pending.Paths)), Source: pending.Source}
		out.PendingDeletions.Sample = pending.Paths[:min(32, len(pending.Paths))]
	}
	peerIDs := make([]string, 0, len(status.Peers))
	for id := range status.Peers {
		peerIDs = append(peerIDs, id)
	}
	slices.Sort(peerIDs)
	for _, id := range peerIDs {
		peer := status.Peers[id]
		out.Peers = append(out.Peers, &dieterv1.FolderPeerStatus{MemberId: id, Name: peer.Name, Kind: dieterv1.FolderMemberKind_FOLDER_MEMBER_KIND_DAEMON, LastSyncAt: folderTime(peer.LastSyncAt), Error: peer.Error})
	}
	return out, nil
}

func (api *foldersAPI) GetFolderStatus(_ context.Context, r *dieterv1.FolderRef) (*dieterv1.FolderStatus, error) {
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	return api.status(definition.ID)
}

func (api *foldersAPI) RescanFolder(ctx context.Context, r *dieterv1.FolderRef) (*dieterv1.FolderStatus, error) {
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	if _, err := api.server.store.Folders.Member(definition.ID); err != nil {
		return nil, err
	}
	wait, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	if err := api.engine().WaitCycle(wait, definition.ID, true); err != nil {
		return nil, domainFailure(err)
	}
	return api.status(definition.ID)
}

func (api *foldersAPI) ResolveFolderDeletions(ctx context.Context, r *dieterv1.ResolveFolderDeletionsRequest) (*dieterv1.FolderStatus, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	if err := api.engine().ResolveDeletions(ctx, definition.ID, r.GetApply()); err != nil {
		return nil, domainFailure(err)
	}
	return api.status(definition.ID)
}

func (api *foldersAPI) ListFolderTrash(_ context.Context, r *dieterv1.ListFolderTrashRequest) (*dieterv1.FolderTrashPage, error) {
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	items, next, total, err := api.engine().TrashPage(definition.ID, r.GetAfter(), int(r.GetPageSize()))
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.FolderTrashPage{Next: next, TotalBytes: total}
	for _, item := range items {
		out.Items = append(out.Items, &dieterv1.FolderTrashItem{Id: item.ID, Path: item.Path, Size: item.Size, Sha256: item.SHA256, DeletedAt: item.DeletedAt, DeletedBy: item.DeletedBy, Reason: item.Reason})
	}
	return out, nil
}

func (api *foldersAPI) RestoreFolderTrash(ctx context.Context, r *dieterv1.RestoreFolderTrashRequest) (*dieterv1.FolderEntry, error) {
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	entry, err := api.engine().RestoreTrash(ctx, definition.ID, r.GetId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return hostfolders.EntryToProto(entry), nil
}

func (api *foldersAPI) PurgeFolderTrash(ctx context.Context, r *dieterv1.PurgeFolderTrashRequest) (*emptypb.Empty, error) {
	if err := folderOperator(ctx); err != nil {
		return nil, err
	}
	definition, err := api.resolve(r.GetFolderId())
	if err != nil {
		return nil, err
	}
	if err := api.engine().PurgeTrash(ctx, definition.ID, r.GetIds()); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}
