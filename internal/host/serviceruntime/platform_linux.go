//go:build linux

package serviceruntime

import (
	"context"
	"debug/elf"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

func PlatformRuntime(root string) Runtime {
	return Runtime{Root: root, Executables: []string{"dieter", "dieter-capture"}, Verify: verifyLinuxExecutable}
}

func verifyLinuxExecutable(_ context.Context, dir string) error {
	want := elf.EM_X86_64
	if runtime.GOARCH == "arm64" {
		want = elf.EM_AARCH64
	}
	for _, name := range []string{"dieter", "dieter-capture"} {
		path := filepath.Join(dir, name)
		file, err := elf.Open(path)
		if err != nil {
			return fmt.Errorf("managed Linux %s is not an ELF executable", name)
		}
		if file.FileHeader.Machine != want {
			file.Close()
			return fmt.Errorf("managed Linux %s architecture does not match this machine", name)
		}
		file.Close()
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
			return fmt.Errorf("managed Linux %s must be a regular executable", name)
		}
	}
	return nil
}
