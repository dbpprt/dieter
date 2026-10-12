package api

import (
	"context"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *filesAPI) ListFiles(ctx context.Context, request *dieterv1.ListFilesRequest) (*dieterv1.FileList, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	api.server.filesMu.RLock()
	defer api.server.filesMu.RUnlock()
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	relative, err := cleanProjectPath(request.GetPath(), true)
	if err != nil {
		return nil, err
	}
	root, target, err := existingProjectPath(project, relative)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(target)
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	if !info.IsDir() {
		return nil, fault.Errorf(fault.Invalid, "%q is not a directory", relative)
	}
	items, err := os.ReadDir(target)
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	entries := make([]projectFileEntry, 0, len(items))
	for _, item := range items {
		if item.Name() == ".git" {
			continue
		}
		logicalPath := path.Join(relative, item.Name())
		entry, entryErr := projectEntry(root, logicalPath, filepath.Join(target, item.Name()), item)
		if entryErr != nil || entry.Hidden && !request.GetShowHidden() {
			continue
		}
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Kind != entries[j].Kind {
			return entries[i].Kind == "directory"
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	result := &dieterv1.FileList{Path: relative}
	for _, entry := range entries {
		result.Entries = append(result.Entries, &dieterv1.FileEntry{
			Name: entry.Name, Path: entry.Path, Kind: entry.Kind, Size: entry.Size,
			ModifiedAt: entry.ModifiedAt, Hidden: entry.Hidden, Symlink: entry.Symlink,
		})
	}
	return result, nil
}

func (api *filesAPI) ReadFile(ctx context.Context, request *dieterv1.ReadFileRequest) (*dieterv1.FileDocument, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	api.server.filesMu.RLock()
	defer api.server.filesMu.RUnlock()
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	relative, err := cleanProjectPath(request.GetPath(), false)
	if err != nil {
		return nil, err
	}
	_, target, err := existingProjectPath(project, relative)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(target)
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fault.Errorf(fault.Invalid, "%q is not a regular file", relative)
	}
	content, err := readLimitedProjectFile(target)
	if err != nil {
		return nil, err
	}
	binary := !utf8.Valid(content) || containsNUL(content)
	result := &dieterv1.FileDocument{
		Path: relative, Name: path.Base(relative), Binary: binary, Size: info.Size(),
		ModifiedAt: info.ModTime().UTC().Format(projectTimeFormat),
		Revision:   projectFileRevision(content), MimeType: mime.TypeByExtension(strings.ToLower(filepath.Ext(target))),
	}
	if binary {
		result.Data = content
	} else {
		result.Content = string(content)
	}
	return result, nil
}

func (api *filesAPI) SaveFile(ctx context.Context, request *dieterv1.SaveFileRequest) (*dieterv1.FileDocument, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	api.server.filesMu.Lock()
	defer api.server.filesMu.Unlock()
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	relative, err := cleanProjectPath(request.GetPath(), false)
	if err != nil {
		return nil, err
	}
	root, target, err := existingProjectPath(project, relative)
	if err != nil {
		return nil, err
	}
	if err := ensureNonSymlinkRegular(target, relative); err != nil {
		return nil, err
	}
	current, err := readLimitedProjectFile(target)
	if err != nil {
		return nil, err
	}
	if request.GetRevision() == "" || request.GetRevision() != projectFileRevision(current) {
		return nil, fileError(http.StatusConflict, "%q changed on disk; reload it before saving", relative)
	}
	content := []byte(request.GetContent())
	if len(content) > maxProjectFileSize {
		return nil, fileError(http.StatusRequestEntityTooLarge, "file exceeds the %d MiB editor limit", maxProjectFileSize>>20)
	}
	if err := ensureContained(root, target); err != nil {
		return nil, err
	}
	if err := atomicWriteProjectFile(target, content); err != nil {
		return nil, projectPathIOError(relative, err)
	}
	api.server.changesets.InvalidatePath(project.Path)
	info, err := os.Stat(target)
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	return &dieterv1.FileDocument{
		Path: relative, Name: path.Base(relative), Size: int64(len(content)),
		ModifiedAt: info.ModTime().UTC().Format(projectTimeFormat), Revision: projectFileRevision(content),
		Content: request.GetContent(),
	}, nil
}

func (api *filesAPI) CreateFile(ctx context.Context, request *dieterv1.CreateFileRequest) (*dieterv1.FileEntry, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	api.server.filesMu.Lock()
	defer api.server.filesMu.Unlock()
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	relative, err := cleanProjectPath(request.GetPath(), false)
	if err != nil {
		return nil, err
	}
	_, target, err := newProjectPath(project, relative)
	if err != nil {
		return nil, err
	}
	kind := request.GetKind()
	if kind != "file" && kind != "directory" {
		return nil, fault.New(fault.Invalid, "kind must be file or directory")
	}
	content := []byte(request.GetContent())
	if len(content) > maxProjectFileSize {
		return nil, fileError(http.StatusRequestEntityTooLarge, "file exceeds the %d MiB editor limit", maxProjectFileSize>>20)
	}
	if kind == "directory" {
		err = os.Mkdir(target, 0o755)
	} else {
		err = atomicCreateProjectFile(target, content)
	}
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	api.server.changesets.InvalidatePath(project.Path)
	return &dieterv1.FileEntry{Name: path.Base(relative), Path: relative, Kind: kind, Size: int64(len(content))}, nil
}

func (api *filesAPI) MoveFile(ctx context.Context, request *dieterv1.MoveFileRequest) (*dieterv1.MoveFileResponse, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	api.server.filesMu.Lock()
	defer api.server.filesMu.Unlock()
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	sourceRelative, err := cleanProjectPath(request.GetSource(), false)
	if err != nil {
		return nil, err
	}
	destinationRelative, err := cleanProjectPath(request.GetDestination(), false)
	if err != nil {
		return nil, err
	}
	_, source, err := existingProjectPathNoFollow(project, sourceRelative)
	if err != nil {
		return nil, err
	}
	_, destination, err := newProjectPath(project, destinationRelative)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(source)
	if err != nil {
		return nil, projectPathIOError(sourceRelative, err)
	}
	if info.IsDir() && (destinationRelative == sourceRelative || strings.HasPrefix(destinationRelative, sourceRelative+"/")) {
		return nil, fault.New(fault.Invalid, "a directory cannot be moved inside itself")
	}
	if err := os.Rename(source, destination); err != nil {
		return nil, projectPathIOError(sourceRelative, err)
	}
	api.server.changesets.InvalidatePath(project.Path)
	return &dieterv1.MoveFileResponse{Source: sourceRelative, Destination: destinationRelative}, nil
}

func (api *filesAPI) DeleteFile(ctx context.Context, request *dieterv1.DeleteFileRequest) (*emptypb.Empty, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	api.server.filesMu.Lock()
	defer api.server.filesMu.Unlock()
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	relative, err := cleanProjectPath(request.GetPath(), false)
	if err != nil {
		return nil, err
	}
	_, target, err := existingProjectPathNoFollow(project, relative)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(target)
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	if info.IsDir() {
		if !request.GetRecursive() {
			return nil, fault.New(fault.Invalid, "deleting a directory requires recursive=true")
		}
		err = os.RemoveAll(target)
	} else {
		err = os.Remove(target)
	}
	if err != nil {
		return nil, projectPathIOError(relative, err)
	}
	api.server.changesets.InvalidatePath(project.Path)
	return &emptypb.Empty{}, nil
}
