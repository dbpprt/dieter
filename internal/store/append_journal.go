package store

import (
	"bytes"
	"errors"
	"io"
	"os"
)

// Append one durable newline-terminated record. A killed writer may leave a
// partial final record; truncate only that uncommitted suffix before appending
// so the next acknowledged event cannot be swallowed by a corrupt JSON line.
// The caller owns the central cross-process lock.
func appendJournalRecord(path string, line []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 0 {
		last := []byte{0}
		if _, err := file.ReadAt(last, info.Size()-1); err != nil {
			return err
		}
		if last[0] != '\n' {
			end := info.Size()
			boundary := int64(0)
			buffer := make([]byte, 64<<10)
			for end > 0 {
				start := max(int64(0), end-int64(len(buffer)))
				part := buffer[:end-start]
				if _, err := file.ReadAt(part, start); err != nil && !errors.Is(err, io.EOF) {
					return err
				}
				if i := bytes.LastIndexByte(part, '\n'); i >= 0 {
					boundary = start + int64(i) + 1
					break
				}
				end = start
			}
			if err := file.Truncate(boundary); err != nil {
				return err
			}
		}
	}
	if _, err := file.Write(append(line, '\n')); err != nil {
		return err
	}
	return file.Sync()
}
