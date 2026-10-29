//go:build !darwin

package darwinfs

import (
	"errors"
	"time"
)

// ErrCrossVolume mirrors the darwin error value.
var ErrCrossVolume = errors.New("source and destination are on different volumes; APFS clones need one volume")

// ErrTimeout mirrors the darwin error value.
var ErrTimeout = errors.New("fsevents: timed out before history replay finished")

func CloneTree(src, dst string) (time.Duration, error)    { return 0, errors.ErrUnsupported }
func ClonePerFile(src, dst string) (time.Duration, error) { return 0, errors.ErrUnsupported }
func CloneFile(src, dst string) error                     { return errors.ErrUnsupported }
func VolumeOf(path string) (uint64, string, error)        { return 0, "", errors.ErrUnsupported }
func CurrentEventID() uint64                              { return 0 }

func ScanClone(root string, opt ScanOptions) (map[string]CEntry, ScanStats, error) {
	return nil, ScanStats{}, errors.ErrUnsupported
}

func EventsSince(paths []string, since uint64, timeout time.Duration) ([]FSEvent, error) {
	return nil, errors.ErrUnsupported
}
