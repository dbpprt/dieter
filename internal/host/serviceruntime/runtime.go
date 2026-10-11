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

	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// TeamID is the only Developer ID team trusted for the daemon, capture helper
// and privacy helper. It comes from config/identity.json.
const TeamID = buildinfo.AppleTeamID
const (
	activationEnv = config.ServiceActivationVar
	lockEnv       = config.ServiceLockFDVar
)

var executables = []string{"dieter", "dieter-capture"}

type Runtime struct {
	Root string
	// Executables defaults to the signed daemon/helper pair. Platform runtimes
	// may supply an explicit list when their verification policy differs.
	Executables []string
	// Signed app bundles travel with their daemon/helper release and participate
	// in the same atomic activation and rollback. No links are permitted.
	Bundles []string
	// SourceBundlePrefix is relative to the standalone source executable pair.
	// Homebrew stores its companion bundle in ../libexec; release archives keep
	// it beside the pair. Activated runtime paths are identical in both cases.
	SourceBundlePrefix string
	// Verify is injectable for isolated filesystem tests. Production always
	// uses Developer ID verification; there is no unsigned-install CLI flag.
	Verify func(context.Context, string) error
	// InheritedLock and ActivationToken are the handoff from a process that
	// re-executed this daemon through Service.Exec (DIETER_SERVICE_LOCK_FD and
	// DIETER_SERVICE_ACTIVATION). Both are empty on a fresh start. The handoff
	// belongs to the one Start call of the re-executed process.
	InheritedLock   string
	ActivationToken string
}

func (r Runtime) executableNames() []string {
	if len(r.Executables) == 0 {
		return executables
	}
	return r.Executables
}

type activation struct {
	Format int    `json:"format,omitempty"`
	Token  string `json:"token"`
	Before string `json:"before"`
	After  string `json:"after"`
}

// HomebrewRoot is independent of the formula's versioned opt/Cellar prefix.
func HomebrewRoot(prefix string) string {
	return filepath.Join(prefix, "var", "dieter", "service")
}

func (r Runtime) path(name string) string { return filepath.Join(r.Root, name) }

// DaemonExecutable is a real executable at the managed activation path.
func (r Runtime) DaemonExecutable() string {
	return r.path("bin/dieter")
}

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
	for _, name := range r.Bundles {
		if err := realDir(filepath.Join(dir, name)); err != nil {
			return err
		}
	}
	return verify(ctx, dir)
}

func VerifySignedPair(ctx context.Context, dir string) error {
	return verifySignedRelease(ctx, dir, verifySignedExecutable)
}

func verifySignedRelease(ctx context.Context, dir string, check func(context.Context, string, string) error) error {
	if err := verifySignedPairForTeam(ctx, dir, TeamID, check); err != nil {
		return err
	}
	return check(ctx, filepath.Join(dir, "DieterPrivacyHelper.app"), developerIDRequirement(buildinfo.PrivacyIdentifier, TeamID))
}

func verifySignedExecutables(ctx context.Context, dir string) error {
	return verifySignedPair(ctx, dir, verifySignedExecutable)
}

func verifySignedPair(ctx context.Context, dir string, check func(context.Context, string, string) error) error {
	return verifySignedPairForTeam(ctx, dir, TeamID, check)
}

// developerIDRequirement is the designated requirement every shipped executable
// must satisfy: the identity's bundle identifier, signed by Developer ID for team.
func developerIDRequirement(identifier, team string) string {
	return fmt.Sprintf(`identifier %q and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = %q`, identifier, team)
}

func verifySignedPairForTeam(ctx context.Context, dir, team string, check func(context.Context, string, string) error) error {
	for _, name := range executables {
		identifier := buildinfo.DaemonIdentifier
		if name == "dieter-capture" {
			identifier = buildinfo.CaptureIdentifier
		}
		if err := check(ctx, filepath.Join(dir, name), developerIDRequirement(identifier, team)); err != nil {
			return fmt.Errorf("verify signed %s for team %s: %w", name, team, err)
		}
	}
	return nil
}

