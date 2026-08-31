//go:build windows

package app

// Windows is not a supported daemon target today. Keep admission available to
// cross-compilation without rejecting every turn until a native disk probe is
// added for that platform.
func availableDiskBytes(string) (uint64, error) {
	return ^uint64(0), nil
}
