package git

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
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
		generation: map[string]uint64{},
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
	r.mu.Unlock()
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
	Revision   string
}

func ReadStatus(ctx context.Context, runner Runner, directory string) (StatusSnapshot, error) {
	result, err := runner.Run(ctx, directory, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
	if err != nil {
		return StatusSnapshot{}, err
	}
	if result.Truncated {
		return StatusSnapshot{}, ErrTooManyChanges
	}
	value, err := ParseStatus(result.Output)
	if err != nil {
		return StatusSnapshot{}, err
	}
	value.Revision = revision(directory, result.Output, value.Files)
	return value, nil
}

func ParseStatus(raw []byte) (StatusSnapshot, error) {
	var value StatusSnapshot
	records := zeroFields(raw)
	for index := 0; index < len(records); index++ {
		record := records[index]
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
			if len(fields) != 9 {
				return StatusSnapshot{}, fault.Invalidf("invalid ordinary porcelain-v2 record")
			}
			value.Files = append(value.Files, changedFile(fields[1], fields[2], fields[8], ""))
		case strings.HasPrefix(record, "2 "):
			fields := strings.SplitN(record, " ", 10)
			if len(fields) != 10 || index+1 >= len(records) {
				return StatusSnapshot{}, fault.Invalidf("invalid renamed porcelain-v2 record")
			}
			index++
			file := changedFile(fields[1], fields[2], fields[9], records[index])
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
				return StatusSnapshot{}, fault.Invalidf("invalid unmerged porcelain-v2 record")
			}
			file := changedFile(fields[1], fields[2], fields[10], "")
			file.Conflicted, file.Status = true, "conflicted"
			value.Files = append(value.Files, file)
		case strings.HasPrefix(record, "? "):
			filePath := strings.TrimPrefix(record, "? ")
			value.Files = append(value.Files, model.ChangedFile{
				Path: filePath, Status: "untracked", WorktreeStatus: "untracked", Unstaged: true,
			})
		case strings.HasPrefix(record, "! "):
			// Ignored files are not requested, but tolerate them if Git emits one.
		default:
			return StatusSnapshot{}, fault.Invalidf("unknown porcelain-v2 record %q", record)
		}
	}
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

func revision(root string, raw []byte, files []model.ChangedFile) string {
	hash := sha256.New()
	_, _ = hash.Write(raw)
	for _, file := range files {
		if !file.Unstaged {
			continue
		}
		_, _ = hash.Write([]byte{0})
		_, _ = hash.Write([]byte(file.Path))
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(file.Path)))
		if err != nil {
			_, _ = hash.Write([]byte("missing"))
			continue
		}
		_, _ = fmt.Fprintf(hash, "%d:%d:%d", info.Mode(), info.Size(), info.ModTime().UnixNano())
		if info.Mode()&os.ModeSymlink != 0 {
			if target, readErr := os.Readlink(filepath.Join(root, filepath.FromSlash(file.Path))); readErr == nil {
				_, _ = hash.Write([]byte(target))
			}
		}
	}
	return hex.EncodeToString(hash.Sum(nil)[:16])
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
