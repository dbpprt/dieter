package harness

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type runtimeManifest struct {
	Digest          string   `json:"digest"`
	ProtocolVersion string   `json:"protocolVersion"`
	SourceFiles     []string `json:"sourceFiles"`
	InstalledAt     string   `json:"installedAt"`
}

var requiredRuntimeFiles = []string{
	"runner.mjs",
	"package.json",
	"package-lock.json",
	"node_modules/@ai-sdk/harness/dist/index.js",
	"node_modules/@ai-sdk/harness-acp/dist/index.js",
	"node_modules/@ai-sdk/harness-claude-code/dist/index.js",
	"node_modules/@ai-sdk/harness-codex/dist/index.js",
	"node_modules/@ai-sdk/harness-pi/dist/index.js",
	"node_modules/@earendil-works/pi-coding-agent/dist/index.js",
}

func embeddedRuntimeSourceFiles() []string {
	entries, err := runtimeAssets.ReadDir("runtime")
	if err != nil {
		panic("read embedded harness runtime: " + err.Error())
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	return names
}

func runtimeSourceDigest(names []string, read func(string) ([]byte, error)) (string, error) {
	hash := sha256.New()
	for _, name := range names {
		contents, err := read(name)
		if err != nil {
			return "", fmt.Errorf("read %s: %w", name, err)
		}
		_, _ = hash.Write([]byte(name))
		_, _ = hash.Write([]byte{0})
		_, _ = hash.Write(contents)
		_, _ = hash.Write([]byte{0})
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func validateRuntimeDirectory(dir, digest string) error {
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("runtime path is not a real directory")
	}
	for _, name := range requiredRuntimeFiles {
		path := filepath.Join(dir, filepath.FromSlash(name))
		entry, statErr := os.Lstat(path)
		if statErr != nil {
			return fmt.Errorf("required runtime file %s: %w", name, statErr)
		}
		if !entry.Mode().IsRegular() || entry.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("required runtime file %s is not a regular file", name)
		}
	}
	marker, err := os.Lstat(filepath.Join(dir, ".installed"))
	if err != nil {
		return err
	}
	if !marker.Mode().IsRegular() || marker.Mode()&os.ModeSymlink != 0 {
		return errors.New("runtime installation marker is not a regular file")
	}
	rawManifest, err := os.ReadFile(filepath.Join(dir, ".installed"))
	if err != nil {
		return err
	}
	var manifest runtimeManifest
	if err := json.Unmarshal(rawManifest, &manifest); err != nil {
		return fmt.Errorf("decode runtime installation marker: %w", err)
	}
	if manifest.Digest != digest || manifest.ProtocolVersion != RuntimeProtocolVersion {
		return fmt.Errorf("runtime installation marker identifies digest %q protocol %q", manifest.Digest, manifest.ProtocolVersion)
	}
	if len(manifest.SourceFiles) == 0 || len(manifest.SourceFiles) > 128 {
		return errors.New("runtime installation marker has invalid source files")
	}
	for index, name := range manifest.SourceFiles {
		if name == "" || filepath.Base(name) != name || filepath.Clean(name) != name || (index > 0 && manifest.SourceFiles[index-1] >= name) {
			return errors.New("runtime installation marker has invalid source files")
		}
	}
	actual, err := runtimeSourceDigest(manifest.SourceFiles, func(name string) ([]byte, error) {
		return os.ReadFile(filepath.Join(dir, name))
	})
	if err != nil {
		return err
	}
	if actual != digest {
		return fmt.Errorf("runtime source digest is %s", actual)
	}
	return nil
}

func installRuntimeAtomically(ctx context.Context, root, finalDir, digest string) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return err
	}
	lock, err := acquireRuntimeInstallLock(ctx, filepath.Join(root, ".install-"+digest+".lock"))
	if err != nil {
		return fmt.Errorf("lock AI SDK harness runtime %s: %w", digest, err)
	}
	defer lock.Close()
	if err := validateRuntimeDirectory(finalDir, digest); err == nil {
		return nil
	}

	var quarantined string
	if _, err := os.Lstat(finalDir); err == nil {
		quarantined = filepath.Join(root, fmt.Sprintf(".corrupt-%s-%d-%d", digest, os.Getpid(), time.Now().UnixNano()))
		if err := os.Rename(finalDir, quarantined); err != nil {
			return fmt.Errorf("quarantine corrupt AI SDK harness runtime: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if quarantined != "" {
		defer os.RemoveAll(quarantined)
	}

	temporary, err := os.MkdirTemp(root, ".stage-"+digest+"-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	if err := os.Chmod(temporary, 0o700); err != nil {
		return err
	}
	if err := stageRuntimeAssets(temporary); err != nil {
		return fmt.Errorf("stage AI SDK harness runtime: %w", err)
	}
	command := exec.CommandContext(ctx, "npm", "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund")
	command.Dir = temporary
	output, installErr := command.CombinedOutput()
	if installErr != nil {
		return fmt.Errorf("install pinned AI SDK harness runtime: %s: %w", strings.TrimSpace(string(output)), installErr)
	}
	manifest, err := json.Marshal(runtimeManifest{
		Digest: digest, ProtocolVersion: RuntimeProtocolVersion, SourceFiles: embeddedRuntimeSourceFiles(), InstalledAt: time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return err
	}
	manifest = append(manifest, '\n')
	if err := writeSyncedRuntimeFile(filepath.Join(temporary, ".installed"), manifest); err != nil {
		return err
	}
	if err := validateRuntimeDirectory(temporary, digest); err != nil {
		return fmt.Errorf("validate installed AI SDK harness runtime: %w", err)
	}
	if err := syncRuntimeDirectory(temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, finalDir); err != nil {
		return fmt.Errorf("publish AI SDK harness runtime: %w", err)
	}
	if err := syncRuntimeDirectory(root); err != nil {
		return err
	}
	return nil
}

func writeSyncedRuntimeFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	return errors.Join(err, closeErr)
}

func syncRuntimeDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	err = directory.Sync()
	return errors.Join(err, directory.Close())
}
