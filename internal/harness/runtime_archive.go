package harness

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/buildinfo"
)

// A runtime archive is a gzip-compressed tar: manifest.json first, then the
// managed Bun package as npm installed it (bun/, before Bun's postinstall, so
// each host still selects its own executable variant), then the runtime's
// node_modules (harness/node_modules). Embedded runtime sources never travel
// in it; the daemon stages those from its own binary.
const (
	runtimeArchiveFormat        = 1
	runtimeArchiveManifestName  = "manifest.json"
	archiveBunTree              = "bun"
	archiveHarnessTree          = "harness"
	maxRuntimeArchiveEntries    = 250_000
	maxRuntimeArchiveManifest   = 64 << 10
	maxRuntimeArchiveNameLength = 1024
	runtimeArchiveTimeout       = 15 * time.Minute
)

// Size bounds of a downloaded archive (compressed) and of its regular file
// contents. With the agent CLIs (October 2026) the darwin-arm64 archive is
// ~690 MB expanding to ~2.0 GB in ~70,000 entries; linux-amd64 also carries
// Claude Code's musl build and four Bun variants, ~1.03 GB expanding to
// ~2.9 GB. GitHub release assets are limited to 2 GiB. Variables so tests can
// exercise them.
var (
	maxRuntimeArchiveBytes    = int64(3 << 29)
	maxRuntimeArchiveExpanded = int64(4 << 30)
)

// runtimeArchiveRoots names the top-level entries each archive tree may carry,
// in archive order.
var runtimeArchiveRoots = map[string][]string{
	archiveBunTree:     {"node_modules", "package.json"},
	archiveHarnessTree: {"node_modules"},
}

// runtimeArchiveEpoch is the modification time of every archive entry, so
// identical installs produce identical archives.
var runtimeArchiveEpoch = time.Date(2000, time.January, 1, 0, 0, 0, 0, time.UTC)

// RuntimeArchiveName is the release asset holding one platform's prebuilt
// harness runtime.
func RuntimeArchiveName(goos, goarch string) string {
	return "dieter-harness-runtime-" + goos + "-" + goarch + ".tar.gz"
}

// RuntimeArchive pins the prebuilt harness runtime a release daemon installs
// instead of running npm. The zero value pins nothing.
type RuntimeArchive struct {
	// BaseURL is the directory holding RuntimeArchiveName(GOOS, GOARCH): HTTPS,
	// or plain HTTP on a loopback address for local tests.
	BaseURL string
	// SHA256 is the hex digest of this platform's archive.
	SHA256 string
	// Client downloads the archive; nil uses a client that honors the
	// HTTPS_PROXY, HTTP_PROXY and NO_PROXY environment. Redirects always
	// follow the BaseURL scheme rules.
	Client *http.Client
}

// ReleaseRuntimeArchive is the archive this binary was built with: the
// platform asset of its own release, pinned by -ldflags in
// buildinfo.HarnessRuntimeSHA256. Source builds pin none.
func ReleaseRuntimeArchive() RuntimeArchive {
	sum := strings.TrimSpace(buildinfo.HarnessRuntimeSHA256)
	if sum == "" {
		return RuntimeArchive{}
	}
	base := strings.TrimSpace(buildinfo.HarnessRuntimeBaseURL)
	if base == "" {
		base = buildinfo.ReleasesURL + "/download/v" + buildinfo.ReleaseVersion
	}
	return RuntimeArchive{BaseURL: base, SHA256: sum}
}

func (a RuntimeArchive) pinned() bool { return a.SHA256 != "" }

// runtimeArchiveManifest identifies what an archive was built from. The daemon
// installs only an archive built from its own embedded runtime.
type runtimeArchiveManifest struct {
	Format            int    `json:"format"`
	Platform          string `json:"platform"`
	RuntimeDigest     string `json:"runtimeDigest"`
	PackageLockSHA256 string `json:"packageLockSha256"`
	BunVersion        string `json:"bunVersion"`
}

func currentRuntimeArchiveManifest() runtimeArchiveManifest {
	lock, err := runtimeAssets.ReadFile("runtime/package-lock.json")
	if err != nil {
		panic("embedded harness runtime is incomplete: " + err.Error())
	}
	sum := sha256.Sum256(lock)
	return runtimeArchiveManifest{
		Format: runtimeArchiveFormat, Platform: runtime.GOOS + "-" + runtime.GOARCH, RuntimeDigest: embeddedRuntimeDigest(),
		PackageLockSHA256: hex.EncodeToString(sum[:]), BunVersion: managedBunVersion,
	}
}

