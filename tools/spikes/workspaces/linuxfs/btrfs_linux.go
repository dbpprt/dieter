//go:build linux

package linuxfs

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// BtrfsPath is the btrfs-progs binary.
var BtrfsPath = "btrfs"

const btrfsSuperMagic = 0x9123683e

// IsSubvolume reports whether path is the root of a btrfs subvolume (inode
// 256 on btrfs).
func IsSubvolume(path string) bool {
	var sfs unix.Statfs_t
	if err := unix.Statfs(path, &sfs); err != nil || uint32(sfs.Type) != btrfsSuperMagic {
		return false
	}
	var st unix.Stat_t
	return unix.Lstat(path, &st) == nil && st.Mode&unix.S_IFMT == unix.S_IFDIR && st.Ino == 256
}

// SubvolumeCreate creates an empty subvolume (unprivileged on btrfs).
func SubvolumeCreate(path string) error {
	_, err := runBtrfs("subvolume", "create", path)
	return err
}

// Snapshot snapshots the subvolume src at dst, read-only when asked.
func Snapshot(src, dst string, readonly bool) (time.Duration, error) {
	args := []string{"subvolume", "snapshot"}
	if readonly {
		args = append(args, "-r")
	}
	start := time.Now()
	_, err := runBtrfs(append(args, src, dst)...)
	return time.Since(start), err
}

// DeleteSubvolume deletes a subvolume. Unprivileged deletion through
// "btrfs subvolume delete" needs user_subvol_rm_allowed; without it the
// subvolume is made writable (if read-only), emptied and removed with
// rmdir, which the owner may do on an empty subvolume.
func DeleteSubvolume(path string) error {
	_, first := runBtrfs("subvolume", "delete", path)
	if first == nil {
		return nil
	}
	if out, err := runBtrfs("property", "get", "-ts", path, "ro"); err == nil && strings.Contains(out, "ro=true") {
		if _, err := runBtrfs("property", "set", "-ts", path, "ro", "false"); err != nil {
			return fmt.Errorf("%w (after %v)", err, first)
		}
	}
	ents, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	for _, e := range ents {
		p := filepath.Join(path, e.Name())
		if e.IsDir() && IsSubvolume(p) {
			err = DeleteSubvolume(p)
		} else {
			err = RemoveAll(p)
		}
		if err != nil {
			return err
		}
	}
	if err := unix.Rmdir(path); err != nil {
		return fmt.Errorf("rmdir %s: %w (after %v)", path, err, first)
	}
	return nil
}

func runBtrfs(args ...string) (string, error) {
	cmd := exec.Command(BtrfsPath, args...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("btrfs %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(out.String()))
	}
	return out.String(), nil
}
