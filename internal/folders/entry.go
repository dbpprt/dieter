package folders

import (
	"encoding/hex"
	"path"
	"strings"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"golang.org/x/text/unicode/norm"
)

// Bounds of entries and folders.
const (
	MaxPathBytes      = 4096
	MaxComponentBytes = 255
	MaxFileSize       = int64(64) << 30
	MaxNameBytes      = 64
	// MaxEntries bounds a folder on a daemon (filetransfer.MaxEntries).
	MaxEntries = 100000
	// MaxPhoneEntries bounds a folder on a phone.
	MaxPhoneEntries = 25000
	// BlockSize is the transfer chunk and block hash size.
	BlockSize = 1 << 20
	// BlockThreshold is the size above which members keep block hashes.
	BlockThreshold = 8 << 20
	// TemporaryPrefix marks payload-only partial files beside a destination.
	TemporaryPrefix = ".dieter-transfer-"
)

// Kind is an entry's kind.
type Kind string

const (
	KindFile      Kind = "file"
	KindDirectory Kind = "directory"
	KindDeleted   Kind = "deleted"
)

// Mode is a member's direction.
type Mode string

const (
	ModeTwoWay      Mode = "two-way"
	ModeSendOnly    Mode = "send-only"
	ModeReceiveOnly Mode = "receive-only"
)

// ValidMode reports whether m is a known mode.
func ValidMode(m Mode) bool { return m == ModeTwoWay || m == ModeSendOnly || m == ModeReceiveOnly }

// Entry is one entry of a member's index as members exchange it.
type Entry struct {
	Path       string  `json:"path"`
	Kind       Kind    `json:"kind"`
	Size       int64   `json:"size,omitempty"`
	Modified   int64   `json:"modified,omitempty"`
	Executable bool    `json:"executable,omitempty"`
	SHA256     string  `json:"sha256,omitempty"`
	Version    Version `json:"version"`
	Sequence   uint64  `json:"sequence,omitempty"`
	AuthorID   string  `json:"authorId,omitempty"`
	AuthorName string  `json:"authorName,omitempty"`
}

// Protected reports whether a path component is never synced: Git metadata
// and transfer partials.
func Protected(component string) bool {
	return component == ".git" || strings.HasPrefix(component, TemporaryPrefix)
}

// ValidatePath checks that p is a relative, clean, NFC path within bounds
// that names no protected component.
func ValidatePath(p string) error {
	if p == "" || p == "." || len(p) > MaxPathBytes || !utf8.ValidString(p) || strings.ContainsAny(p, "\\\x00") || strings.HasPrefix(p, "/") {
		return fault.Invalidf("invalid folder path")
	}
	if path.Clean(p) != p || p == ".." || strings.HasPrefix(p, "../") {
		return fault.Invalidf("folder path must be clean and relative")
	}
	if !norm.NFC.IsNormalString(p) {
		return fault.Invalidf("folder path must be NFC")
	}
	for _, part := range strings.Split(p, "/") {
		if part == "" || part == "." || part == ".." || len(part) > MaxComponentBytes {
			return fault.Invalidf("invalid folder path component")
		}
		for _, r := range part {
			if r < 0x20 || r == 0x7f {
				return fault.Invalidf("folder path contains a control character")
			}
		}
		if Protected(part) {
			return fault.New(fault.PermissionDenied, "protected folder path")
		}
	}
	return nil
}

// NormalizePath is p in NFC: how a member names a path it found on disk.
func NormalizePath(p string) string { return norm.NFC.String(p) }

func validDigest(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 32 && s == strings.ToLower(s)
}

// Validate checks an entry received from another member.
func (e Entry) Validate() error {
	if err := ValidatePath(e.Path); err != nil {
		return err
	}
	if err := e.Version.Validate(); err != nil {
		return err
	}
	if len(e.Version) == 0 {
		return fault.Invalidf("an entry needs a version")
	}
	if len(e.AuthorID) > 128 || len(e.AuthorName) > MaxNameBytes || !utf8.ValidString(e.AuthorName) {
		return fault.Invalidf("invalid entry author")
	}
	switch e.Kind {
	case KindFile:
		if e.Size < 0 || e.Size > MaxFileSize || !validDigest(e.SHA256) {
			return fault.Invalidf("a file entry needs a size and SHA-256")
		}
	case KindDirectory, KindDeleted:
		if e.Size != 0 || e.SHA256 != "" || e.Executable {
			return fault.Invalidf("only files have content")
		}
	default:
		return fault.Invalidf("invalid entry kind")
	}
	return nil
}

// SameContent reports whether a and b describe the same content: equal kind
// and, for files, equal size, SHA-256 and executable bit.
func SameContent(a, b Entry) bool {
	if a.Kind != b.Kind {
		return false
	}
	return a.Kind != KindFile || a.Size == b.Size && a.SHA256 == b.SHA256 && a.Executable == b.Executable
}

// Wins reports whether a beats b when their versions are concurrent and
// their contents differ: the later modification, then the higher author ID,
// then the higher SHA-256. Every member computes the same result.
func Wins(a, b Entry) bool {
	if a.Modified != b.Modified {
		return a.Modified > b.Modified
	}
	if a.AuthorID != b.AuthorID {
		return a.AuthorID > b.AuthorID
	}
	return a.SHA256 > b.SHA256
}

// Depth is the number of components of p.
func Depth(p string) int { return strings.Count(p, "/") + 1 }
