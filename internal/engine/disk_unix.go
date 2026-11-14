//go:build unix

package engine

import "syscall"

func availableDiskBytes(path string) (uint64, error) {
	var value syscall.Statfs_t
	if err := syscall.Statfs(path, &value); err != nil {
		return 0, err
	}
	return value.Bavail * uint64(value.Bsize), nil
}
