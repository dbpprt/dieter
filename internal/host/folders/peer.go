package folders

import (
	"context"
	"errors"
	"time"

	core "github.com/dbpprt/dieter/internal/folders"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// A peer connection is reused for a few minutes: daemon tokens are short-lived.
const peerConnLifetime = 4 * time.Minute

type peerConn struct {
	client dieterclient.Client
	close  func()
	at     time.Time
}

type peerClient struct {
	client dieterclient.Client
	self   string
}

type indexPage struct {
	IndexID  string
	Reset    bool
	Entries  []core.Entry
	Sequence uint64
	Head     uint64
	More     bool
}

// withPeer runs fn with a connection to daemonID, reusing a recent one.
func (e *Engine) withPeer(ctx context.Context, daemonID string, fn func(peerClient) error) error {
	if e.opts.Dial == nil {
		return fault.New(fault.Unavailable, "this machine has no peers")
	}
	self, err := e.DaemonID()
	if err != nil {
		return err
	}
	e.peerMu.Lock()
	conn := e.peers[daemonID]
	if conn != nil && e.now().Sub(conn.at) > peerConnLifetime {
		conn.close()
		delete(e.peers, daemonID)
		conn = nil
	}
	e.peerMu.Unlock()
	if conn == nil {
		attempt, cancel := context.WithTimeout(ctx, 45*time.Second)
		client, closeFn, err := e.opts.Dial(attempt, daemonID)
		cancel()
		if err != nil {
			return err
		}
		conn = &peerConn{client: client, close: closeFn, at: e.now()}
		e.peerMu.Lock()
		if old := e.peers[daemonID]; old != nil {
			old.close()
		}
		e.peers[daemonID] = conn
		e.peerMu.Unlock()
	}
	err = fn(peerClient{client: conn.client, self: self})
	if transportFailure(err) {
		e.peerMu.Lock()
		if e.peers[daemonID] == conn {
			conn.close()
			delete(e.peers, daemonID)
		}
		e.peerMu.Unlock()
	}
	return err
}

func transportFailure(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.Unauthenticated, codes.Internal, codes.Unknown, codes.DeadlineExceeded:
		return true
	}
	return false
}

func (e *Engine) closePeers() {
	e.peerMu.Lock()
	defer e.peerMu.Unlock()
	for id, conn := range e.peers {
		conn.close()
		delete(e.peers, id)
	}
}

func (p peerClient) index(ctx context.Context, folderID, indexID string, after uint64, memberID string, ack uint64) (indexPage, error) {
	call, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	page, err := p.client.GetFolderIndex(call, &dieterv1.GetFolderIndexRequest{FolderId: folderID, IndexId: indexID, AfterSequence: after, PageSize: 512, MemberId: memberID, AcknowledgedSequence: ack})
	if err != nil {
		return indexPage{}, err
	}
	out := indexPage{IndexID: page.GetIndexId(), Reset: page.GetReset_(), Sequence: page.GetSequence(), Head: page.GetHeadSequence(), More: page.GetMore()}
	for _, entry := range page.GetEntries() {
		out.Entries = append(out.Entries, EntryFromProto(entry))
	}
	return out, nil
}

func (p peerClient) read(ctx context.Context, folderID, path, sha string, offset int64, length int) ([]byte, error) {
	call, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	chunk, err := p.client.ReadFileChunk(call, &dieterv1.ReadFileChunkRequest{Target: &dieterv1.TransferPath{FolderId: folderID, Path: path}, Revision: sha, Offset: offset, Length: int32(length)})
	if err != nil {
		return nil, err
	}
	return chunk.GetData(), nil
}

func (p peerClient) blocks(ctx context.Context, folderID, path, sha string) ([]string, error) {
	var blocks []string
	after := int32(0)
	for {
		call, cancel := context.WithTimeout(ctx, 60*time.Second)
		page, err := p.client.GetFolderBlocks(call, &dieterv1.GetFolderBlocksRequest{FolderId: folderID, Path: path, Sha256: sha, After: after})
		cancel()
		if err != nil {
			return nil, err
		}
		blocks = append(blocks, page.GetBlocks()...)
		if page.GetNext() == 0 || int(page.GetNext()) >= int(page.GetTotal()) || len(blocks) >= int(page.GetTotal()) {
			return blocks, nil
		}
		after = page.GetNext()
	}
}

// EntryFromProto converts a wire entry.
func EntryFromProto(entry *dieterv1.FolderEntry) core.Entry {
	out := core.Entry{Path: entry.GetPath(), Size: entry.GetSize(), Modified: entry.GetModifiedNanos(), Executable: entry.GetExecutable(), SHA256: entry.GetSha256(), Sequence: entry.GetSequence(), AuthorID: entry.GetAuthorId(), AuthorName: entry.GetAuthorName()}
	switch entry.GetKind() {
	case dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_FILE:
		out.Kind = core.KindFile
	case dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_DIRECTORY:
		out.Kind = core.KindDirectory
	case dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_DELETED:
		out.Kind = core.KindDeleted
	}
	for _, counter := range entry.GetVersion() {
		out.Version = append(out.Version, core.Counter{Actor: counter.GetActor(), Value: counter.GetValue()})
	}
	return out
}

// EntryToProto converts an entry for the wire.
func EntryToProto(entry core.Entry) *dieterv1.FolderEntry {
	out := &dieterv1.FolderEntry{Path: entry.Path, Size: entry.Size, ModifiedNanos: entry.Modified, Executable: entry.Executable, Sha256: entry.SHA256, Sequence: entry.Sequence, AuthorId: entry.AuthorID, AuthorName: entry.AuthorName}
	switch entry.Kind {
	case core.KindFile:
		out.Kind = dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_FILE
	case core.KindDirectory:
		out.Kind = dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_DIRECTORY
	case core.KindDeleted:
		out.Kind = dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_DELETED
	}
	for _, counter := range entry.Version {
		out.Version = append(out.Version, &dieterv1.FolderCounter{Actor: counter.Actor, Value: counter.Value})
	}
	return out
}
