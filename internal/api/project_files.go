package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

const maxProjectFileSize = 5 << 20
const projectTimeFormat = "2006-01-02T15:04:05.999999999Z07:00"

func (s *Server) scopedProject(ctx context.Context, projectID, cardID string) (model.Project, error) {
	cardID = strings.TrimSpace(cardID)
	if cardID == "" {
		return s.store.Kanban.ProjectForCheckout(strings.TrimSpace(projectID), kanban.CheckoutFromContext(ctx))
	}
	card, err := s.store.Kanban.ResolveCard(cardID)
	if err != nil {
		return model.Project{}, err
	}
	if projectID != "" && strings.TrimSpace(projectID) != card.ProjectID {
		return model.Project{}, fault.New(fault.Invalid, "card does not belong to the requested project")
	}
	if err = s.store.Kanban.RequireLocalCard(card); err != nil {
		return model.Project{}, err
	}
	if checkout := kanban.CheckoutFromContext(ctx); checkout != "" && checkout != card.CheckoutID {
		return model.Project{}, fault.New(fault.Invalid, "checkout does not match conversation")
	}
	value, err := s.workspaces.Ensure(ctx, card.ID)
	if err != nil {
		return model.Project{}, err
	}
	project, err := s.store.Kanban.ResolveProject(card.ProjectID)
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

// atomicWriteProjectFile replaces an existing project file, preserving its
// permissions.
func atomicWriteProjectFile(target string, content []byte) error {
	info, err := os.Stat(target)
	if err != nil {
		return err
	}
	return fsx.WriteFile(target, content, info.Mode().Perm())
}

// atomicCreateProjectFile publishes a new project file and fails when one
// already exists. It never creates missing parent directories in a project.
func atomicCreateProjectFile(target string, content []byte) error {
	if _, err := os.Stat(filepath.Dir(target)); err != nil {
		return err
	}
	return fsx.CreateFile(target, content, 0o644)
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
