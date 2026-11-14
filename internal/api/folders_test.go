package api

import (
	"testing"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/testkit"
)

// Agent turns read folders but never change them; a remote device registers
// only itself.
func TestFolderChangesRefuseAgentTurnsAndForgedDevices(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, &testkit.FakeRunner{}, testkit.MockCatalog())
	ctx := t.Context()
	turn := withHeaders(ctx, map[string]string{turnTokenMetadata: "dtt1:card:turn:token"})

	_, err := client.CreateFolder(turn, &dieterv1.CreateFolderRequest{Name: "Inbox"})
	wantCode(t, err, connect.CodePermissionDenied, "an agent creating a folder")
	folder, err := client.CreateFolder(ctx, &dieterv1.CreateFolderRequest{Name: "Inbox"})
	if err != nil || folder.GetName() != "Inbox" || len(folder.GetRules()) == 0 || folder.GetTrashDays() != 30 {
		t.Fatalf("create = %v, %v", folder, err)
	}
	dir := t.TempDir()
	_, err = client.AttachFolder(turn, &dieterv1.AttachFolderRequest{FolderId: folder.GetId(), Path: dir})
	wantCode(t, err, connect.CodePermissionDenied, "an agent attaching a folder")
	attached, err := client.AttachFolder(ctx, &dieterv1.AttachFolderRequest{FolderId: "Inbox", Path: dir})
	if err != nil || attached.GetMember().GetPath() == "" {
		t.Fatalf("attach by name = %v, %v", attached, err)
	}
	// Reading the membership is allowed; changing it is not.
	member, err := client.UpdateFolderMember(turn, &dieterv1.UpdateFolderMemberRequest{FolderId: folder.GetId()})
	if err != nil || member.GetPath() == "" {
		t.Fatalf("member read = %v, %v", member, err)
	}
	paused := true
	_, err = client.UpdateFolderMember(turn, &dieterv1.UpdateFolderMemberRequest{FolderId: folder.GetId(), Paused: &paused})
	wantCode(t, err, connect.CodePermissionDenied, "an agent pausing a folder")
	for name, call := range map[string]func() error{
		"update": func() error {
			_, e := client.UpdateFolder(turn, &dieterv1.UpdateFolderRequest{FolderId: folder.GetId(), Name: &paused2})
			return e
		},
		"archive": func() error {
			_, e := client.ArchiveFolder(turn, &dieterv1.FolderRef{FolderId: folder.GetId()})
			return e
		},
		"detach": func() error {
			_, e := client.DetachFolder(turn, &dieterv1.FolderRef{FolderId: folder.GetId()})
			return e
		},
		"purge": func() error {
			_, e := client.PurgeFolderTrash(turn, &dieterv1.PurgeFolderTrashRequest{FolderId: folder.GetId()})
			return e
		},
		"resolve": func() error {
			_, e := client.ResolveFolderDeletions(turn, &dieterv1.ResolveFolderDeletionsRequest{FolderId: folder.GetId()})
			return e
		},
		"register": func() error {
			_, e := client.RegisterFolderClient(turn, &dieterv1.RegisterFolderClientRequest{FolderId: folder.GetId(), DeviceId: "dv_x"})
			return e
		},
	} {
		wantCode(t, call(), connect.CodePermissionDenied, "an agent: "+name)
	}
	if _, err := client.GetFolderStatus(turn, &dieterv1.FolderRef{FolderId: folder.GetId()}); err != nil {
		t.Fatalf("an agent reading status: %v", err)
	}
	remote := withHeaders(ctx, map[string]string{operatorSubjectMetadata: "github:1", deviceIDMetadata: "dv_remote"})
	_, err = client.RegisterFolderClient(remote, &dieterv1.RegisterFolderClientRequest{FolderId: folder.GetId(), DeviceId: "dv_other", Name: "Phone"})
	wantCode(t, err, connect.CodePermissionDenied, "registering another device")
	registered, err := client.RegisterFolderClient(remote, &dieterv1.RegisterFolderClientRequest{FolderId: folder.GetId(), Name: "Phone"})
	if err != nil || registered.GetMemberId() != "dv_remote" {
		t.Fatalf("self registration = %v, %v", registered, err)
	}
}

var paused2 = "Renamed"