func (m runtimeArchiveManifest) check(want runtimeArchiveManifest) error {
	switch {
	case m.Format != want.Format:
		return fmt.Errorf("archive format is %d, want %d", m.Format, want.Format)
	case m.Platform != want.Platform:
		return fmt.Errorf("archive is for %s, want %s", m.Platform, want.Platform)
	case m.RuntimeDigest != want.RuntimeDigest:
		return fmt.Errorf("archive was built from harness runtime %s, this binary embeds %s", m.RuntimeDigest, want.RuntimeDigest)
	case m.PackageLockSHA256 != want.PackageLockSHA256:
		return fmt.Errorf("archive was built from package-lock.json %s, this binary embeds %s", m.PackageLockSHA256, want.PackageLockSHA256)
	case m.BunVersion != want.BunVersion:
		return fmt.Errorf("archive carries Bun %s, want %s", m.BunVersion, want.BunVersion)
	}
	return nil
}

// installRuntimeArchive downloads the pinned archive and extracts its
// node_modules into stage, then installs the managed Bun it carries.
func installRuntimeArchive(ctx context.Context, archive RuntimeArchive, stage, dieterHome string) error {
	path, err := downloadRuntimeArchive(ctx, archive, filepath.Dir(stage))
	if err != nil {
		return err
	}
	defer os.Remove(path)
	if err := extractRuntimeArchive(path, archiveHarnessTree, stage); err != nil {
		return fmt.Errorf("extract AI SDK harness runtime archive: %w", err)
	}
	// Bun serves only OMP. As with npm installs, a host where it cannot run
	// fails OMP turns, which retry through ensureManagedBun and report why,
	// rather than every harness.
	_, _ = installArchiveBun(ctx, path, dieterHome)
	return nil
}

// installArchiveBun publishes the managed Bun from a verified archive file
// unless that version is already installed.
func installArchiveBun(ctx context.Context, path, dieterHome string) (string, error) {
	return installManagedBun(ctx, dieterHome, func(_ context.Context, stage string) error {
		return extractRuntimeArchive(path, archiveBunTree, stage)
	})
}

// downloadRuntimeArchive streams this platform's archive into a new file in
// dir, hashing it on the way, and returns the file only when its SHA-256 is
// the pinned one. The caller removes it.
func downloadRuntimeArchive(ctx context.Context, archive RuntimeArchive, dir string) (string, error) {
	want := strings.ToLower(strings.TrimSpace(archive.SHA256))
	if decoded, err := hex.DecodeString(want); err != nil || len(decoded) != sha256.Size {
		return "", fmt.Errorf("pinned AI SDK harness runtime archive SHA-256 %q is invalid", archive.SHA256)
	}
	source := strings.TrimRight(strings.TrimSpace(archive.BaseURL), "/") + "/" + RuntimeArchiveName(runtime.GOOS, runtime.GOARCH)
	if err := checkRuntimeArchiveURL(source); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, runtimeArchiveTimeout)
	defer cancel()
	failed := func(err error) error {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("download AI SDK harness runtime archive %s: timed out after %s", source, runtimeArchiveTimeout)
		}
		return fmt.Errorf("download AI SDK harness runtime archive %s: %w", source, err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return "", failed(err)
	}
	response, err := runtimeArchiveClient(archive.Client).Do(request)
	if err != nil {
		return "", failed(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", failed(fmt.Errorf("HTTP %s", response.Status))
	}
	if response.ContentLength > maxRuntimeArchiveBytes {
		return "", failed(fmt.Errorf("archive is %d bytes, the limit is %d", response.ContentLength, maxRuntimeArchiveBytes))
	}
	file, err := os.CreateTemp(dir, ".download-*.tar.gz")
	if err != nil {
		return "", err
	}
	complete := false
	defer func() {
		if !complete {
			_ = file.Close()
			_ = os.Remove(file.Name())
		}
	}()
	hash := sha256.New()
	written, err := io.Copy(io.MultiWriter(file, hash), io.LimitReader(response.Body, maxRuntimeArchiveBytes+1))
	if err != nil {
		return "", failed(err)
	}
	if written > maxRuntimeArchiveBytes {
		return "", failed(fmt.Errorf("archive exceeds %d bytes", maxRuntimeArchiveBytes))
	}
	if actual := hex.EncodeToString(hash.Sum(nil)); actual != want {
		return "", failed(fmt.Errorf("SHA-256 of the %d downloaded bytes is %s, want %s", written, actual, want))
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	complete = true
	return file.Name(), nil
}

// runtimeArchiveClient applies the archive URL rules to every redirect of
// base, or of a proxy-aware default client.
func runtimeArchiveClient(base *http.Client) *http.Client {
	var client http.Client
	if base != nil {
		client = *base
	} else {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.ResponseHeaderTimeout = time.Minute
		client.Transport = transport
	}
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("too many redirects")
		}
		return checkRuntimeArchiveURL(request.URL.String())
	}
	return &client
}

