//go:build darwin || linux

// Package tree observes directory states: a full-hash oracle (Scan), an
// incremental stat-cache manifest, git ignore classification and a
// deterministic fixture repository generator.
package tree

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"dieter.spike/workspaces/core"
)

// ScanOptions tunes Scan. The zero value is the default.
type ScanOptions struct {
	Workers int // directory and hash workers each; 0 means GOMAXPROCS
}

// ScanStats summarizes one Scan.
type ScanStats struct {
	Entries  int           `json:"entries"` // all entries in the tree, directories included
	Files    int           `json:"files"`   // regular files hashed
	Bytes    int64         `json:"bytes"`   // bytes hashed
	Duration time.Duration `json:"duration"`
}

// Scan walks root without git and returns its full state: every entry
// lstat'ed, every regular file hashed, every symlink read, non-noise xattrs
// hashed. The root-level ".git" entry is skipped. Entries that disappear
// while scanning are left out.
func Scan(root string, opt ScanOptions) (core.Tree, ScanStats, error) {
	start := time.Now()
	abs, err := absRoot(root)
	if err != nil {
		return nil, ScanStats{}, err
	}
	workers := defaultWorkers(opt.Workers)
	out := core.Tree{}
	var mu sync.Mutex
	put := func(rel string, e core.Entry) {
		mu.Lock()
		out[rel] = e
		mu.Unlock()
	}
	var files atomic.Int64
	var bytes atomic.Int64

	jobs := make(chan node, workers*64)
	var hashErr error
	var hashErrOnce sync.Once
	var hwg sync.WaitGroup
	for range workers {
		hwg.Add(1)
		go func() {
			defer hwg.Done()
			for n := range jobs {
				e, hashed, err := fileEntry(n)
				if err != nil {
					if !vanished(err) {
						hashErrOnce.Do(func() { hashErr = err })
					}
					continue
				}
				files.Add(1)
				bytes.Add(hashed)
				put(n.rel, e)
			}
		}()
	}

	walkErr := walk(abs, workers, func(n node) error {
		if n.st.typ == core.File {
			jobs <- n
			return nil
		}
		e, err := otherEntry(n)
		if err != nil {
			if vanished(err) {
				return nil
			}
			return err
		}
		put(n.rel, e)
		return nil
	})
	close(jobs)
	hwg.Wait()
	if walkErr != nil {
		return nil, ScanStats{}, walkErr
	}
	if hashErr != nil {
		return nil, ScanStats{}, hashErr
	}
	return out, ScanStats{
		Entries:  len(out),
		Files:    int(files.Load()),
		Bytes:    bytes.Load(),
		Duration: time.Since(start),
	}, nil
}

// fileEntry hashes a regular file and reads its xattrs.
func fileEntry(n node) (core.Entry, int64, error) {
	h, k, err := hashRegular(n.path)
	if err != nil {
		return core.Entry{}, 0, err
	}
	x, err := readXattrs(n.path)
	if err != nil {
		return core.Entry{}, 0, fmt.Errorf("xattrs %s: %w", n.path, err)
	}
	return core.Entry{Type: core.File, Mode: n.st.mode, Size: n.st.size, Hash: h, Xattrs: x}, k, nil
}

// otherEntry builds the entry of a directory, symlink or special file.
func otherEntry(n node) (core.Entry, error) {
	e := core.Entry{Type: n.st.typ, Mode: n.st.mode}
	if n.st.typ == core.Symlink {
		t, err := readlink(n.path)
		if err != nil {
			return e, err
		}
		e.Target, e.Size = t, n.st.size
	}
	x, err := readXattrs(n.path)
	if err != nil {
		return e, fmt.Errorf("xattrs %s: %w", n.path, err)
	}
	e.Xattrs = x
	return e, nil
}
