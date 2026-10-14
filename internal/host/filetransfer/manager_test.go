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
