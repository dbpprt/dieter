package main

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Only regular bounded artifacts created by the test driver may leave the app.
func extractEvidence(data []byte, dir string) error {
	r := tar.NewReader(bytes.NewReader(data))
	count := 0
	var size int64
	for {
		h, err := r.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(h.Name)
		if h.Typeflag == tar.TypeDir {
			continue
		}
		if h.Typeflag != tar.TypeReg || !strings.HasPrefix(name, "e2e/") || strings.Contains(name, "..") || filepath.IsAbs(name) {
			return fmt.Errorf("invalid artifact %q", h.Name)
		}
		count++
		size += h.Size
		if count > 300 || h.Size < 0 || size > 32<<20 {
			return fmt.Errorf("artifact budget exceeded")
		}
		path := filepath.Join(dir, name)
		if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return err
		}
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		_, copyErr := io.CopyN(f, r, h.Size)
		closeErr := f.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
}
