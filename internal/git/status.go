package git

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

var ErrTooManyChanges = fault.New(fault.FailedPrecondition, "checkout has too many changes to display safely")

const cacheTTL = 200 * time.Millisecond

// Reader coalesces the workspace and Changes refreshes that native clients
// intentionally issue together. It retains only one short-lived status result
// per checkout and never stores patches or file contents.
type StatusReader struct {
	mu         sync.Mutex
	runner     Runner
	cache      map[string]cachedSnapshot
	inflight   map[string]*snapshotCall
	generation map[string]uint64
	epoch      uint64
	// invalidated holds, per watched directory, a channel closed by its next
	// Invalidate.
	invalidated map[string]chan struct{}
}

type cachedSnapshot struct {
	value     StatusSnapshot
	createdAt time.Time
}

type snapshotCall struct {
	done       chan struct{}
	value      StatusSnapshot
	err        error
	force      bool
	generation uint64
	epoch      uint64
}

func NewStatusReader(runner Runner) *StatusReader {
	return &StatusReader{
		runner: runner, cache: map[string]cachedSnapshot{}, inflight: map[string]*snapshotCall{},
		generation: map[string]uint64{}, invalidated: map[string]chan struct{}{},
	}
}

func (r *StatusReader) SetRunner(runner Runner) {
	if runner == nil {
		return
	}
	r.mu.Lock()
	r.runner = runner
	r.cache = map[string]cachedSnapshot{}
	r.epoch++
	r.mu.Unlock()
}

func (r *StatusReader) Read(ctx context.Context, directory string, force bool) (StatusSnapshot, error) {
	for {
		r.mu.Lock()
		if !force {
			if cached, ok := r.cache[directory]; ok && time.Since(cached.createdAt) <= cacheTTL {
				value := cloneSnapshot(cached.value)
				r.mu.Unlock()
				return value, nil
			}
		}
		if call := r.inflight[directory]; call != nil {
			r.mu.Unlock()
			select {
			case <-ctx.Done():
				return StatusSnapshot{}, ctx.Err()
			case <-call.done:
			}
			r.mu.Lock()
			current := call.epoch == r.epoch && call.generation == r.generation[directory]
			r.mu.Unlock()
			if !current || (force && !call.force) {
				continue
			}
			return cloneSnapshot(call.value), call.err
		}
		call := &snapshotCall{
			done: make(chan struct{}), force: force, generation: r.generation[directory], epoch: r.epoch,
		}
		r.inflight[directory] = call
		runner := r.runner
		r.mu.Unlock()

		call.value, call.err = ReadStatus(ctx, runner, directory)
		r.mu.Lock()
		if r.inflight[directory] == call {
			delete(r.inflight, directory)
		}
		if call.err == nil && call.epoch == r.epoch && call.generation == r.generation[directory] {
			r.cache[directory] = cachedSnapshot{value: cloneSnapshot(call.value), createdAt: time.Now()}
		}
		current := call.epoch == r.epoch && call.generation == r.generation[directory]
		close(call.done)
		r.mu.Unlock()
		if !current {
			continue
		}
		return cloneSnapshot(call.value), call.err
	}
}

func (r *StatusReader) Invalidate(directory string) {
	r.mu.Lock()
	delete(r.cache, directory)
	r.generation[directory]++
	if changed := r.invalidated[directory]; changed != nil {
		close(changed)
		delete(r.invalidated, directory)
	}
	r.mu.Unlock()
}

// Invalidated is closed by the next Invalidate of directory: a Git
// operation, a file save or a transfer changed it.
func (r *StatusReader) Invalidated(directory string) <-chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	changed := r.invalidated[directory]
	if changed == nil {
		changed = make(chan struct{})
		r.invalidated[directory] = changed
	}
	return changed
}

func cloneSnapshot(value StatusSnapshot) StatusSnapshot {
	value.Files = append([]model.ChangedFile(nil), value.Files...)
	return value
}

// Snapshot is the complete cheap state emitted by one porcelain-v2 status
// command. Line statistics and patches are intentionally absent: they belong
// to the selected-file diff path, not the Changes list path.
type StatusSnapshot struct {
	Branch     string
	HeadSHA    string
	Upstream   string
	Ahead      int
	Behind     int
	Files      []model.ChangedFile
	Dirty      bool
	Conflicted bool
	// Revision changes with anything in the tree; each file's Revision changes
	// only with that file, and IndexFingerprint only with the staged content.
	Revision         string
	IndexFingerprint string
	// Truncated means the status output hit its bound: Files holds the
	// records read before it. Displays show them; mutations refuse.
	Truncated bool
}