// checkRuntimeArchiveURL admits HTTPS, and plain HTTP only on a loopback
// address for local end-to-end tests. The pinned SHA-256 authenticates the
// archive either way.
func checkRuntimeArchiveURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("AI SDK harness runtime archive URL %q is invalid", raw)
	}
	if parsed.Scheme == "https" {
		return nil
	}
	if ip := net.ParseIP(parsed.Hostname()); parsed.Scheme == "http" && ip != nil && ip.IsLoopback() {
		return nil
	}
	return fmt.Errorf("AI SDK harness runtime archive URL %q must use HTTPS", raw)
}

// extractRuntimeArchive verifies the manifest of a downloaded archive and
// extracts the entries of one tree into dest. It validates every entry of the
// archive: names stay inside their tree, only directories, regular files and
// symbolic links that resolve inside their tree are accepted, nothing is
// written through a symbolic link, and the totals stay bounded.
func extractRuntimeArchive(archivePath, tree, dest string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer file.Close()
	compressed, err := gzip.NewReader(bufio.NewReaderSize(file, 1<<20))
	if err != nil {
		return fmt.Errorf("read archive: %w", err)
	}
	defer compressed.Close()
	reader := tar.NewReader(compressed)
	header, err := reader.Next()
	if err != nil {
		return fmt.Errorf("read archive manifest: %w", err)
	}
	if header.Name != runtimeArchiveManifestName || header.Typeflag != tar.TypeReg || header.Size > maxRuntimeArchiveManifest {
		return errors.New("archive does not begin with its manifest")
	}
	raw, err := io.ReadAll(reader)
	if err != nil {
		return fmt.Errorf("read archive manifest: %w", err)
	}
	var manifest runtimeArchiveManifest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return fmt.Errorf("decode archive manifest: %w", err)
	}
	if err := manifest.check(currentRuntimeArchiveManifest()); err != nil {
		return err
	}

	directories := map[string]bool{}
	entries, expanded := 0, int64(0)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read archive: %w", err)
		}
		if entries++; entries > maxRuntimeArchiveEntries {
			return fmt.Errorf("archive has more than %d entries", maxRuntimeArchiveEntries)
		}
		entryTree, name, err := runtimeArchiveEntry(header)
		if err != nil {
			return err
		}
		if header.Typeflag == tar.TypeReg {
			if expanded += header.Size; header.Size < 0 || expanded > maxRuntimeArchiveExpanded {
				return fmt.Errorf("archive expands beyond %d bytes", maxRuntimeArchiveExpanded)
			}
		}
		if entryTree != tree {
			continue
		}
		parent, err := realArchiveParent(dest, name, directories)
		if err != nil {
			return err
		}
		target := filepath.Join(parent, path.Base(name))
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.Mkdir(target, 0o755); err != nil {
				info, statErr := os.Lstat(target)
				if statErr != nil || !info.IsDir() {
					return fmt.Errorf("create archive directory %s: %w", header.Name, err)
				}
			}
			directories[name] = true
		case tar.TypeReg:
			if err := extractArchiveFile(reader, target, header); err != nil {
				return fmt.Errorf("extract %s: %w", header.Name, err)
			}
		case tar.TypeSymlink:
			if err := os.Symlink(header.Linkname, target); err != nil {
				return fmt.Errorf("extract %s: %w", header.Name, err)
			}
		}
	}
}

