// Package darwinfs evaluates APFS copy-on-write clones as per-session
// workspaces on macOS: whole-tree clonefile(2), a getattrlistbulk(2) scanner
// that reports per-file clone ids, and FSEvents history replay. Every exported
// function returns errors.ErrUnsupported on other platforms.
package darwinfs

import (
	"time"

	"dieter.spike/workspaces/core"
)

// CEntry is one entry reported by ScanClone.
type CEntry struct {
	Path            string         // NFC, slash-separated, relative to the scan root
	Type            core.EntryType // file, dir, symlink or other
	Mode            uint32         // permission bits (0o7777)
	Size            int64          // ATTR_FILE_DATALENGTH (0 for directories)
	AllocSize       int64          // ATTR_FILE_ALLOCSIZE (0 for directories)
	MtimeNs         int64          // ATTR_CMN_MODTIME
	CtimeNs         int64          // ATTR_CMN_CHGTIME
	Ino             uint64         // ATTR_CMN_FILEID
	CloneID         uint64         // ATTR_CMNEXT_CLONEID (0 when unsupported)
	PrivateSize     int64          // ATTR_CMNEXT_PRIVATESIZE: bytes not shared with any clone
	SharesAllBlocks bool           // EF_SHARES_ALL_BLOCKS from ATTR_CMNEXT_EXT_FLAGS
	LinkCount       uint32         // ATTR_FILE_LINKCOUNT (0 for directories)
}

// ScanOptions tunes ScanClone.
type ScanOptions struct {
	Workers int  // directories read in parallel; <= 0 means 1
	SkipGit bool // skip the ".git" entry at the root and everything below it
	// SkipBlockStats omits PrivateSize and SharesAllBlocks, which make APFS
	// walk each file's extents (about 3x the cost of the rest of the scan).
	// CloneID is still reported.
	SkipBlockStats bool
}

// ScanStats summarises one ScanClone call.
type ScanStats struct {
	Entries  int           // entries returned (directories included)
	Dirs     int           // directories read, the root included
	Calls    int           // getattrlistbulk(2) calls
	Duration time.Duration // wall time of the scan
}

// FSEvent is one FSEvents record. Path is absolute and resolved the way
// FSEvents reports it.
type FSEvent struct {
	Path  string
	Flags uint32
	ID    uint64
}

// FSEvents flag bits (kFSEventStreamEventFlag*).
const (
	FlagMustScanSubDirs  uint32 = 0x00000001
	FlagUserDropped      uint32 = 0x00000002
	FlagKernelDropped    uint32 = 0x00000004
	FlagEventIDsWrapped  uint32 = 0x00000008
	FlagHistoryDone      uint32 = 0x00000010
	FlagRootChanged      uint32 = 0x00000020
	FlagMount            uint32 = 0x00000040
	FlagUnmount          uint32 = 0x00000080
	FlagItemCreated      uint32 = 0x00000100
	FlagItemRemoved      uint32 = 0x00000200
	FlagItemInodeMetaMod uint32 = 0x00000400
	FlagItemRenamed      uint32 = 0x00000800
	FlagItemModified     uint32 = 0x00001000
	FlagItemFinderInfo   uint32 = 0x00002000
	FlagItemChangeOwner  uint32 = 0x00004000
	FlagItemXattrMod     uint32 = 0x00008000
	FlagItemIsFile       uint32 = 0x00010000
	FlagItemIsDir        uint32 = 0x00020000
	FlagItemIsSymlink    uint32 = 0x00040000
	FlagOwnEvent         uint32 = 0x00080000
	FlagItemIsHardlink   uint32 = 0x00100000
	FlagItemIsLastHard   uint32 = 0x00200000
	FlagItemCloned       uint32 = 0x00400000
)

func (e FSEvent) has(f uint32) bool { return e.Flags&f != 0 }

func (e FSEvent) Created() bool         { return e.has(FlagItemCreated) }
func (e FSEvent) Removed() bool         { return e.has(FlagItemRemoved) }
func (e FSEvent) Renamed() bool         { return e.has(FlagItemRenamed) }
func (e FSEvent) Modified() bool        { return e.has(FlagItemModified) }
func (e FSEvent) InodeMetaMod() bool    { return e.has(FlagItemInodeMetaMod) }
func (e FSEvent) XattrMod() bool        { return e.has(FlagItemXattrMod) }
func (e FSEvent) Cloned() bool          { return e.has(FlagItemCloned) }
func (e FSEvent) ItemIsFile() bool      { return e.has(FlagItemIsFile) }
func (e FSEvent) ItemIsDir() bool       { return e.has(FlagItemIsDir) }
func (e FSEvent) ItemIsSymlink() bool   { return e.has(FlagItemIsSymlink) }
func (e FSEvent) MustScanSubDirs() bool { return e.has(FlagMustScanSubDirs) }
func (e FSEvent) UserDropped() bool     { return e.has(FlagUserDropped) }
func (e FSEvent) KernelDropped() bool   { return e.has(FlagKernelDropped) }
func (e FSEvent) HistoryDone() bool     { return e.has(FlagHistoryDone) }

// Lossy reports whether the event tells the consumer that it must rescan
// (coalesced subtree or dropped events).
func (e FSEvent) Lossy() bool {
	return e.has(FlagMustScanSubDirs | FlagUserDropped | FlagKernelDropped | FlagEventIDsWrapped | FlagRootChanged)
}

// FlagString renders the set flags for logs, e.g. "Created|Modified|IsFile".
func FlagString(f uint32) string {
	names := []struct {
		bit  uint32
		name string
	}{
		{FlagMustScanSubDirs, "MustScanSubDirs"}, {FlagUserDropped, "UserDropped"},
		{FlagKernelDropped, "KernelDropped"}, {FlagEventIDsWrapped, "IdsWrapped"},
		{FlagHistoryDone, "HistoryDone"}, {FlagRootChanged, "RootChanged"},
		{FlagMount, "Mount"}, {FlagUnmount, "Unmount"},
		{FlagItemCreated, "Created"}, {FlagItemRemoved, "Removed"},
		{FlagItemInodeMetaMod, "InodeMetaMod"}, {FlagItemRenamed, "Renamed"},
		{FlagItemModified, "Modified"}, {FlagItemFinderInfo, "FinderInfoMod"},
		{FlagItemChangeOwner, "ChangeOwner"}, {FlagItemXattrMod, "XattrMod"},
		{FlagItemIsFile, "IsFile"}, {FlagItemIsDir, "IsDir"},
		{FlagItemIsSymlink, "IsSymlink"}, {FlagOwnEvent, "OwnEvent"},
		{FlagItemIsHardlink, "IsHardlink"}, {FlagItemIsLastHard, "IsLastHardlink"},
		{FlagItemCloned, "Cloned"},
	}
	out := ""
	for _, n := range names {
		if f&n.bit != 0 {
			if out != "" {
				out += "|"
			}
			out += n.name
		}
	}
	return out
}
