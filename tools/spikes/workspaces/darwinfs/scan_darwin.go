//go:build darwin

package darwinfs

/*
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>

static const uint32_t dfs_cmn = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE |
	ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_ACCESSMASK | ATTR_CMN_FILEID | ATTR_CMN_ERROR;
static const uint32_t dfs_file = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;

static int dfs_bulk(int fd, void *buf, size_t size, uint32_t ext) {
	struct attrlist al = {0};
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.commonattr = dfs_cmn;
	al.fileattr = dfs_file;
	al.forkattr = ext;
	return getattrlistbulk(fd, &al, buf, size, ext ? FSOPT_ATTR_CMN_EXTENDED : 0);
}

static int dfs_gencount(const char *path, uint32_t *out) {
	struct attrlist al = {0};
	struct { uint32_t len; attribute_set_t ret; uint32_t gen; } __attribute__((packed)) buf = {0};
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_GEN_COUNT;
	int r = getattrlist(path, &al, &buf, sizeof(buf), FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW);
	if (r == 0) *out = (buf.ret.commonattr & ATTR_CMN_GEN_COUNT) ? buf.gen : 0;
	return r;
}
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"sync"
	"time"
	"unsafe"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// Attribute bits mirrored from <sys/attr.h> for parsing.
const (
	attrCmnName        = 0x00000001
	attrCmnObjType     = 0x00000008
	attrCmnModTime     = 0x00000400
	attrCmnChgTime     = 0x00000800
	attrCmnAccessMask  = 0x00020000
	attrCmnFileID      = 0x02000000
	attrCmnError       = 0x20000000
	attrFileLinkCount  = 0x00000001
	attrFileAllocSize  = 0x00000004
	attrFileDataLength = 0x00000200
	attrExtPrivateSize = 0x00000008
	attrExtCloneID     = 0x00000100
	attrExtExtFlags    = 0x00000200

	efSharesAllBlocks = 0x00000040

	vREG = 1
	vDIR = 2
	vLNK = 5

	bulkBufSize = 256 << 10
)

// scanExtAttrs is the ATTR_CMNEXT_* set ScanClone requests; experiments
// narrow it to price individual attributes.
var scanExtAttrs uint32 = attrExtPrivateSize | attrExtCloneID | attrExtExtFlags

// ScanClone walks root with getattrlistbulk(2), reading directories in
// parallel on opt.Workers goroutines. The root itself is not reported.
// Subdirectories that vanish during the walk are skipped; any other error
// stops the walk and is returned with the entries collected so far.
func ScanClone(root string, opt ScanOptions) (map[string]CEntry, ScanStats, error) {
	start := time.Now()
	workers := opt.Workers
	if workers <= 0 {
		workers = 1
	}
	root = strings.TrimSuffix(root, "/")
	if root == "" {
		root = "/"
	}
	ext := scanExtAttrs
	if opt.SkipBlockStats {
		ext &^= attrExtPrivateSize | attrExtExtFlags
	}
	s := &scanner{root: root, opt: opt, ext: ext, stack: []string{""}, pending: 1}
	s.cond = sync.NewCond(&s.mu)
	results := make([][]CEntry, workers)
	stats := make([]ScanStats, workers)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i], stats[i] = s.work()
		}(i)
	}
	wg.Wait()
	var st ScanStats
	n := 0
	for i := range results {
		n += len(results[i])
		st.Dirs += stats[i].Dirs
		st.Calls += stats[i].Calls
	}
	out := make(map[string]CEntry, n)
	for _, rs := range results {
		for _, e := range rs {
			out[e.Path] = e
		}
	}
	st.Entries = len(out)
	st.Duration = time.Since(start)
	return out, st, s.err
}

type scanner struct {
	root    string
	opt     ScanOptions
	ext     uint32
	mu      sync.Mutex
	cond    *sync.Cond
	stack   []string // raw (not normalised) relative directory paths
	pending int      // directories queued or being read
	err     error
}

func (s *scanner) work() ([]CEntry, ScanStats) {
	buf := make([]byte, bulkBufSize)
	var out []CEntry
	var st ScanStats
	for {
		s.mu.Lock()
		for len(s.stack) == 0 && s.pending > 0 && s.err == nil {
			s.cond.Wait()
		}
		if s.err != nil || s.pending == 0 {
			s.mu.Unlock()
			return out, st
		}
		dir := s.stack[len(s.stack)-1]
		s.stack = s.stack[:len(s.stack)-1]
		s.mu.Unlock()

		var subdirs []string
		var err error
		out, subdirs, err = s.readDir(dir, buf, out, &st)

		s.mu.Lock()
		if err != nil && s.err == nil {
			s.err = err
		}
		s.stack = append(s.stack, subdirs...)
		s.pending += len(subdirs) - 1
		s.mu.Unlock()
		s.cond.Broadcast()
	}
}

func (s *scanner) readDir(rel string, buf []byte, out []CEntry, st *ScanStats) ([]CEntry, []string, error) {
	abs := s.root
	flags := unix.O_RDONLY | unix.O_DIRECTORY | unix.O_CLOEXEC
	if rel != "" {
		abs = s.root + "/" + rel
		flags |= unix.O_NOFOLLOW
	}
	fd, err := unix.Open(abs, flags, 0)
	if err != nil {
		if rel != "" && (errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENOTDIR) || errors.Is(err, unix.ELOOP)) {
			return out, nil, nil // raced with a delete or a replace; skip
		}
		return out, nil, &fs.PathError{Op: "open", Path: abs, Err: err}
	}
	defer unix.Close(fd)
	st.Dirs++
	var subdirs []string
	for {
		n, err := C.dfs_bulk(C.int(fd), unsafe.Pointer(&buf[0]), C.size_t(len(buf)), C.uint32_t(s.ext))
		st.Calls++
		if n < 0 {
			if errors.Is(err, unix.EINTR) {
				continue
			}
			return out, subdirs, &fs.PathError{Op: "getattrlistbulk", Path: abs, Err: err}
		}
		if n == 0 {
			return out, subdirs, nil
		}
		off := 0
		for i := 0; i < int(n); i++ {
			if off+4 > len(buf) {
				return out, subdirs, fmt.Errorf("getattrlistbulk %s: truncated buffer", abs)
			}
			length := int(binary.LittleEndian.Uint32(buf[off:]))
			if length <= 0 || off+length > len(buf) {
				return out, subdirs, fmt.Errorf("getattrlistbulk %s: bad entry length %d", abs, length)
			}
			e, name, errno, perr := parseEntry(buf[off : off+length])
			off += length
			if perr != nil {
				return out, subdirs, fmt.Errorf("getattrlistbulk %s: %w", abs, perr)
			}
			if errno != 0 {
				continue // per-entry error (e.g. vanished); the entry is unusable
			}
			childRel := name
			if rel != "" {
				childRel = rel + "/" + name
			}
			if rel == "" && s.opt.SkipGit && name == ".git" {
				continue
			}
			e.Path = core.NormPath(childRel)
			out = append(out, e)
			if e.Type == core.Dir {
				subdirs = append(subdirs, childRel)
			}
		}
	}
}

// parseEntry decodes one getattrlistbulk record laid out as: length,
// returned attribute_set_t, common attributes in bit order, file attributes,
// then the extended common (forkattr) attributes.
func parseEntry(b []byte) (CEntry, string, uint32, error) {
	var e CEntry
	le := binary.LittleEndian
	if len(b) < 24 {
		return e, "", 0, errors.New("short entry")
	}
	cmn := le.Uint32(b[4:])
	file := le.Uint32(b[16:])
	ext := le.Uint32(b[20:])
	p := 24
	need := func(n int) bool { return p+n <= len(b) }
	var name string
	var errno uint32
	if cmn&attrCmnName != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short name")
		}
		doff := int(int32(le.Uint32(b[p:])))
		dlen := int(le.Uint32(b[p+4:]))
		start := p + doff
		if start < 0 || start+dlen > len(b) || dlen == 0 {
			return e, "", 0, errors.New("bad name reference")
		}
		name = string(b[start : start+dlen-1]) // drop the NUL
		p += 8
	}
	if cmn&attrCmnObjType != 0 {
		if !need(4) {
			return e, "", 0, errors.New("short objtype")
		}
		switch le.Uint32(b[p:]) {
		case vREG:
			e.Type = core.File
		case vDIR:
			e.Type = core.Dir
		case vLNK:
			e.Type = core.Symlink
		default:
			e.Type = core.Other
		}
		p += 4
	}
	if cmn&attrCmnModTime != 0 {
		if !need(16) {
			return e, "", 0, errors.New("short modtime")
		}
		e.MtimeNs = int64(le.Uint64(b[p:]))*1e9 + int64(le.Uint64(b[p+8:]))
		p += 16
	}
	if cmn&attrCmnChgTime != 0 {
		if !need(16) {
			return e, "", 0, errors.New("short chgtime")
		}
		e.CtimeNs = int64(le.Uint64(b[p:]))*1e9 + int64(le.Uint64(b[p+8:]))
		p += 16
	}
	if cmn&attrCmnAccessMask != 0 {
		if !need(4) {
			return e, "", 0, errors.New("short accessmask")
		}
		e.Mode = le.Uint32(b[p:]) & 0o7777
		p += 4
	}
	if cmn&attrCmnFileID != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short fileid")
		}
		e.Ino = le.Uint64(b[p:])
		p += 8
	}
	if cmn&attrCmnError != 0 {
		if !need(4) {
			return e, "", 0, errors.New("short error")
		}
		errno = le.Uint32(b[p:])
		p += 4
	}
	if file&attrFileLinkCount != 0 {
		if !need(4) {
			return e, "", 0, errors.New("short linkcount")
		}
		e.LinkCount = le.Uint32(b[p:])
		p += 4
	}
	if file&attrFileAllocSize != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short allocsize")
		}
		e.AllocSize = int64(le.Uint64(b[p:]))
		p += 8
	}
	if file&attrFileDataLength != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short datalength")
		}
		e.Size = int64(le.Uint64(b[p:]))
		p += 8
	}
	if ext&attrExtPrivateSize != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short privatesize")
		}
		e.PrivateSize = int64(le.Uint64(b[p:]))
		p += 8
	}
	if ext&attrExtCloneID != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short cloneid")
		}
		e.CloneID = le.Uint64(b[p:])
		p += 8
	}
	if ext&attrExtExtFlags != 0 {
		if !need(8) {
			return e, "", 0, errors.New("short extflags")
		}
		e.SharesAllBlocks = le.Uint64(b[p:])&efSharesAllBlocks != 0
		p += 8
	}
	return e, name, errno, nil
}

// genCount returns ATTR_CMN_GEN_COUNT for one path (0 when unsupported). It is
// used by the clone-id experiments as a per-write change counter to compare
// against clone ids.
func genCount(path string) (uint32, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var gc C.uint32_t
	if r, err := C.dfs_gencount(cpath, &gc); r != 0 {
		return 0, &fs.PathError{Op: "getattrlist", Path: path, Err: err}
	}
	return uint32(gc), nil
}
