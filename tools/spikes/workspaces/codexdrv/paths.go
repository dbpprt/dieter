package codexdrv

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"dieter.spike/workspaces/core"
)

// relativizer maps paths Codex reports onto keys relative to the working
// directory. It knows every spelling of the root: as given, fully resolved,
// as Codex echoed it, and the macOS /private <-> /tmp, /var, /etc aliases.
type relativizer struct {
	roots []string // longest first
}

func newRelativizer(dirs ...string) *relativizer {
	set := map[string]bool{}
	for _, d := range dirs {
		if d == "" || !filepath.IsAbs(d) {
			continue
		}
		for _, v := range spellings(filepath.Clean(d)) {
			set[v] = true
		}
		if r, err := filepath.EvalSymlinks(d); err == nil {
			for _, v := range spellings(r) {
				set[v] = true
			}
		}
	}
	r := &relativizer{}
	for d := range set {
		r.roots = append(r.roots, d)
	}
	sort.Slice(r.roots, func(i, j int) bool {
		if len(r.roots[i]) != len(r.roots[j]) {
			return len(r.roots[i]) > len(r.roots[j])
		}
		return r.roots[i] < r.roots[j]
	})
	return r
}

// spellings returns p plus its macOS /private alias, if any.
func spellings(p string) []string {
	out := []string{p}
	if rest, ok := strings.CutPrefix(p, "/private"); ok && (strings.HasPrefix(rest, "/tmp") || strings.HasPrefix(rest, "/var") || strings.HasPrefix(rest, "/etc")) {
		out = append(out, rest)
	}
	for _, top := range []string{"/tmp", "/var", "/etc"} {
		if p == top || strings.HasPrefix(p, top+"/") {
			out = append(out, "/private"+p)
		}
	}
	return out
}

// rel returns the normalized key for p and whether p lies inside the root.
// Relative paths are taken as relative to the root (Codex's cwd). Paths
// outside the root are returned absolute, normalized.
func (r *relativizer) rel(p string) (string, bool) {
	if p == "" {
		return "", false
	}
	if !filepath.IsAbs(p) {
		c := filepath.Clean(p)
		if c == ".." || strings.HasPrefix(c, "../") {
			return core.NormPath(c), false
		}
		return core.NormPath(c), true
	}
	// The resolved spelling wins: a write through a symlinked directory
	// changes the file under its real path.
	c := filepath.Clean(p)
	var cands []string
	if resolved := resolveParent(c); resolved != c {
		cands = spellings(resolved)
	}
	cands = append(cands, spellings(c)...)
	for _, cand := range cands {
		for _, root := range r.roots {
			if rest, ok := strings.CutPrefix(cand, root+"/"); ok && rest != "" {
				return core.NormPath(rest), true
			}
		}
	}
	return core.NormPath(c), false
}

// resolveParent resolves symlinks in p's directory part (never the final
// component: a reported symlink stays itself). Missing trailing directories
// (for example of a deleted file) are kept as written.
func resolveParent(p string) string {
	dir, base := filepath.Split(p)
	dir = filepath.Clean(dir)
	var tail []string
	for {
		if r, err := filepath.EvalSymlinks(dir); err == nil {
			parts := append([]string{r}, tail...)
			return filepath.Join(append(parts, base)...)
		}
		if _, err := os.Lstat(dir); err == nil {
			return p // exists but unresolvable; keep as is
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return p
		}
		tail = append([]string{filepath.Base(dir)}, tail...)
		dir = parent
	}
}
