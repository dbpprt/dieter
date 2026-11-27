package reviewer

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"
)

const gitCleanupTimeout = 30 * time.Second

// DefaultIgnoreGlobs are left out of every review: lock files, minified and
// generated code (after pr-agent's generated_code_ignore and ignore lists).
var DefaultIgnoreGlobs = []string{
	"package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
	"go.sum", "Cargo.lock", "poetry.lock", "uv.lock", "Pipfile.lock", "Gemfile.lock", "composer.lock",
	"mix.lock", "Podfile.lock", "Package.resolved", "gradle.lockfile", "*.lockfile",
	"*.min.js", "*.min.css", "*.map", "*.pb.go", "*_pb2.py", "*_pb2.pyi", "*.pb.swift", "*.grpc.swift",
	"*.connect.go", "*_grpc.pb.go", "*.snap", "**/__snapshots__/**", "**/node_modules/**", "**/vendor/**",
}

// sensitiveGlobs mark paths whose changes deserve a closer look (pr-agent's
// deterministic risk checks): CI, dependency manifests, infrastructure and
// database migrations.
var sensitiveGlobs = []string{
	".github/workflows/**", ".github/actions/**", ".gitlab-ci.yml", "Jenkinsfile*", ".circleci/**",
	"azure-pipelines*.yml", "*CODEOWNERS", "package.json", "requirements*.txt", "pyproject.toml",
	"Cargo.toml", "go.mod", "pom.xml", "build.gradle*", "Gemfile", "*Dockerfile*", "docker-compose*.y*ml",
	"*.tf", "*.tfvars", "**/migrations/**", "**/migrate/**",
}

// File is one changed file of the reviewed change.
type File struct {
	Path, OldPath string
	// Status is "added", "modified", "deleted" or "renamed".
	Status             string
	Additions, Removed int
	Binary             bool
	// Inlined is whether its diff is in the prompt.
	Inlined bool
}

// Change is the reviewed change: the files that remain after the ignore
// globs, and their diff rendered with new-side line numbers.
type Change struct {
	Base, Tree string
	Files      []File
	Ignored    []string
	Additions  int
	Deletions  int
	// Rendered is the inlined diff; files over the budget are listed but not
	// inlined.
	Rendered string
	// Truncated reports files left out of Rendered.
	Truncated bool
	// Sensitive lists changed paths that match the sensitive globs.
	Sensitive []string
	paths     map[string]bool
}

// HasFile reports whether path is a file of the change (deleted files
// included).
func (c Change) HasFile(file string) bool { return c.paths[file] }

// ReadChange reads the change from base to tree in repoDir, drops ignored
// files and renders at most budget bytes of diff.
func ReadChange(ctx context.Context, repoDir, base, tree string, ignore []string, budget int) (Change, error) {
	change := Change{Base: base, Tree: tree, paths: map[string]bool{}}
	numstat, err := git(ctx, repoDir, nil, nil, "diff", "--numstat", "-z", "--find-renames", "--no-ext-diff", base, tree)
	if err != nil {
		return change, fmt.Errorf("read the change: %w", err)
	}
	files := parseNumstat(numstat)
	globs := append(append([]string(nil), DefaultIgnoreGlobs...), ignore...)
	kept := make([]File, 0, len(files))
	for _, file := range files {
		if matchesAny(globs, file.Path) {
			change.Ignored = append(change.Ignored, file.Path)
			continue
		}
		kept = append(kept, file)
		change.paths[file.Path] = true
		change.Additions += file.Additions
		change.Deletions += file.Removed
		if matchesAny(sensitiveGlobs, file.Path) {
			change.Sensitive = append(change.Sensitive, file.Path)
		}
	}
	if len(kept) == 0 {
		change.Files = kept
		return change, nil
	}
	raw, err := git(ctx, repoDir, nil, nil, "diff", "--no-color", "--no-ext-diff", "--find-renames", "--unified=3", base, tree)
	if err != nil && !errors.Is(err, errTruncated) {
		return change, fmt.Errorf("read the diff: %w", err)
	}
	sections := splitDiff(raw)
	var rendered strings.Builder
	for index := range kept {
		file := &kept[index]
		section, ok := sections[file.Path]
		if !ok && file.OldPath != "" {
			section, ok = sections[file.OldPath]
		}
		if !ok || file.Binary {
			continue
		}
		text := renderFile(*file, section)
		if rendered.Len()+len(text) > budget {
			change.Truncated = true
			continue
		}
		file.Inlined = true
		rendered.WriteString(text)
	}
	change.Files, change.Rendered = kept, rendered.String()
	return change, nil
}

