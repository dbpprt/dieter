//go:build e2e

package filetransfer

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"testing"
)

type zeroStream struct{ maxRead int }

func (r *zeroStream) Read(p []byte) (int, error) {
	r.maxRead = max(r.maxRead, len(p))
	clear(p)
	return len(p), nil
}

// Exercise offsets beyond 32-bit signed integers without allocating the file
// in memory. The temporary output is removed by the test fixture.
func TestPublishMultiGiBEndToEnd(t *testing.T) {
	const size int64 = (2 << 30) + 17
	hash := sha256.New()
	if _, err := io.CopyBuffer(hash, io.LimitReader(&zeroStream{}, size), make([]byte, ChunkSize)); err != nil {
		t.Fatal(err)
	}
	source := Entry{Size: size, SHA256: hex.EncodeToString(hash.Sum(nil)), Mode: 0o600, Modified: 1}
	stream := &zeroStream{}
	root := t.TempDir()
	if err := Publish(t.Context(), root, "large.bin", Missing, source, io.LimitReader(stream, size)); err != nil {
		t.Fatal(err)
	}
	actual, err := Stat(t.Context(), root, "large.bin", true)
	if err != nil || actual.Size != size || actual.SHA256 != source.SHA256 {
		t.Fatalf("large file %+v: %v", actual, err)
	}
	if stream.maxRead > ChunkSize {
		t.Fatalf("unbounded read buffer: %d", stream.maxRead)
	}
}
