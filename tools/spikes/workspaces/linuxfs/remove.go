package linuxfs

import (
	"os"
	"path/filepath"
)

// RemoveAll removes path like os.RemoveAll after making every directory
// below it searchable and writable by the owner (overlayfs leaves mode-000
// work directories behind).
func RemoveAll(path string) error {
	if err := makeWritable(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.RemoveAll(path)
}

func makeWritable(dir string) error {
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return nil
	}
	if fi.Mode().Perm()&0o700 != 0o700 {
		if err := os.Chmod(dir, fi.Mode().Perm()|0o700); err != nil {
			return err
		}
	}
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	ents, err := f.ReadDir(-1)
	f.Close()
	if err != nil {
		return err
	}
	for _, e := range ents {
		if e.IsDir() {
			if err := makeWritable(filepath.Join(dir, e.Name())); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
	}
	return nil
}
