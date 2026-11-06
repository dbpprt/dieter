//go:build linux

package linuxfs

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// Prepare validates the layout and creates Upper and an empty Work. Lower
// and Mount must be existing directories; Upper is kept (a session reuses
// it across turns); Work may only hold overlayfs's own "work" and "index"
// leftovers, which are removed. It must not run while another namespace
// still has the overlay mounted.
func (o Overlay) Prepare() error {
	named := []struct{ name, path string }{
		{"lower", o.Lower}, {"upper", o.Upper}, {"work", o.Work}, {"mount", o.Mount},
	}
	resolved := make([]string, len(named))
	for i, n := range named {
		if n.path == "" || !filepath.IsAbs(n.path) {
			return fmt.Errorf("linuxfs: %s path %q is not absolute", n.name, n.path)
		}
		resolved[i] = resolvePath(n.path)
	}
	for i := range named {
		for j := range named {
			if i != j && within(resolved[i], resolved[j]) {
				return fmt.Errorf("linuxfs: %s %s overlaps %s %s", named[i].name, named[i].path, named[j].name, named[j].path)
			}
		}
	}
	for _, n := range []struct{ name, path string }{{"lower", o.Lower}, {"mount", o.Mount}} {
		fi, err := os.Stat(n.path)
		if err != nil {
			return fmt.Errorf("linuxfs: %s: %w", n.name, err)
		}
		if !fi.IsDir() {
			return fmt.Errorf("linuxfs: %s %s is not a directory", n.name, n.path)
		}
	}
	if err := os.MkdirAll(o.Upper, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(o.Work, 0o700); err != nil {
		return err
	}
	ents, err := os.ReadDir(o.Work)
	if err != nil {
		return err
	}
	for _, e := range ents {
		if e.Name() != "work" && e.Name() != "index" {
			return fmt.Errorf("linuxfs: work dir %s holds unexpected %q", o.Work, e.Name())
		}
		if err := RemoveAll(filepath.Join(o.Work, e.Name())); err != nil {
			return err
		}
	}
	var su, sw unix.Stat_t
	if err := unix.Stat(o.Upper, &su); err != nil {
		return &fs.PathError{Op: "stat", Path: o.Upper, Err: err}
	}
	if err := unix.Stat(o.Work, &sw); err != nil {
		return &fs.PathError{Op: "stat", Path: o.Work, Err: err}
	}
	if su.Dev != sw.Dev {
		return errors.New("linuxfs: upper and work must be on the same filesystem and btrfs subvolume")
	}
	return nil
}

// resolvePath resolves symlinks in the longest existing prefix of p.
func resolvePath(p string) string {
	p = filepath.Clean(p)
	rest := ""
	for cur := p; ; {
		if r, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(r, rest)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}

// within reports whether a equals b or lies below it.
func within(a, b string) bool {
	return a == b || strings.HasPrefix(a, strings.TrimSuffix(b, "/")+"/")
}