// runtimeArchiveEntry validates one entry header and returns its tree and its
// path inside that tree.
func runtimeArchiveEntry(header *tar.Header) (string, string, error) {
	name := header.Name
	if header.Typeflag == tar.TypeDir {
		name = strings.TrimSuffix(name, "/")
	}
	if name == "" || len(name) > maxRuntimeArchiveNameLength || strings.ContainsAny(name, "\\\x00") || path.IsAbs(name) ||
		path.Clean(name) != name || name == ".." || strings.HasPrefix(name, "../") {
		return "", "", fmt.Errorf("archive entry %q has an unsafe name", header.Name)
	}
	tree, inside, found := strings.Cut(name, "/")
	roots, known := runtimeArchiveRoots[tree]
	if !found || !known {
		return "", "", fmt.Errorf("archive entry %q is outside the runtime trees", header.Name)
	}
	top, _, _ := strings.Cut(inside, "/")
	allowed := false
	for _, root := range roots {
		allowed = allowed || top == root
	}
	if !allowed {
		return "", "", fmt.Errorf("archive entry %q is outside the runtime trees", header.Name)
	}
	switch header.Typeflag {
	case tar.TypeDir, tar.TypeReg:
	case tar.TypeSymlink:
		if err := checkArchiveLink(inside, header.Linkname); err != nil {
			return "", "", fmt.Errorf("archive entry %q: %w", header.Name, err)
		}
	default:
		return "", "", fmt.Errorf("archive entry %q has unsupported type %q", header.Name, header.Typeflag)
	}
	return tree, inside, nil
}

// checkArchiveLink admits a relative, clean link target that resolves inside
// the link's tree. Clean relative paths climb only through leading "..", and
// entries are never created beneath a link, so the lexical check matches the
// filesystem.
func checkArchiveLink(name, target string) error {
	if target == "" || strings.ContainsAny(target, "\\\x00") || path.IsAbs(target) || path.Clean(target) != target {
		return fmt.Errorf("link target %q is not a clean relative path", target)
	}
	if resolved := path.Join(path.Dir(name), target); resolved == ".." || strings.HasPrefix(resolved, "../") {
		return fmt.Errorf("link target %q escapes the archive tree", target)
	}
	return nil
}

// realArchiveParent creates or verifies the parent directories of name under
// dest, refusing any that is not a real directory. directories caches the
// verified ones.
func realArchiveParent(dest, name string, directories map[string]bool) (string, error) {
	parent := path.Dir(name)
	if parent == "." || directories[parent] {
		return filepath.Join(dest, filepath.FromSlash(parent)), nil
	}
	current := ""
	for _, part := range strings.Split(parent, "/") {
		current = path.Join(current, part)
		if directories[current] {
			continue
		}
		target := filepath.Join(dest, filepath.FromSlash(current))
		info, err := os.Lstat(target)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := os.Mkdir(target, 0o755); err != nil {
				return "", err
			}
		case err != nil:
			return "", err
		case !info.IsDir():
			return "", fmt.Errorf("archive entry %q is beneath a non-directory", name)
		}
		directories[current] = true
	}
	return filepath.Join(dest, filepath.FromSlash(parent)), nil
}

func extractArchiveFile(reader io.Reader, target string, header *tar.Header) error {
	mode := os.FileMode(0o644)
	if header.Mode&0o111 != 0 {
		mode = 0o755
	}
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.CopyN(file, reader, header.Size); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

// writeRuntimeArchive writes the manifest and each tree's allowed roots from
// sources (tree name to directory) as a deterministic archive: lexical walk
// order, a fixed modification time, root ownership and normalized modes, so
// identical inputs produce identical bytes. Hard links become regular files.
func writeRuntimeArchive(w io.Writer, manifest runtimeArchiveManifest, sources map[string]string) error {
	compressed := gzip.NewWriter(w)
	archive := tar.NewWriter(compressed)
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	if err := archive.WriteHeader(&tar.Header{
		Name: runtimeArchiveManifestName, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(raw)), ModTime: runtimeArchiveEpoch,
	}); err != nil {
		return err
	}
	if _, err := archive.Write(raw); err != nil {
		return err
	}
	for _, tree := range []string{archiveBunTree, archiveHarnessTree} {
		source := sources[tree]
		for _, root := range runtimeArchiveRoots[tree] {
			if err := filepath.WalkDir(filepath.Join(source, root), func(file string, entry fs.DirEntry, walkErr error) error {
				if walkErr != nil {
					return walkErr
				}
				return writeArchiveEntry(archive, source, tree, file, entry)
			}); err != nil {
				return fmt.Errorf("archive %s: %w", tree, err)
			}
		}
	}
	if err := archive.Close(); err != nil {
		return err
	}
	return compressed.Close()
}

