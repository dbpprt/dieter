// Package serviceruntime maintains real, signed executables at stable paths.
// Installation state belongs to the Homebrew runtime, never to a project or
// the user's Dieter database. Staging and activation share one installation
// lock; a separate lifetime lock excludes a second service during activation.
package serviceruntime

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const TeamID = "DS6N5L85E7"
const activationEnv = "DIETER_SERVICE_ACTIVATION"
const lockEnv = "DIETER_SERVICE_LOCK_FD"

var executables = []string{"dieter", "dieter-capture"}

type Runtime struct {
	Root string
	// Executables defaults to the signed daemon/helper pair. Platform runtimes
	// may supply an explicit list when their verification policy differs.
	Executables []string
	// Verify is injectable for isolated filesystem tests. Production always
	// uses Developer ID verification; there is no unsigned-install CLI flag.
	Verify func(context.Context, string) error
}

func (r Runtime) executableNames() []string {
	if len(r.Executables) == 0 {
		return executables
	}
	return r.Executables
}

type activation struct {
	Token  string `json:"token"`
	Before string `json:"before"`
	After  string `json:"after"`
}

// HomebrewRoot is independent of the formula's versioned opt/Cellar prefix.
func HomebrewRoot(prefix string) string {
	return filepath.Join(prefix, "var", "dieter", "service")
}

func (r Runtime) path(name string) string { return filepath.Join(r.Root, name) }

func (r Runtime) verify(ctx context.Context, dir string) error {
	if err := realDir(dir); err != nil {
		return err
	}
	verify := r.Verify
	if verify == nil {
		verify = VerifySignedPair
	}
	for _, name := range r.executableNames() {
		info, err := os.Lstat(filepath.Join(dir, name))
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
			return fmt.Errorf("%s must be a regular executable", name)
		}
	}
	return verify(ctx, dir)
}

func VerifySignedPair(ctx context.Context, dir string) error {
	for _, name := range executables {
		identifier := "com.dbpprt.dieter.daemon"
		if name == "dieter-capture" {
			identifier = "com.dbpprt.dieter.capture"
		}
		requirement := fmt.Sprintf(`identifier %q and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = %q`, identifier, TeamID)
		checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		output, err := exec.CommandContext(checkCtx, "/usr/bin/codesign", "--verify", "--strict", "-R", "="+requirement, filepath.Join(dir, name)).CombinedOutput()
		cancel()
		if err != nil {
			return fmt.Errorf("verify signed %s: %w: %s", name, err, strings.TrimSpace(string(output)))
		}
	}
	return nil
}

// Stage never modifies an existing bin directory, including while the service
// is stopped. The next service start is the only activation point.
func (r Runtime) Stage(ctx context.Context, source string) error {
	if err := r.prepare(); err != nil {
		return err
	}
	lock, err := r.installLock(ctx)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := r.collectInterruptedTemps(); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(r.Root, ".stage-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	for _, name := range r.executableNames() {
		if err := copyExecutable(filepath.Join(source, name), filepath.Join(tmp, name)); err != nil {
			return err
		}
	}
	if err := r.verify(ctx, tmp); err != nil {
		return err
	}
	if err := syncDir(tmp); err != nil {
		return err
	}
	if _, err := os.Lstat(r.path("bin")); errors.Is(err, os.ErrNotExist) {
		if err := os.Rename(tmp, r.path("bin")); err != nil {
			return err
		}
		return syncDir(r.Root)
	} else if err != nil {
		return err
	}
	if err := realDir(r.path("bin")); err != nil {
		return err
	}
	current, err := r.releaseHash(r.path("bin"))
	if err != nil {
		return err
	}
	next, err := r.releaseHash(tmp)
	if err != nil {
		return err
	}
	if current == next {
		if err := os.RemoveAll(r.path("pending")); err != nil {
			return err
		}
		return syncDir(r.Root)
	}
	if _, err := os.Lstat(r.path("pending")); err == nil {
		if err := realDir(r.path("pending")); err != nil {
			return err
		}
		if err := exchange(tmp, r.path("pending")); err != nil {
			return err
		}
	} else if errors.Is(err, os.ErrNotExist) {
		if err := os.Rename(tmp, r.path("pending")); err != nil {
			return err
		}
	} else {
		return err
	}
	return syncDir(r.Root)
}

