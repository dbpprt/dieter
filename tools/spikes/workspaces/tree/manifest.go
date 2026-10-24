//go:build darwin || linux

package tree

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"dieter.spike/workspaces/core"
)

// MEntry is one manifest entry: the observable state plus the stat fields
// that decide whether the cached hash can be trusted.
type MEntry struct {
	Type    core.EntryType `json:"type"`
	Mode    uint32         `json:"mode"`
	Size    int64          `json:"size"`
	MtimeNs int64          `json:"mtimeNs"`
	CtimeNs int64          `json:"ctimeNs"`
	Ino     uint64         `json:"ino"`
	Dev     uint64         `json:"dev"`
	Hash    string         `json:"hash,omitempty"`
	Target  string         `json:"target,omitempty"`
	Xattrs  string         `json:"xattrs,omitempty"`
}

// Manifest is a stat cache of a directory, like git's index. CreatedAt is
// when the walk that produced it started; entries stamped at or after it
// (minus a small clock slack) are racy and never reused.
type Manifest struct {
	Root      string            `json:"root"`
	Entries   map[string]MEntry `json:"entries"`
	CreatedAt time.Time         `json:"createdAt"`
}

// ManifestStats summarizes one manifest build.
type ManifestStats struct {
	Entries  int           `json:"entries"`  // all entries, directories included
	Files    int           `json:"files"`    // regular files
	Rehashed int           `json:"rehashed"` // regular files whose content was hashed
	Bytes    int64         `json:"bytes"`    // bytes hashed
	Duration time.Duration `json:"duration"`
}

// BuildManifest walks root like Scan. With prev, a file's hash and xattrs
// are reused when type, mode, size, mtime, ctime and inode all match the
// previous entry and that entry was not racy; everything else is hashed.
func BuildManifest(root string, prev *Manifest) (*Manifest, ManifestStats, error) {
	var lookup func(n node) (MEntry, bool)
	if prev != nil {
		lookup = func(n node) (MEntry, bool) {
			pe, ok := prev.Entries[n.rel]
			if !ok || !sameContentStat(pe, n.st) || pe.CtimeNs != n.st.ctime || pe.Ino != n.st.ino ||
				racy(pe, prev.CreatedAt) {
				return MEntry{}, false
			}
			return pe, true
		}
	}
	return buildManifest(root, lookup)
}

// InheritManifest builds the manifest of viewRoot, a fresh copy-on-write
// clone of base.Root, without hashing what the clone preserved: a file whose
// type, mode, size and mtime equal the base entry inherits the base hash and
// xattrs (the view's own inode, ctime and device are recorded). Other files
// are hashed. It trusts the clone to have preserved content and xattrs
// whenever it preserved mtime.
func InheritManifest(base *Manifest, viewRoot string) (*Manifest, ManifestStats, error) {
	if base == nil {
		return nil, ManifestStats{}, fmt.Errorf("tree: InheritManifest needs a base manifest")
	}
	return buildManifest(viewRoot, func(n node) (MEntry, bool) {
		pe, ok := base.Entries[n.rel]
		if !ok || !sameContentStat(pe, n.st) || racy(pe, base.CreatedAt) {
			return MEntry{}, false
		}
		return pe, true
	})
}

func sameContentStat(pe MEntry, st statInfo) bool {
	return pe.Type == st.typ && pe.Mode == st.mode && pe.Size == st.size && pe.MtimeNs == st.mtime
}

// racy reports an entry whose mtime or ctime is not safely older than the
// walk that recorded it: a same-size rewrite within the same timestamp tick
// would be invisible to the stat comparison, so such entries are re-read.
func racy(pe MEntry, createdAt time.Time) bool {
	if createdAt.IsZero() {
		return false
	}
	cut := createdAt.UnixNano() - racySlackNs
	return pe.MtimeNs >= cut || pe.CtimeNs >= cut
}

func buildManifest(root string, lookup func(n node) (MEntry, bool)) (*Manifest, ManifestStats, error) {
	start := time.Now()
	abs, err := absRoot(root)
	if err != nil {
		return nil, ManifestStats{}, err
	}
	workers := defaultWorkers(0)
	m := &Manifest{Root: abs, Entries: map[string]MEntry{}, CreatedAt: start}
	var mu sync.Mutex
	put := func(rel string, e MEntry) {
		mu.Lock()
		m.Entries[rel] = e
		mu.Unlock()
	}
	var files, rehashed, bytes atomic.Int64

	jobs := make(chan node, workers*64)
	var hashErr error
	var hashErrOnce sync.Once
	var hwg sync.WaitGroup
	for range workers {
		hwg.Add(1)
		go func() {
			defer hwg.Done()
			for n := range jobs {
				e, k, err := fileEntry(n)
				if err != nil {
					if !vanished(err) {
						hashErrOnce.Do(func() { hashErr = err })
					}
					continue
				}
				rehashed.Add(1)
				bytes.Add(k)
				put(n.rel, mentry(n.st, e))
			}
		}()
	}

	walkErr := walk(abs, workers, func(n node) error {
		var pe MEntry
		var hit bool
		if lookup != nil {
			pe, hit = lookup(n)
		}
		if n.st.typ == core.File {
			files.Add(1)
			if !hit {
				jobs <- n
				return nil
			}
			put(n.rel, mentry(n.st, core.Entry{Hash: pe.Hash, Xattrs: pe.Xattrs}))
			return nil
		}
		var e core.Entry
		if hit {
			e = core.Entry{Xattrs: pe.Xattrs}
			if n.st.typ == core.Symlink {
				t, err := readlink(n.path)
				if err != nil {
					if vanished(err) {
						return nil
					}
					return err
				}
				e.Target = t
			}
		} else {
			var err error
			if e, err = otherEntry(n); err != nil {
				if vanished(err) {
					return nil
				}
				return err
			}
		}
		put(n.rel, mentry(n.st, e))
		return nil
	})
	close(jobs)
	hwg.Wait()
	if walkErr != nil {
		return nil, ManifestStats{}, walkErr
	}
	if hashErr != nil {
		return nil, ManifestStats{}, hashErr
	}
	return m, ManifestStats{
		Entries:  len(m.Entries),
		Files:    int(files.Load()),
		Rehashed: int(rehashed.Load()),
		Bytes:    bytes.Load(),
		Duration: time.Since(start),
	}, nil
}

func mentry(st statInfo, e core.Entry) MEntry {
	return MEntry{
		Type: st.typ, Mode: st.mode, Size: st.size,
		MtimeNs: st.mtime, CtimeNs: st.ctime, Ino: st.ino, Dev: st.dev,
		Hash: e.Hash, Target: e.Target, Xattrs: e.Xattrs,
	}
}

// Tree returns the observable state recorded in the manifest.
func (m *Manifest) Tree() core.Tree {
	t := make(core.Tree, len(m.Entries))
	for p, e := range m.Entries {
		t[p] = core.Entry{Type: e.Type, Mode: e.Mode, Size: e.Size, Hash: e.Hash, Target: e.Target, Xattrs: e.Xattrs}
	}
	return t
}

// Save writes the manifest as JSON, atomically (temp file and rename).
func (m *Manifest) Save(path string) error {
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// LoadManifest reads a manifest written by Save.
func LoadManifest(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	m := &Manifest{}
	if err := json.Unmarshal(data, m); err != nil {
		return nil, fmt.Errorf("tree: manifest %s: %w", path, err)
	}
	if m.Entries == nil {
		m.Entries = map[string]MEntry{}
	}
	return m, nil
}