// Complete returns ErrTooManyChanges for a truncated snapshot.
func (s StatusSnapshot) Complete() error {
	if s.Truncated {
		return ErrTooManyChanges
	}
	return nil
}

func ReadStatus(ctx context.Context, runner Runner, directory string) (StatusSnapshot, error) {
	result, err := runner.Run(ctx, directory, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
	if err != nil {
		return StatusSnapshot{}, err
	}
	output := result.Output
	if result.Truncated {
		// Keep every complete record; the last one may be cut off.
		if end := bytes.LastIndexByte(output, 0); end >= 0 {
			output = output[:end+1]
		} else {
			output = nil
		}
	}
	value, err := ParseStatus(output)
	if err != nil && !result.Truncated {
		return StatusSnapshot{}, err
	}
	value.Truncated = result.Truncated
	if value.Truncated {
		value.Dirty = true
	}
	value.Revision = revision(directory, output, value.Files)
	return value, nil
}

// ParseStatus reads porcelain-v2 output. Each file's Revision starts as the
// digest of its records (HEAD and index object names and modes, XY state);
// ReadStatus folds in the working-tree file's metadata, which Git does not
// hash.
func ParseStatus(raw []byte) (StatusSnapshot, error) {
	var value StatusSnapshot
	index := sha256.New()
	records := zeroFields(raw)
	for position := 0; position < len(records); position++ {
		record := records[position]
		switch {
		case strings.HasPrefix(record, "# branch.oid "):
			value.HeadSHA = strings.TrimPrefix(record, "# branch.oid ")
			if value.HeadSHA == "(initial)" {
				value.HeadSHA = ""
			}
		case strings.HasPrefix(record, "# branch.head "):
			value.Branch = strings.TrimPrefix(record, "# branch.head ")
			if value.Branch == "(detached)" {
				value.Branch = ""
			}
		case strings.HasPrefix(record, "# branch.upstream "):
			value.Upstream = strings.TrimPrefix(record, "# branch.upstream ")
		case strings.HasPrefix(record, "# branch.ab "):
			fields := strings.Fields(strings.TrimPrefix(record, "# branch.ab "))
			if len(fields) == 2 {
				value.Ahead, _ = strconv.Atoi(strings.TrimPrefix(fields[0], "+"))
				value.Behind, _ = strconv.Atoi(strings.TrimPrefix(fields[1], "-"))
			}
		case strings.HasPrefix(record, "1 "):
			fields := strings.SplitN(record, " ", 9)
			if len(fields) != 9 || len(fields[1]) != 2 {
				return value, fault.Invalidf("invalid ordinary porcelain-v2 record")
			}
			file := changedFile(fields[1], fields[2], fields[8], "")
			file.Revision = recordDigest(record)
			indexEntry(index, fields[1][:1], fields[4], fields[7], fields[8], "")
			value.Files = append(value.Files, file)
		case strings.HasPrefix(record, "2 "):
			fields := strings.SplitN(record, " ", 10)
			if len(fields) != 10 || position+1 >= len(records) {
				return value, fault.Invalidf("invalid renamed porcelain-v2 record")
			}
			position++
			file := changedFile(fields[1], fields[2], fields[9], records[position])
			file.Revision = recordDigest(record, records[position])
			indexEntry(index, fields[1][:1], fields[4], fields[7], fields[9], records[position])
			if strings.HasPrefix(fields[8], "R") {
				if file.Staged {
					file.IndexStatus = "renamed"
				} else {
					file.WorktreeStatus = "renamed"
				}
				file.Status = "renamed"
			} else if strings.HasPrefix(fields[8], "C") {
				if file.Staged {
					file.IndexStatus = "copied"
				} else {
					file.WorktreeStatus = "copied"
				}
				file.Status = "copied"
			}
			value.Files = append(value.Files, file)
		case strings.HasPrefix(record, "u "):
			fields := strings.SplitN(record, " ", 11)
			if len(fields) != 11 {
				return value, fault.Invalidf("invalid unmerged porcelain-v2 record")
			}
			file := changedFile(fields[1], fields[2], fields[10], "")
			file.Conflicted, file.Status = true, "conflicted"
			file.Revision = recordDigest(record)
			_, _ = index.Write([]byte(record))
			_, _ = index.Write([]byte{0})
			value.Files = append(value.Files, file)
		case strings.HasPrefix(record, "? "):
			filePath := strings.TrimPrefix(record, "? ")
			value.Files = append(value.Files, model.ChangedFile{
				Path: filePath, Status: "untracked", WorktreeStatus: "untracked", Unstaged: true, Revision: recordDigest(record),
			})
		case strings.HasPrefix(record, "! "):
			// Ignored files are not requested, but tolerate them if Git emits one.
		default:
			return value, fault.Invalidf("unknown porcelain-v2 record %q", record)
		}
	}
	_, _ = index.Write([]byte(value.HeadSHA))
	value.IndexFingerprint = hex.EncodeToString(index.Sum(nil)[:16])
	sort.SliceStable(value.Files, func(i, j int) bool { return value.Files[i].Path < value.Files[j].Path })
	value.Dirty = len(value.Files) > 0
	for _, file := range value.Files {
		value.Conflicted = value.Conflicted || file.Conflicted
	}
	return value, nil
}

func changedFile(xy, submodule, filePath, previousPath string) model.ChangedFile {
	file := model.ChangedFile{
		Path: filePath, PreviousPath: previousPath, Submodule: strings.HasPrefix(submodule, "S"),
	}
	if len(xy) != 2 {
		file.Status = "modified"
		return file
	}
	if xy[0] != '.' {
		file.Staged = true
		file.IndexStatus = statusName(xy[0])
	}
	if xy[1] != '.' {
		file.Unstaged = true
		file.WorktreeStatus = statusName(xy[1])
	}
	if file.WorktreeStatus != "" {
		file.Status = file.WorktreeStatus
	} else {
		file.Status = file.IndexStatus
	}
	file.Conflicted = strings.ContainsRune(xy, 'U') || xy == "AA" || xy == "DD"
	if file.Conflicted {
		file.Status = "conflicted"
	}
	return file
}

func statusName(value byte) string {
	switch value {
	case 'A', '?':
		return "added"
	case 'D':
		return "deleted"
	case 'R':
		return "renamed"
	case 'C':
		return "copied"
	case 'U':
		return "conflicted"
	default:
		return "modified"
	}
}

// revision finishes each file's revision with the working-tree metadata Git
// does not hash (an unstaged edit keeps its status line until the content is
// staged) and returns the whole tree's revision.
func revision(root string, raw []byte, files []model.ChangedFile) string {
	hash := sha256.New()
	_, _ = hash.Write(raw)
	for index := range files {
		file := &files[index]
		if file.Unstaged {
			file.Revision = worktreeRevision(root, *file)
		}
		_, _ = hash.Write([]byte{0})
		_, _ = hash.Write([]byte(file.Revision))
	}
	return hex.EncodeToString(hash.Sum(nil)[:16])
}

func worktreeRevision(root string, file model.ChangedFile) string {
	hash := sha256.New()
	_, _ = hash.Write([]byte(file.Revision))
	_, _ = hash.Write([]byte{0})
	full := filepath.Join(root, filepath.FromSlash(file.Path))
	info, err := os.Lstat(full)
	if err != nil {
		_, _ = hash.Write([]byte("missing"))
	} else {
		_, _ = fmt.Fprintf(hash, "%d:%d:%d", info.Mode(), info.Size(), info.ModTime().UnixNano())
		if info.Mode()&os.ModeSymlink != 0 {
			if target, readErr := os.Readlink(full); readErr == nil {
				_, _ = hash.Write([]byte(target))
			}
		}
	}
	return hex.EncodeToString(hash.Sum(nil)[:16])
}

func recordDigest(records ...string) string {
	hash := sha256.New()
	for _, record := range records {
		_, _ = hash.Write([]byte(record))
		_, _ = hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil)[:16])
}

// indexEntry adds one path's index side (X state, mode and object name) to
// the index fingerprint. Unchanged paths match HEAD, which the fingerprint
// also covers.
func indexEntry(hash io.Writer, state, mode, object, filePath, previousPath string) {
	_, _ = fmt.Fprintf(hash, "%s %s %s %s\x00%s\x00", state, mode, object, filePath, previousPath)
}

func zeroFields(raw []byte) []string {
	parts := strings.Split(string(raw), "\x00")
	result := parts[:0]
	for _, part := range parts {
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}
