package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

const maxProjectFileSize = 5 << 20
const projectTimeFormat = "2006-01-02T15:04:05.999999999Z07:00"

func (s *Server) scopedProject(ctx context.Context, projectID, cardID string) (model.Project, error) {
	cardID = strings.TrimSpace(cardID)
	if cardID == "" {
		return s.store.ResolveProject(strings.TrimSpace(projectID))
	}
	card, err := s.store.ResolveCard(cardID)
	if err != nil {
		return model.Project{}, err
	}
	if projectID != "" && strings.TrimSpace(projectID) != card.ProjectID {
		return model.Project{}, errors.New("card does not belong to the requested project")
	}
	value, err := s.workspaces.Ensure(ctx, card.ID)
	if err != nil {
		return model.Project{}, err
	}
	project, err := s.store.ResolveProject(card.ProjectID)
	if err != nil {
		return model.Project{}, err
	}
	project.Path = value.Path
	return project, nil
}

type projectFileEntry struct {
	Name       string
	Path       string
	Kind       string
	Size       int64
	ModifiedAt string
	Hidden     bool
	Symlink    bool
}

type projectFileError struct {
	status  int
	message string
}

func (err *projectFileError) Error() string { return err.message }

func fileError(status int, format string, args ...any) error {
	return &projectFileError{status: status, message: fmt.Sprintf(format, args...)}
}

func cleanProjectPath(value string, allowRoot bool) (string, error) {
	if strings.ContainsRune(value, '\x00') || strings.Contains(value, "\\") || strings.HasPrefix(value, "/") || filepath.IsAbs(value) {
		return "", fileError(http.StatusBadRequest, "project file path must be relative")
	}
	cleaned := path.Clean(value)
	if cleaned == "." {
		if allowRoot && (value == "" || value == ".") {
			return "", nil
		}
		return "", fileError(http.StatusBadRequest, "project file path is required")
	}
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", fileError(http.StatusBadRequest, "project file path cannot leave the project")
	}
	for _, segment := range strings.Split(cleaned, "/") {
		if segment == ".git" {
			return "", fileError(http.StatusForbidden, ".git is protected")
		}
	}
	return cleaned, nil
}

func projectRoot(project model.Project) (string, error) {
	root, err := filepath.EvalSymlinks(project.Path)
	if err != nil {
		return "", projectPathIOError("project root", err)
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(root)
	if err != nil {
		return "", projectPathIOError("project root", err)
	}
	if !info.IsDir() {
		return "", fileError(http.StatusBadRequest, "project root is not a directory")
	}
	return root, nil
}

func existingProjectPath(project model.Project, relative string) (string, string, error) {
	root, err := projectRoot(project)
	if err != nil {
		return "", "", err
	}
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", "", projectPathIOError(relative, err)
	}
	if err := ensureContained(root, resolved); err != nil {
		return "", "", err
	}
	return root, candidate, nil
}

func existingProjectPathNoFollow(project model.Project, relative string) (string, string, error) {
	root, err := projectRoot(project)
	if err != nil {
		return "", "", err
	}
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	if err := ensureContained(root, candidate); err != nil {
		return "", "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(candidate))
	if err != nil {
		return "", "", projectPathIOError(path.Dir(relative), err)
	}
	if err := ensureContained(root, parent); err != nil {
		return "", "", err
	}
	if _, err := os.Lstat(candidate); err != nil {
		return "", "", projectPathIOError(relative, err)
	}
	return root, candidate, nil
}

func newProjectPath(project model.Project, relative string) (string, string, error) {
	root, err := projectRoot(project)
	if err != nil {
		return "", "", err
	}
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	if err := ensureContained(root, candidate); err != nil {
		return "", "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(candidate))
	if err != nil {
		return "", "", projectPathIOError(path.Dir(relative), err)
	}
	if err := ensureContained(root, parent); err != nil {
		return "", "", err
	}
	if _, err := os.Lstat(candidate); err == nil {
		return "", "", fileError(http.StatusConflict, "%q already exists", relative)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", "", projectPathIOError(relative, err)
	}
	return root, candidate, nil
}

func ensureContained(root, target string) error {
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fileError(http.StatusForbidden, "project file path leaves the project root")
	}
	return nil
}

func ensureNonSymlinkRegular(target, relative string) error {
	info, err := os.Lstat(target)
	if err != nil {
		return projectPathIOError(relative, err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fileError(http.StatusForbidden, "saving through symlinks is not allowed")
	}
	if !info.Mode().IsRegular() {
		return fileError(http.StatusBadRequest, "%q is not a regular file", relative)
	}
	return nil
}

func projectEntry(root, relative, target string, item fs.DirEntry) (projectFileEntry, error) {
	linkInfo, err := item.Info()
	if err != nil {
		return projectFileEntry{}, err
	}
	symlink := item.Type()&os.ModeSymlink != 0
	if symlink {
		resolved, resolveErr := filepath.EvalSymlinks(target)
		targetInfo, statErr := os.Stat(target)
		if resolveErr == nil && statErr == nil && ensureContained(root, resolved) == nil {
			linkInfo = targetInfo
		}
	}
	kind := "file"
	if linkInfo.IsDir() {
		kind = "directory"
	}
	entry := projectFileEntry{
		Name: item.Name(), Path: relative, Kind: kind, Hidden: strings.HasPrefix(item.Name(), "."),
		Symlink: symlink, ModifiedAt: linkInfo.ModTime().UTC().Format(projectTimeFormat),
	}
	if kind == "file" {
		entry.Size = linkInfo.Size()
	}
	return entry, nil
}

func readLimitedProjectFile(target string) ([]byte, error) {
	file, err := os.Open(target)
	if err != nil {
		return nil, projectPathIOError(path.Base(target), err)
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, maxProjectFileSize+1))
	if err != nil {
		return nil, err
	}
	if len(content) > maxProjectFileSize {
		return nil, fileError(http.StatusRequestEntityTooLarge, "file exceeds the %d MiB editor limit", maxProjectFileSize>>20)
	}
	return content, nil
}

func containsNUL(content []byte) bool {
	for _, value := range content {
		if value == 0 {
			return true
		}
	}
	return false
}

func projectFileRevision(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

func atomicWriteProjectFile(target string, content []byte) error {
	info, err := os.Stat(target)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(target), ".dieter-save-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	closed := false
	defer func() {
		if !closed {
			_ = temporary.Close()
		}
		_ = os.Remove(temporaryPath)
	}()
	if err := temporary.Chmod(info.Mode().Perm()); err != nil {
		return err
	}
	if _, err := temporary.Write(content); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	closed = true
	return os.Rename(temporaryPath, target)
}

func atomicCreateProjectFile(target string, content []byte) error {
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := file.Write(content); err != nil {
		_ = file.Close()
		_ = os.Remove(target)
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		_ = os.Remove(target)
		return err
	}
	return file.Close()
}

func projectPathIOError(relative string, err error) error {
	status := http.StatusBadRequest
	if errors.Is(err, fs.ErrNotExist) {
		status = http.StatusNotFound
	} else if errors.Is(err, fs.ErrPermission) {
		status = http.StatusForbidden
	} else if errors.Is(err, fs.ErrExist) {
		status = http.StatusConflict
	}
	if relative == "" {
		relative = "."
	}
	return fileError(status, "%q: %v", relative, err)
}
