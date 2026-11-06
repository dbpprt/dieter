package api

import (
	"context"
	"errors"
	"os"
	"syscall"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	transfers "github.com/dbpprt/dieter/internal/host/filetransfer"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *filesAPI) transferRoot(ctx context.Context, p *dieterv1.TransferPath) (string, error) {
	if p == nil {
		return "", fault.Invalidf("transfer target required")
	}
	if (p.ProjectId == "") == (p.CardId == "") {
		return "", fault.Invalidf("exactly one project or conversation required")
	}
	project, err := api.server.scopedProject(kanban.WithCheckout(ctx, p.CheckoutId), p.ProjectId, p.CardId)
	if err != nil {
		return "", err
	}
	return projectRoot(project)
}
func transferError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	if _, ok := fault.KindOf(err); ok {
		return err
	}
	if errors.Is(err, os.ErrNotExist) {
		return fault.Wrap(fault.NotFound, err)
	}
	if errors.Is(err, os.ErrPermission) {
		return fault.Wrap(fault.PermissionDenied, err)
	}
	if errors.Is(err, syscall.ENOSPC) || errors.Is(err, syscall.EDQUOT) {
		return fault.Wrap(fault.ResourceExhausted, err)
	}
	if errors.Is(err, os.ErrExist) {
		return fault.Wrap(fault.Conflict, err)
	}
	return fault.Wrap(fault.FailedPrecondition, err)
}
func transferEntry(e files.Entry) *dieterv1.TransferEntry {
	return &dieterv1.TransferEntry{Path: e.Path, Kind: e.Kind, Size: e.Size, ModifiedNanos: e.Modified, Revision: e.Revision, Sha256: e.SHA256, Mode: e.Mode}
}
func uploadResult(u transfers.Upload, err error) (*dieterv1.FileUpload, error) {
	if err != nil {
		return nil, transferError(err)
	}
	return &dieterv1.FileUpload{Id: u.ID, Offset: u.Offset, Size: u.Source.Size, State: u.State, ExpiresUnix: u.Expires}, nil
}
func (api *filesAPI) uploads() transfers.Manager {
	return transfers.Manager{Home: api.server.store.Root}
}

func (api *filesAPI) StatTransferFile(ctx context.Context, r *dieterv1.TransferPath) (*dieterv1.TransferEntry, error) {
	root, err := api.transferRoot(ctx, r)
	if err != nil {
		return nil, err
	}
	e, err := files.Stat(ctx, root, r.Path, r.Checksum)
	return transferEntry(e), transferError(err)
}
func (api *filesAPI) ListTransferFiles(ctx context.Context, r *dieterv1.ListTransferFilesRequest) (*dieterv1.TransferPage, error) {
	root, err := api.transferRoot(ctx, r.Target)
	if err != nil {
		return nil, err
	}
	limit := int(r.PageSize)
	if limit == 0 {
		limit = 256
	}
	entries, next, revision, err := files.List(ctx, root, r.Target.Path, r.After, r.Revision, limit)
	if err != nil {
		return nil, transferError(err)
	}
	result := &dieterv1.TransferPage{Next: next, Revision: revision}
	for _, e := range entries {
		result.Entries = append(result.Entries, transferEntry(e))
	}
	return result, nil
}
func (api *filesAPI) ReadFileChunk(ctx context.Context, r *dieterv1.ReadFileChunkRequest) (*dieterv1.FileChunk, error) {
	root, err := api.transferRoot(ctx, r.Target)
	if err != nil {
		return nil, err
	}
	b, err := files.Read(ctx, root, r.Target.Path, r.Revision, r.Offset, int(r.Length))
	if err != nil {
		return nil, transferError(err)
	}
	return &dieterv1.FileChunk{Data: b, Sha256: files.Digest(b)}, nil
}
func (api *filesAPI) BeginFileUpload(ctx context.Context, r *dieterv1.BeginFileUploadRequest) (*dieterv1.FileUpload, error) {
	root, err := api.transferRoot(ctx, r.Target)
	if err != nil {
		return nil, err
	}
	return uploadResult(api.uploads().Begin(ctx, r.OperationId, root, r.Target.Path, r.ExpectedRevision, files.Entry{Size: r.Size, SHA256: r.Sha256, Modified: r.ModifiedNanos, Mode: r.Mode}))
}
func (api *filesAPI) WriteFileChunk(ctx context.Context, r *dieterv1.WriteFileChunkRequest) (*dieterv1.FileUpload, error) {
	return uploadResult(api.uploads().Write(ctx, r.Id, r.Offset, r.Data, r.Sha256))
}
func (api *filesAPI) GetFileUpload(ctx context.Context, r *dieterv1.FileUploadRequest) (*dieterv1.FileUpload, error) {
	return uploadResult(api.uploads().Get(ctx, r.Id))
}
func (api *filesAPI) AbortFileUpload(ctx context.Context, r *dieterv1.FileUploadRequest) (*dieterv1.FileUpload, error) {
	return uploadResult(api.uploads().Abort(ctx, r.Id))
}
func (api *filesAPI) CommitFileUpload(ctx context.Context, r *dieterv1.FileUploadRequest) (*dieterv1.FileUpload, error) {
	api.server.filesMu.Lock()
	defer api.server.filesMu.Unlock()
	u, err := api.uploads().Commit(ctx, r.Id)
	if err == nil {
		api.server.changesets.InvalidatePath(u.Root)
	}
	return uploadResult(u, err)
}
func (api *filesAPI) DeleteTransferFile(ctx context.Context, r *dieterv1.DeleteTransferFileRequest) (*emptypb.Empty, error) {
	root, err := api.transferRoot(ctx, r.Target)
	if err != nil {
		return nil, err
	}
	api.server.filesMu.Lock()
	defer api.server.filesMu.Unlock()
	lock, err := fsx.LockHome(ctx, api.server.store.Root)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err = files.Remove(ctx, root, r.Target.Path, r.Revision); err != nil {
		return nil, transferError(err)
	}
	api.server.changesets.InvalidatePath(root)
	return &emptypb.Empty{}, nil
}