// parseNumstat reads `git diff --numstat -z`: "A\tD\tpath\0", or for a
// rename "A\tD\t\0old\0new\0"; binary files count "-".
func parseNumstat(raw []byte) []File {
	var files []File
	fields := bytes.Split(raw, []byte{0})
	for index := 0; index < len(fields); index++ {
		entry := string(fields[index])
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "\t", 3)
		if len(parts) != 3 {
			continue
		}
		file := File{Status: "modified"}
		if parts[0] == "-" || parts[1] == "-" {
			file.Binary = true
		} else {
			file.Additions, _ = strconv.Atoi(parts[0])
			file.Removed, _ = strconv.Atoi(parts[1])
		}
		if parts[2] == "" && index+2 < len(fields) {
			file.OldPath, file.Path, file.Status = string(fields[index+1]), string(fields[index+2]), "renamed"
			index += 2
		} else {
			file.Path = parts[2]
		}
		files = append(files, file)
	}
	return files
}

// splitDiff splits a unified diff into per-file sections keyed by the new
// path (the old path for deletions).
func splitDiff(raw []byte) map[string][]string {
	sections := map[string][]string{}
	var current []string
	flush := func() {
		if len(current) == 0 {
			return
		}
		key := ""
		for _, line := range current {
			if after, ok := strings.CutPrefix(line, "+++ b/"); ok {
				key = after
				break
			}
			if line == "+++ /dev/null" {
				for _, other := range current {
					if after, ok := strings.CutPrefix(other, "--- a/"); ok {
						key = after
					}
				}
				break
			}
		}
		if key == "" {
			// Renames without content changes and binary files have no +++ line.
			if fields := strings.Fields(current[0]); len(fields) >= 4 {
				key = strings.TrimPrefix(fields[len(fields)-1], "b/")
			}
		}
		if key != "" {
			sections[key] = current
		}
		current = nil
	}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 64*1024), 4<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "diff --git ") {
			flush()
		}
		current = append(current, line)
	}
	flush()
	return sections
}

// renderFile writes one file's hunks with the new-side line number in front
// of every context and added line, so findings can cite real lines.
func renderFile(file File, section []string) string {
	var out strings.Builder
	header := "## File: " + file.Path
	switch file.Status {
	case "renamed":
		header += " (renamed from " + file.OldPath + ")"
	}
	out.WriteString(header + "\n")
	newLine := 0
	inHunk := false
	for _, line := range section {
		if strings.HasPrefix(line, "@@") {
			inHunk = true
			newLine = hunkStart(line)
			out.WriteString(line + "\n")
			continue
		}
		if !inHunk {
			switch {
			case strings.HasPrefix(line, "new file mode"):
				out.WriteString("(new file)\n")
			case strings.HasPrefix(line, "deleted file mode"):
				out.WriteString("(deleted file)\n")
			}
			continue
		}
		switch {
		case strings.HasPrefix(line, "+"):
			fmt.Fprintf(&out, "%5d +%s\n", newLine, line[1:])
			newLine++
		case strings.HasPrefix(line, "-"):
			fmt.Fprintf(&out, "      -%s\n", line[1:])
		case strings.HasPrefix(line, "\\"):
			out.WriteString("      " + line + "\n")
		default:
			fmt.Fprintf(&out, "%5d  %s\n", newLine, strings.TrimPrefix(line, " "))
			newLine++
		}
	}
	out.WriteString("\n")
	return out.String()
}

// hunkStart reads the new-side start of "@@ -a,b +c,d @@".
func hunkStart(header string) int {
	plus := strings.Index(header, " +")
	if plus < 0 {
		return 1
	}
	rest := header[plus+2:]
	end := strings.IndexAny(rest, ", ")
	if end >= 0 {
		rest = rest[:end]
	}
	value, err := strconv.Atoi(rest)
	if err != nil {
		return 1
	}
	return value
}

func matchesAny(globs []string, file string) bool {
	for _, glob := range globs {
		if matchGlob(glob, file) {
			return true
		}
	}
	return false
}

// matchGlob matches a repository-relative path: a glob without a slash
// matches the base name anywhere; one with slashes matches the whole path,
// where ** spans any number of directories.
func matchGlob(glob, file string) bool {
	glob = strings.TrimPrefix(glob, "./")
	if !strings.Contains(glob, "/") {
		ok, _ := path.Match(glob, path.Base(file))
		return ok
	}
	return matchSegments(strings.Split(glob, "/"), strings.Split(file, "/"))
}

func matchSegments(glob, parts []string) bool {
	for len(glob) > 0 {
		if glob[0] == "**" {
			if len(glob) == 1 {
				return true
			}
			for skip := 0; skip <= len(parts); skip++ {
				if matchSegments(glob[1:], parts[skip:]) {
					return true
				}
			}
			return false
		}
		if len(parts) == 0 {
			return false
		}
		if ok, _ := path.Match(glob[0], parts[0]); !ok {
			return false
		}
		glob, parts = glob[1:], parts[1:]
	}
	return len(parts) == 0
}