type Service struct {
	runtime Runtime
	lock    *os.File
	token   string
}

// Activating reports whether this process owns an uncommitted candidate
// activation. Callers use it to require stronger startup qualification before
// Ready permanently discards the rollback release.
func (s *Service) Activating() bool {
	return s != nil && s.token != ""
}

// Start acquires the lifetime lock before touching the installed pair. Reexec
// is returned after either activation or recovery. The lock survives exec and
// is then marked close-on-exec so ordinary helpers cannot inherit it.
func (r Runtime) Start(ctx context.Context) (service *Service, reexec bool, err error) {
	if err = r.prepare(); err != nil {
		return nil, false, err
	}
	lifetime, err := serviceLock(r.path("service.lock"), os.Getenv(lockEnv))
	if err != nil {
		return nil, false, err
	}
	service = &Service{runtime: r, lock: lifetime}
	defer func() {
		if err != nil {
			lifetime.Close()
		}
	}()
	lock, err := r.installLock(ctx)
	if err != nil {
		return nil, false, err
	}
	defer lock.Close()
	var state activation
	raw, readErr := os.ReadFile(r.path("activation.json"))
	if readErr == nil {
		if err = json.Unmarshal(raw, &state); err != nil {
			return nil, false, err
		}
		current, hashErr := r.releaseHash(r.path("bin"))
		if hashErr != nil {
			return nil, false, hashErr
		}
		if state.Token != "" && os.Getenv(activationEnv) == state.Token && current == state.After {
			service.token = state.Token
			return service, false, r.verify(ctx, r.path("bin"))
		}
		// A service that never reached readiness (including a crash immediately
		// after exchange) is rolled back on its next launchd restart.
		if current == state.After {
			if err = r.verify(ctx, r.path("candidate")); err != nil {
				return nil, false, err
			}
			previous, hashErr := r.releaseHash(r.path("candidate"))
			if hashErr != nil || previous != state.Before {
				return nil, false, errors.New("rollback pair does not match activation journal")
			}
			if err = exchange(r.path("bin"), r.path("candidate")); err != nil {
				return nil, false, err
			}
			if err = syncDir(r.Root); err != nil {
				return nil, false, err
			}
			reexec = true
		} else if current != state.Before {
			return nil, false, errors.New("installed pair does not match activation journal")
		}
		if err = os.Remove(r.path("activation.json")); err != nil {
			return nil, false, err
		}
		if err = os.RemoveAll(r.path("candidate")); err != nil {
			return nil, false, err
		}
		if err = syncDir(r.Root); err != nil {
			return nil, false, err
		}
		return service, reexec, nil
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return nil, false, readErr
	}
	if err = r.verify(ctx, r.path("bin")); err != nil {
		return nil, false, err
	}
	if _, err = os.Lstat(r.path("pending")); errors.Is(err, os.ErrNotExist) {
		return service, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if err = realDir(r.path("pending")); err != nil {
		return nil, false, err
	}
	if err = r.verify(ctx, r.path("pending")); err != nil {
		return nil, false, err
	}
	// Leftovers before the journal was written were never activated.
	if err = os.RemoveAll(r.path("candidate")); err != nil {
		return nil, false, err
	}
	if err = os.Rename(r.path("pending"), r.path("candidate")); err != nil {
		return nil, false, err
	}
	state.Before, err = r.releaseHash(r.path("bin"))
	if err != nil {
		return nil, false, err
	}
	state.After, err = r.releaseHash(r.path("candidate"))
	if err != nil {
		return nil, false, err
	}
	var token [24]byte
	if _, err = rand.Read(token[:]); err != nil {
		return nil, false, err
	}
	state.Token = hex.EncodeToString(token[:])
	if err = writeJSON(r.path("activation.json"), state); err != nil {
		return nil, false, err
	}
	if err = exchange(r.path("bin"), r.path("candidate")); err != nil {
		return nil, false, err
	}
	if err = syncDir(r.Root); err != nil {
		return nil, false, err
	}
	service.token = state.Token
	return service, true, nil
}

// Ready commits only after the daemon has opened its API listener and any
// suspended turns have reacquired a reporting worker. Until then launchd or
// systemd can recover the previous signed pair after a failed startup.
func (s *Service) Ready() error {
	if s == nil || s.token == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	lock, err := s.runtime.installLock(ctx)
	if err != nil {
		return err
	}
	defer lock.Close()
	// Remove the journal before collecting the old pair: a crash during
	// collection must not turn a committed update into an invalid rollback.
	if err := os.Remove(s.runtime.path("activation.json")); err != nil {
		return err
	}
	if err := syncDir(s.runtime.Root); err != nil {
		return err
	}
	s.token = ""
	if err := os.RemoveAll(s.runtime.path("candidate")); err != nil {
		return err
	}
	return syncDir(s.runtime.Root)
}

func (s *Service) Close() {
	if s != nil && s.lock != nil {
		_ = s.lock.Close()
		s.lock = nil
	}
}

func (s *Service) Exec(args []string) error {
	if err := inheritLock(s.lock); err != nil {
		return err
	}
	env := make([]string, 0, len(os.Environ())+2)
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, activationEnv+"=") && !strings.HasPrefix(entry, lockEnv+"=") {
			env = append(env, entry)
		}
	}
	env = append(env, activationEnv+"="+s.token, fmt.Sprintf("%s=%d", lockEnv, s.lock.Fd()))
	return execProcess(s.runtime.path("bin/dieter"), args, env)
}

