//go:build linux

package serviceruntime

import (
	"context"
	"debug/elf"
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

func PlatformRuntime(root string) Runtime {
	return Runtime{Root: root, Executables: []string{"dieter"}, Verify: verifyLinuxExecutable}
}

func verifyLinuxExecutable(_ context.Context, dir string) error {
	path := filepath.Join(dir, "dieter")
	file, err := elf.Open(path)
	if err != nil {
		return errors.New("managed Linux runtime is not an ELF executable")
	}
	defer file.Close()
	want := elf.EM_X86_64
	if runtime.GOARCH == "arm64" {
		want = elf.EM_AARCH64
	}
	if file.FileHeader.Machine != want {
		return errors.New("managed Linux runtime architecture does not match this machine")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return errors.New("managed Linux runtime must be a regular executable")
	}
	return nil
}
