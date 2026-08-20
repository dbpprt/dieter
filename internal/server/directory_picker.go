package server

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type projectDirectoryEntry struct {
	Name          string `json:"name"`
	Path          string `json:"path"`
	GitRepository bool   `json:"gitRepository"`
	Hidden        bool   `json:"hidden"`
}

type projectDirectoryLocation struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Kind string `json:"kind"`
}

type projectDirectoryListing struct {
	Path          string                     `json:"path"`
	Parent        string                     `json:"parent,omitempty"`
	Name          string                     `json:"name"`
	GitRepository bool                       `json:"gitRepository"`
	Separator     string                     `json:"separator"`
	Entries       []projectDirectoryEntry    `json:"entries"`
	Locations     []projectDirectoryLocation `json:"locations"`
}

func listProjectDirectories(requested string) (projectDirectoryListing, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return projectDirectoryListing{}, err
	}
	path := strings.TrimSpace(requested)
	if path == "" {
		path = home
	} else if path == "~" || strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`) {
		path = filepath.Join(home, strings.TrimLeft(path[1:], `/\`))
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return projectDirectoryListing{}, err
	}
	path = filepath.Clean(path)
	info, err := os.Stat(path)
	if err != nil {
		return projectDirectoryListing{}, fmtDirectoryError(path, err)
	}
	if !info.IsDir() {
		return projectDirectoryListing{}, errors.New("selected path is not a directory")
	}

	items, err := os.ReadDir(path)
	if err != nil {
		return projectDirectoryListing{}, fmtDirectoryError(path, err)
	}
	entries := make([]projectDirectoryEntry, 0, len(items))
	for _, item := range items {
		child := filepath.Join(path, item.Name())
		isDirectory := item.IsDir()
		if !isDirectory && item.Type()&os.ModeSymlink != 0 {
			childInfo, statErr := os.Stat(child)
			isDirectory = statErr == nil && childInfo.IsDir()
		}
		if !isDirectory {
			continue
		}
		entries = append(entries, projectDirectoryEntry{
			Name:          item.Name(),
			Path:          child,
			GitRepository: isGitWorkingTree(child),
			Hidden:        strings.HasPrefix(item.Name(), "."),
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})

	parent := filepath.Dir(path)
	if parent == path {
		parent = ""
	}
	name := filepath.Base(path)
	if name == string(filepath.Separator) || name == "." {
		name = path
	}
	return projectDirectoryListing{
		Path:          path,
		Parent:        parent,
		Name:          name,
		GitRepository: isGitWorkingTree(path),
		Separator:     string(filepath.Separator),
		Entries:       entries,
		Locations:     projectDirectoryLocations(home),
	}, nil
}

func fmtDirectoryError(path string, err error) error {
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("directory does not exist: " + path)
	}
	if errors.Is(err, os.ErrPermission) {
		return os.ErrPermission
	}
	return err
}

func isGitWorkingTree(path string) bool {
	_, err := os.Stat(filepath.Join(path, ".git"))
	return err == nil
}

func projectDirectoryLocations(home string) []projectDirectoryLocation {
	locations := []projectDirectoryLocation{{Name: "Home", Path: home, Kind: "home"}}
	seen := map[string]bool{home: true}
	for _, candidate := range []struct{ name, path, kind string }{
		{"Development", filepath.Join(home, "Development"), "code"},
		{"Projects", filepath.Join(home, "Projects"), "code"},
		{"Documents", filepath.Join(home, "Documents"), "folder"},
		{"Desktop", filepath.Join(home, "Desktop"), "folder"},
		{"Computer", filepath.VolumeName(home) + string(filepath.Separator), "computer"},
	} {
		path := filepath.Clean(candidate.path)
		if seen[path] {
			continue
		}
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			continue
		}
		seen[path] = true
		locations = append(locations, projectDirectoryLocation{Name: candidate.name, Path: path, Kind: candidate.kind})
	}
	return locations
}