func (r Runtime) prepare() error {
	if !filepath.IsAbs(r.Root) || filepath.Clean(r.Root) != r.Root {
		return errors.New("service runtime requires a clean absolute path")
	}
	if err := os.MkdirAll(r.Root, 0o700); err != nil {
		return err
	}
	resolved, err := filepath.EvalSymlinks(r.Root)
	if err != nil {
		return err
	}
	if resolved != r.Root {
		return errors.New("service runtime path must not contain symlinks")
	}
	if err := realDir(r.Root); err != nil {
		return err
	}
	return os.Chmod(r.Root, 0o700)
}

func realDir(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s must be a real directory", path)
	}
	return nil
}

// The installation lock ensures these private temporary files cannot belong
// to a concurrent copier. Reclaim crash leftovers on the next staging attempt.
func (r Runtime) collectInterruptedTemps() error {
	entries, err := os.ReadDir(r.Root)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".stage-") || strings.HasPrefix(entry.Name(), ".journal-") {
			if err := os.RemoveAll(r.path(entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

func copyExecutable(source, target string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return fmt.Errorf("%s must be a regular executable", source)
	}
	if info.Size() > 256<<20 {
		return errors.New("service executable exceeds 256 MiB")
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0755)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, io.LimitReader(in, (256<<20)+1))
	syncErr := out.Sync()
	closeErr := out.Close()
	return errors.Join(copyErr, syncErr, closeErr)
}

func pairHash(dir string) (string, error) {
	return hashExecutables(dir, executables)
}

func (r Runtime) releaseHash(dir string) (string, error) {
	return hashExecutables(dir, r.executableNames())
}

func hashExecutables(dir string, names []string) (string, error) {
	h := sha256.New()
	for _, name := range names {
		info, err := os.Lstat(filepath.Join(dir, name))
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() || info.Size() > 256<<20 {
			return "", errors.New("invalid service executable")
		}
		file, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "%s:%d:", name, info.Size())
		_, err = io.Copy(h, file)
		file.Close()
		if err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func writeJSON(path string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".journal-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(raw)
	err = errors.Join(writeErr, file.Sync(), file.Close())
	if err != nil {
		return err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}

func syncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