func writeArchiveEntry(archive *tar.Writer, source, tree, file string, entry fs.DirEntry) error {
	relative, err := filepath.Rel(source, file)
	if err != nil {
		return err
	}
	name := filepath.ToSlash(relative)
	info, err := entry.Info()
	if err != nil {
		return err
	}
	header := &tar.Header{Name: tree + "/" + name, ModTime: runtimeArchiveEpoch}
	switch mode := info.Mode(); {
	case mode.IsDir():
		header.Typeflag, header.Name, header.Mode = tar.TypeDir, header.Name+"/", 0o755
	case mode.IsRegular():
		header.Typeflag, header.Mode, header.Size = tar.TypeReg, 0o644, info.Size()
		if mode&0o111 != 0 {
			header.Mode = 0o755
		}
	case mode&fs.ModeSymlink != 0:
		target, err := os.Readlink(file)
		if err != nil {
			return err
		}
		if err := checkArchiveLink(name, target); err != nil {
			return fmt.Errorf("%s: %w", file, err)
		}
		header.Typeflag, header.Mode, header.Linkname = tar.TypeSymlink, 0o777, target
	default:
		return fmt.Errorf("%s: unsupported file type %s", file, mode.Type())
	}
	if err := archive.WriteHeader(header); err != nil {
		return err
	}
	if header.Typeflag != tar.TypeReg {
		return nil
	}
	contents, err := os.Open(file)
	if err != nil {
		return err
	}
	defer contents.Close()
	if written, err := io.Copy(archive, contents); err != nil {
		return err
	} else if written != header.Size {
		return fmt.Errorf("%s changed while archiving", file)
	}
	return nil
}

// RuntimeArchiveInfo describes a written runtime archive.
type RuntimeArchiveInfo struct {
	Path          string
	Size          int64
	SHA256        string
	RuntimeDigest string
	// Agents are the agent CLIs verified in the installed archive, by agent.
	Agents map[string]RuntimeAgent
}

// RuntimeAgent is one agent CLI as the runtime's own check reports it: its
// package and package-lock version, the CLI version it reports, and this
// platform's native package.
type RuntimeAgent struct {
	Package        string `json:"package"`
	PackageVersion string `json:"packageVersion"`
	Version        string `json:"version"`
	Native         string `json:"native"`
}

// runtimeAgents are the agents whose CLIs the runtime ships and their bridges
// link instead of installing.
var runtimeAgents = []string{"claude", "codex", "omp"}

// BuildRuntimeArchive produces this platform's prebuilt runtime archive at
// output. It installs the embedded runtime and the managed Bun package with
// npm exactly as a source-built daemon does, writes the archive, and verifies
// it by installing it into a scratch home through the daemon's archive path,
// including Bun's postinstall and version check, and then running every agent
// CLI from the installed runtime (verify-agents.mjs).
func BuildRuntimeArchive(ctx context.Context, output string) (RuntimeArchiveInfo, error) {
	return buildRuntimeArchive(ctx, output, func(ctx context.Context, sources map[string]string) error {
		if err := npmInstallRuntime(ctx, sources[archiveHarnessTree]); err != nil {
			return err
		}
		return npmInstallManagedBun(ctx, sources[archiveBunTree])
	})
}