func verifySignedExecutable(ctx context.Context, path, requirement string) error {
	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	args := []string{"--verify", "--strict", "-R", "=" + requirement}
	if filepath.Base(path) == "DieterPrivacyHelper.app" {
		args = append(args, "--deep")
	}
	output, err := exec.CommandContext(checkCtx, "/usr/bin/codesign", append(args, path)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

// Only an activation rollback may restore the earlier signed, unbundled layout.
// New staged macOS releases always require the privacy helper bundle.
func (r Runtime) verifyRollback(ctx context.Context, dir string) error {
	if len(r.Bundles) == 0 {
		return r.verify(ctx, dir)
	}
	if _, err := os.Lstat(filepath.Join(dir, r.Bundles[0])); !errors.Is(err, os.ErrNotExist) {
		return r.verify(ctx, dir)
	}
	if err := realDir(dir); err != nil {
		return err
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
	if r.Verify != nil {
		return r.Verify(ctx, dir)
	}
	return verifySignedExecutables(ctx, dir)
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
	for _, name := range r.Bundles {
		if err := copyBundle(filepath.Join(source, r.SourceBundlePrefix, name), filepath.Join(tmp, name)); err != nil {
			return err
		}
	}
	if err := r.verify(ctx, tmp); err != nil {
		return err
	}
	if err := fsx.SyncDir(tmp); err != nil {
		return err
	}
	if _, err := os.Lstat(r.path("bin")); errors.Is(err, os.ErrNotExist) {
		if err := os.Rename(tmp, r.path("bin")); err != nil {
			return err
		}
		return fsx.SyncDir(r.Root)
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
		return fsx.SyncDir(r.Root)
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
	return fsx.SyncDir(r.Root)
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
	lifetime, err := serviceLock(r.path("service.lock"), r.InheritedLock)
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
		if state.Format < 0 || state.Format > 1 {
			return nil, false, errors.New("unsupported service activation format")
		}
		journalHash := r.releaseHash
		if state.Format == 0 {
			journalHash = func(dir string) (string, error) { return hashExecutables(dir, r.executableNames()) }
		}
		current, hashErr := journalHash(r.path("bin"))
		if hashErr != nil {
			return nil, false, hashErr
		}
		if state.Token != "" && r.ActivationToken == state.Token && current == state.After {
			service.token = state.Token
			return service, false, r.verify(ctx, r.path("bin"))
		}
		// A service that never reached readiness (including a crash immediately
		// after exchange) is rolled back on its next launchd restart.
		if current == state.After {
			if err = r.verifyRollback(ctx, r.path("candidate")); err != nil {
				return nil, false, err
			}
			previous, hashErr := journalHash(r.path("candidate"))
			if hashErr != nil || previous != state.Before {
				return nil, false, errors.New("rollback pair does not match activation journal")
			}
			if err = exchange(r.path("bin"), r.path("candidate")); err != nil {
				return nil, false, err
			}
			if err = fsx.SyncDir(r.Root); err != nil {
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
		if err = fsx.SyncDir(r.Root); err != nil {
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
	state.Format = 1
	if err = writeJSON(r.path("activation.json"), state); err != nil {
		return nil, false, err
	}
	if err = exchange(r.path("bin"), r.path("candidate")); err != nil {
		return nil, false, err
	}
	if err = fsx.SyncDir(r.Root); err != nil {
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
	if err := fsx.SyncDir(s.runtime.Root); err != nil {
		return err
	}
	s.token = ""
	if err := os.RemoveAll(s.runtime.path("candidate")); err != nil {
		return err
	}
	return fsx.SyncDir(s.runtime.Root)
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
	return execProcess(s.runtime.DaemonExecutable(), args, env)
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
	base, err := hashExecutables(dir, r.executableNames())
	if err != nil || len(r.Bundles) == 0 {
		return base, err
	}
	// A pre-bundle installation can be staged or restored, but never qualifies
	// as a new runtime. Its signed executable pair is its complete identity.
	if _, err := os.Lstat(filepath.Join(dir, r.Bundles[0])); errors.Is(err, os.ErrNotExist) {
		return base, nil
	}
	h := sha256.New()
	_, _ = io.WriteString(h, base)
	for _, name := range r.Bundles {
		if err := walkBundle(filepath.Join(dir, name), func(path, relative string, info os.FileInfo) error {
			fmt.Fprintf(h, "%s/%s:%o:", name, relative, info.Mode().Perm())
			if info.IsDir() {
				_, _ = io.WriteString(h, "directory:")
				return nil
			}
			fmt.Fprintf(h, "%d:", info.Size())
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			defer file.Close()
			_, err = io.Copy(h, file)
			return err
		}); err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func walkBundle(root string, visit func(string, string, os.FileInfo) error) error {
	if err := realDir(root); err != nil {
		return err
	}
	count := 0
	var total int64
	return filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		count++
		total += info.Size()
		if count > 256 || total > 512<<20 || (!info.IsDir() && !info.Mode().IsRegular()) {
			return errors.New("invalid service bundle")
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		return visit(path, relative, info)
	})
}

func copyBundle(source, target string) error {
	return walkBundle(source, func(path, relative string, info os.FileInfo) error {
		destination := filepath.Join(target, relative)
		if info.IsDir() {
			return os.Mkdir(destination, info.Mode().Perm())
		}
		input, err := os.Open(path)
		if err != nil {
			return err
		}
		defer input.Close()
		output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm())
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(output, input)
		return errors.Join(copyErr, output.Sync(), output.Close())
	})
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
	return fsx.WriteFile(path, raw, 0o600)
}
