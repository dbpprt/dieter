//go:build !linux

package linuxfs

import (
	"errors"
	"time"

	"dieter.spike/workspaces/core"
)

func (o Overlay) Prepare() error { return errors.ErrUnsupported }

func (o Overlay) ReadUpper() (map[string]UpperEntry, UpperStats, error) {
	return nil, UpperStats{}, errors.ErrUnsupported
}

func (o Overlay) Changes(core.Tree) (core.ChangeSet, CopyUpStats, error) {
	return nil, CopyUpStats{}, errors.ErrUnsupported
}

func ScanTree(string) (core.Tree, error) { return nil, errors.ErrUnsupported }

func ReflinkTree(string, string) (time.Duration, int, error) {
	return 0, 0, errors.ErrUnsupported
}

func IsSubvolume(string) bool { return false }

func SubvolumeCreate(string) error { return errors.ErrUnsupported }

func Snapshot(string, string, bool) (time.Duration, error) { return 0, errors.ErrUnsupported }

func DeleteSubvolume(string) error { return errors.ErrUnsupported }