// buildRuntimeArchive is BuildRuntimeArchive with the install step supplied:
// install populates each staged tree (tree name to directory) after the
// embedded runtime sources are staged.
func buildRuntimeArchive(ctx context.Context, output string, install func(context.Context, map[string]string) error) (RuntimeArchiveInfo, error) {
	output, err := filepath.Abs(output)
	if err != nil {
		return RuntimeArchiveInfo{}, err
	}
	if want := RuntimeArchiveName(runtime.GOOS, runtime.GOARCH); filepath.Base(output) != want {
		return RuntimeArchiveInfo{}, fmt.Errorf("this platform's harness runtime archive is named %s", want)
	}
	work, err := os.MkdirTemp("", "dieter-harness-runtime-archive-")
	if err != nil {
		return RuntimeArchiveInfo{}, err
	}
	defer os.RemoveAll(work)
	sources := map[string]string{archiveHarnessTree: filepath.Join(work, archiveHarnessTree), archiveBunTree: filepath.Join(work, archiveBunTree)}
	for _, dir := range sources {
		if err := os.Mkdir(dir, 0o700); err != nil {
			return RuntimeArchiveInfo{}, err
		}
	}
	if err := stageRuntimeAssets(sources[archiveHarnessTree]); err != nil {
		return RuntimeArchiveInfo{}, fmt.Errorf("stage AI SDK harness runtime: %w", err)
	}
	if err := install(ctx, sources); err != nil {
		return RuntimeArchiveInfo{}, err
	}

	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		return RuntimeArchiveInfo{}, err
	}
	file, err := os.CreateTemp(filepath.Dir(output), ".tmp-"+filepath.Base(output)+"-")
	if err != nil {
		return RuntimeArchiveInfo{}, err
	}
	defer os.Remove(file.Name())
	hash := sha256.New()
	buffered := bufio.NewWriterSize(io.MultiWriter(file, hash), 1<<20)
	manifest := currentRuntimeArchiveManifest()
	if err := writeRuntimeArchive(buffered, manifest, sources); err != nil {
		_ = file.Close()
		return RuntimeArchiveInfo{}, err
	}
	if err := buffered.Flush(); err != nil {
		_ = file.Close()
		return RuntimeArchiveInfo{}, err
	}
	if err := file.Close(); err != nil {
		return RuntimeArchiveInfo{}, err
	}
	if err := os.Chmod(file.Name(), 0o644); err != nil {
		return RuntimeArchiveInfo{}, err
	}
	// Release daemons refuse a larger download; never publish one. Verifying
	// the archive below applies the entry and expanded-size bounds.
	info, err := os.Stat(file.Name())
	if err != nil {
		return RuntimeArchiveInfo{}, err
	}
	if info.Size() > maxRuntimeArchiveBytes {
		return RuntimeArchiveInfo{}, fmt.Errorf("archive is %d bytes; release daemons download at most %d", info.Size(), maxRuntimeArchiveBytes)
	}

	home := filepath.Join(work, "verify")
	root := filepath.Join(home, "runtime", "harness")
	installed := filepath.Join(root, manifest.RuntimeDigest)
	if err := installRuntimeAtomically(ctx, root, installed, manifest.RuntimeDigest, func(_ context.Context, stage string) error {
		return extractRuntimeArchive(file.Name(), archiveHarnessTree, stage)
	}); err != nil {
		return RuntimeArchiveInfo{}, fmt.Errorf("verify the archive's harness runtime: %w", err)
	}
	bunBin, err := installArchiveBun(ctx, file.Name(), home)
	if err != nil {
		return RuntimeArchiveInfo{}, fmt.Errorf("verify the archive's managed Bun: %w", err)
	}
	agents, err := verifyRuntimeAgents(ctx, installed, bunBin, filepath.Join(work, "agent-home"))
	if err != nil {
		return RuntimeArchiveInfo{}, fmt.Errorf("verify the archive's agent CLIs: %w", err)
	}
	if err := os.Rename(file.Name(), output); err != nil {
		return RuntimeArchiveInfo{}, err
	}
	return RuntimeArchiveInfo{
		Path: output, Size: info.Size(), SHA256: hex.EncodeToString(hash.Sum(nil)), RuntimeDigest: manifest.RuntimeDigest, Agents: agents,
	}, nil
}

// verifyRuntimeAgents runs an installed runtime's own agent check with the
// managed Bun on PATH and a scratch HOME: every agent CLI and this platform's
// native package must be present and report the version package-lock.json
// pins. npm runs no install scripts, and none of these packages needs one.
func verifyRuntimeAgents(ctx context.Context, runtimeDir, bunBin, home string) (map[string]RuntimeAgent, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return nil, err
	}
	command := exec.CommandContext(ctx, "node", filepath.Join(runtimeDir, "verify-agents.mjs"))
	command.Dir = runtimeDir
	command.Env = make([]string, 0, len(os.Environ())+2)
	for _, item := range os.Environ() {
		if name, _, _ := strings.Cut(item, "="); name != "HOME" && name != "PATH" {
			command.Env = append(command.Env, item)
		}
	}
	command.Env = append(command.Env, "HOME="+home, "PATH="+bunBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		if message := strings.TrimSpace(stderr.String()); message != "" {
			return nil, errors.New(message)
		}
		return nil, err
	}
	var agents map[string]RuntimeAgent
	if err := json.Unmarshal(output, &agents); err != nil {
		return nil, fmt.Errorf("decode agent check: %w", err)
	}
	for _, agent := range runtimeAgents {
		if agents[agent].Version == "" || agents[agent].Native == "" {
			return nil, fmt.Errorf("agent check did not verify %s", agent)
		}
	}
	return agents, nil
}
