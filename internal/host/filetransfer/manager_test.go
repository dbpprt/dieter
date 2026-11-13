package filetransfer

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
)

func TestUploadResumeReplayCommitAndRecovery(t *testing.T) {
	t.Parallel()
	home, root := t.TempDir(), t.TempDir()
	m := Manager{Home: home}
	ctx := t.Context()
	payload := bytes.Repeat([]byte{0, 255, 3}, files.ChunkSize)
	source := files.Entry{Size: int64(len(payload)), SHA256: files.Digest(payload), Modified: time.Now().Add(-time.Hour).UnixNano(), Mode: 0o640}
	u, err := m.Begin(ctx, "stable-operation", root, "nested/result.bin", files.Missing, source)
	if err != nil {
		t.Fatal(err)
	}
	chunk := payload[:files.ChunkSize]
	u, err = m.Write(ctx, u.ID, 0, chunk, files.Digest(chunk))
	if err != nil {
		t.Fatal(err)
	}
	// Reconstructing the manager simulates loss of every in-memory observation.
	m = Manager{Home: home}
	resumed, err := m.Begin(ctx, "stable-operation", root, "nested/result.bin", files.Missing, source)
	if err != nil || resumed.Offset != files.ChunkSize {
		t.Fatalf("resume %+v %v", resumed, err)
	}
	if _, err = m.Write(ctx, u.ID, 0, chunk, files.Digest(chunk)); err != nil {
		t.Fatal(err)
	}
	different := bytes.Repeat([]byte{1}, files.ChunkSize)
	if _, err = m.Write(ctx, u.ID, 0, different, files.Digest(different)); err == nil {
		t.Fatal("accepted different chunk replay")
	}
	if _, err = m.Commit(ctx, u.ID); err == nil {
		t.Fatal("committed incomplete upload")
	}
	for offset := int64(files.ChunkSize); offset < source.Size; offset += files.ChunkSize {
		b := payload[offset:min(offset+files.ChunkSize, source.Size)]
		if _, err = m.Write(ctx, u.ID, offset, b, files.Digest(b)); err != nil {
			t.Fatal(err)
		}
	}
	if u, err = m.Commit(ctx, u.ID); err != nil || u.State != "committed" {
		t.Fatalf("commit %+v %v", u, err)
	}
	if _, err = m.Commit(ctx, u.ID); err != nil {
		t.Fatal("commit replay", err)
	}
	got, err := files.Stat(ctx, root, "nested/result.bin", true)
	if err != nil || got.SHA256 != source.SHA256 {
		t.Fatalf("%+v %v", got, err)
	}
	// Model a crash after publish but before recording the commit receipt.
	u.State = "committing"
	if err = m.save(u); err != nil {
		t.Fatal(err)
	}
	if u, err = m.Commit(ctx, u.ID); err != nil || u.State != "committed" {
		t.Fatalf("lost response recovery %+v %v", u, err)
	}
	source.Size++
	if _, err = m.Begin(ctx, "stable-operation", root, "nested/result.bin", files.Missing, source); err == nil {
		t.Fatal("accepted operation ID reuse")
	}
}
func TestUploadCorruptionConflictAbortAndBounds(t *testing.T) {
	t.Parallel()
	m := Manager{Home: t.TempDir()}
	root := t.TempDir()
	ctx := t.Context()
	body := []byte("payload")
	source := files.Entry{Size: int64(len(body)), SHA256: files.Digest(body), Modified: 1, Mode: 0o600}
	for _, test := range []string{"corrupt", "conflict", "abort"} {
		t.Run(test, func(t *testing.T) {
			u, err := m.Begin(ctx, test, root, test, files.Missing, source)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = m.Write(ctx, u.ID, 0, body, "bad"); err == nil {
				t.Fatal("accepted bad checksum")
			}
			if _, err = m.Write(ctx, u.ID, 0, body, files.Digest(body)); err != nil {
				t.Fatal(err)
			}
			switch test {
			case "corrupt":
				if err = os.WriteFile(filepath.Join(m.directory(u.ID), "0000000000000000.chunk"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
			case "conflict":
				if err = os.WriteFile(filepath.Join(root, test), []byte("other writer"), 0o600); err != nil {
					t.Fatal(err)
				}
			case "abort":
				if _, err = m.Abort(ctx, u.ID); err != nil {
					t.Fatal(err)
				}
			}
			if _, err = m.Commit(ctx, u.ID); err == nil {
				t.Fatal("invalid commit succeeded")
			}
		})
	}
	source.Size = MaxFileSize + 1
	if _, err := m.Begin(ctx, "large", root, "large", files.Missing, source); err == nil {
		t.Fatal("accepted oversized file")
	}
}

func TestUploadAdmissionRecoversOrphanAndExpiredStaging(t *testing.T) {
	t.Parallel()
	m := Manager{Home: t.TempDir()}
	root := t.TempDir()
	ctx := t.Context()
	orphan := files.Digest([]byte("orphan"))
	if err := os.MkdirAll(m.directory(orphan), 0o700); err != nil {
		t.Fatal(err)
	}
	source := files.Entry{SHA256: files.Digest(nil), Mode: 0o600}
	old, err := m.Begin(ctx, "old", root, "old", files.Missing, source)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(m.directory(orphan)); !os.IsNotExist(err) {
		t.Fatal("orphan retained")
	}
	old.Expires = time.Now().Add(-time.Hour).Unix()
	if err = m.save(old); err != nil {
		t.Fatal(err)
	}
	if _, err = m.Begin(ctx, "new", root, "new", files.Missing, source); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(m.directory(old.ID)); !os.IsNotExist(err) {
		t.Fatal("expired staging retained")
	}
}

func TestUploadAcceptsPipelinedChunksWithinTheWindow(t *testing.T) {
	t.Parallel()
	home, root := t.TempDir(), t.TempDir()
	m := Manager{Home: home}
	ctx := t.Context()
	payload := bytes.Repeat([]byte{7, 1, 9, 4}, (Window+3)*files.ChunkSize/4)
	payload = append(payload, 42)
	source := files.Entry{Size: int64(len(payload)), SHA256: files.Digest(payload), Modified: 1, Mode: 0o600}
	u, err := m.Begin(ctx, "pipelined", root, "out.bin", files.Missing, source)
	if err != nil || u.Offset != 0 {
		t.Fatalf("begin %+v %v", u, err)
	}
	chunk := func(offset int64) []byte { return payload[offset:min(offset+files.ChunkSize, source.Size)] }
	write := func(offset int64) (Upload, error) {
		b := chunk(offset)
		return m.Write(ctx, u.ID, offset, b, files.Digest(b))
	}
	if _, err = write(Window * files.ChunkSize); err == nil {
		t.Fatal("accepted a chunk beyond the window")
	}
	// Chunks ahead of the offset are kept; the offset is the contiguous prefix.
	for _, index := range []int64{2, 1, Window - 1} {
		if got, err := write(index * files.ChunkSize); err != nil || got.Offset != 0 {
			t.Fatalf("chunk %d: %+v %v", index, got, err)
		}
	}
	different := bytes.Repeat([]byte{1}, files.ChunkSize)
	if _, err = m.Write(ctx, u.ID, files.ChunkSize, different, files.Digest(different)); err == nil {
		t.Fatal("accepted a different replay of a chunk ahead of the offset")
	}
	if got, err := write(0); err != nil || got.Offset != 3*files.ChunkSize {
		t.Fatalf("prefix %+v %v", got, err)
	}
	// A restarted daemon derives the same offset from the published chunks.
	m = Manager{Home: home}
	if got, err := m.Begin(ctx, "pipelined", root, "out.bin", files.Missing, source); err != nil || got.Offset != 3*files.ChunkSize {
		t.Fatalf("resume %+v %v", got, err)
	}
	if _, err = m.Commit(ctx, u.ID); err == nil {
		t.Fatal("committed an upload with a gap")
	}
	for offset := int64(3 * files.ChunkSize); offset < source.Size; offset += files.ChunkSize {
		if _, err = write(offset); err != nil {
			t.Fatalf("chunk at %d: %v", offset, err)
		}
	}
	// A staged chunk left by a crashed write is removed with the chunks.
	if err = os.WriteFile(filepath.Join(m.directory(u.ID), ".dieter-write-crashed"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if u, err = m.Commit(ctx, u.ID); err != nil || u.State != "committed" || u.Offset != source.Size {
		t.Fatalf("commit %+v %v", u, err)
	}
	entries, err := os.ReadDir(m.directory(u.ID))
	if err != nil || len(entries) != 1 || entries[0].Name() != "session.json" {
		t.Fatalf("staging not cleaned: %v %v", entries, err)
	}
	got, err := files.Stat(ctx, root, "out.bin", true)
	if err != nil || got.SHA256 != source.SHA256 {
		t.Fatalf("%+v %v", got, err)
	}
}

// Writes record the offset every checkpoint, so finding it never rescans
// every chunk of a large upload.
func TestUploadRecordsTheOffsetAtCheckpoints(t *testing.T) {
	t.Parallel()
	m := Manager{Home: t.TempDir()}
	ctx := t.Context()
	chunk := bytes.Repeat([]byte{5}, files.ChunkSize)
	const chunks = checkpoint/files.ChunkSize + 2
	whole := bytes.Repeat(chunk, chunks)
	source := files.Entry{Size: int64(len(whole)), SHA256: files.Digest(whole), Modified: 1, Mode: 0o600}
	u, err := m.Begin(ctx, "checkpoint", t.TempDir(), "large.bin", files.Missing, source)
	if err != nil {
		t.Fatal(err)
	}
	for i := range int64(chunks - 1) {
		if _, err = m.Write(ctx, u.ID, i*files.ChunkSize, chunk, files.Digest(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	recorded, err := m.read(u.ID)
	if err != nil || recorded.Offset != checkpoint {
		t.Fatalf("recorded offset %d, want %d: %v", recorded.Offset, checkpoint, err)
	}
	if current, err := m.Get(ctx, u.ID); err != nil || current.Offset != (chunks-1)*files.ChunkSize {
		t.Fatalf("current offset %+v: %v", current, err)
	}
}
