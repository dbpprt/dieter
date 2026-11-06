//go:build darwin

package darwinfs

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// ErrCrossVolume is wrapped by the clone functions when source and
// destination are on different volumes (EXDEV).
var ErrCrossVolume = errors.New("source and destination are on different volumes; APFS clones need one volume")

const cloneFlags = unix.CLONE_NOFOLLOW | unix.CLONE_NOOWNERCOPY

// CloneTree clones the directory src to dst with a single clonefile(2) call.
// dst must not exist; its parent must exist on the same APFS volume.
func CloneTree(src, dst string) (time.Duration, error) {
	src = strings.TrimSuffix(src, "/")
	dst = strings.TrimSuffix(dst, "/")
	st, err := os.Lstat(src)
	if err != nil {
		return 0, err
	}
	if !st.IsDir() {
		return 0, fmt.Errorf("clone tree %s: not a directory", src)
	}
	if _, err := os.Lstat(dst); err == nil {
		return 0, fmt.Errorf("clone tree %s -> %s: %w", src, dst, fs.ErrExist)
	}
	start := time.Now()
	err = unix.Clonefile(src, dst, cloneFlags)
	elapsed := time.Since(start)
	if err != nil {
		return elapsed, cloneErr("clone tree", src, dst, err)
	}
	return elapsed, nil
}

// ClonePerFile clones src to dst with /bin/cp -c -R, which walks the tree and
// clones each file individually. It is not atomic with respect to concurrent
// writes in src. cp -c silently falls back to a full copy across volumes, so
// the volumes are compared first and a mismatch fails with ErrCrossVolume.
func ClonePerFile(src, dst string) (time.Duration, error) {
	src = strings.TrimSuffix(src, "/")
	dst = strings.TrimSuffix(dst, "/")
	if _, err := os.Lstat(dst); err == nil {
		return 0, fmt.Errorf("clone per file %s -> %s: %w", src, dst, fs.ErrExist)
	}
	srcDev, _, err := VolumeOf(src)
	if err != nil {
		return 0, err
	}
	dstDev, _, err := VolumeOf(filepath.Dir(dst))
	if err != nil {
		return 0, err
	}
	if srcDev != dstDev {
		return 0, cloneErr("clone per file", src, dst, unix.EXDEV)
	}
	cmd := exec.Command("/bin/cp", "-c", "-R", src, dst)
	cmd.Env = childEnv()
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	start := time.Now()
	err = cmd.Run()
	elapsed := time.Since(start)
	if err != nil {
		return elapsed, fmt.Errorf("cp -c -R %s %s: %w: %s", src, dst, err, strings.TrimSpace(out.String()))
	}
	return elapsed, nil
}

// CloneFile clones a single regular file or symlink (not followed).
func CloneFile(src, dst string) error {
	st, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if st.IsDir() {
		return fmt.Errorf("clone file %s: is a directory (use CloneTree)", src)
	}
	if err := unix.Clonefile(src, dst, cloneFlags); err != nil {
		return cloneErr("clone file", src, dst, err)
	}
	return nil
}

func cloneErr(op, src, dst string, err error) error {
	switch {
	case errors.Is(err, unix.EXDEV):
		return fmt.Errorf("%s %s -> %s: %w (%w)", op, src, dst, ErrCrossVolume, err)
	case errors.Is(err, unix.ENOTSUP):
		return fmt.Errorf("%s %s -> %s: filesystem does not support clones (%w)", op, src, dst, err)
	}
	return &fs.PathError{Op: op, Path: src + " -> " + dst, Err: err}
}

// VolumeOf returns the device id and mount point of the volume holding path.
func VolumeOf(path string) (uint64, string, error) {
	var st unix.Stat_t
	if err := unix.Stat(path, &st); err != nil {
		return 0, "", &fs.PathError{Op: "stat", Path: path, Err: err}
	}
	var sfs unix.Statfs_t
	if err := unix.Statfs(path, &sfs); err != nil {
		return 0, "", &fs.PathError{Op: "statfs", Path: path, Err: err}
	}
	return uint64(uint32(st.Dev)), unix.ByteSliceToString(sfs.Mntonname[:]), nil
}

// childEnv strips Dieter session variables from the environment of child
// processes.
func childEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		switch strings.SplitN(kv, "=", 2)[0] {
		case "DIETER_TURN_TOKEN", "DIETER_HOME", "DIETER_CARD_ID":
			continue
		}
		env = append(env, kv)
	}
	return env
}
