package codexdrv

import (
	"sort"
	"strconv"
	"strings"
)

// ParseUnifiedDiffPaths returns the sorted, de-duplicated file paths a
// unified diff touches. It understands git headers (diff --git, rename/copy
// from/to, quoted C-style paths), plain ---/+++ headers with trailing
// timestamps, and /dev/null for added or deleted files. Hunk bodies are
// skipped by line count, so content lines that start with "--- " are never
// taken for headers. The a/ and b/ prefixes are removed; paths are returned
// as written (relative to the diff's root, or absolute).
func ParseUnifiedDiffPaths(diff string) []string {
	seen := map[string]bool{}
	add := func(p string) {
		if p != "" && p != "/dev/null" {
			seen[p] = true
		}
	}
	var (
		git          bool // current section started with diff --git
		oldN, newN   int  // hunk lines still expected on each side
		minus        string
		haveMinus    bool
		strip        = func(p, prefix string) string { return strings.TrimPrefix(p, prefix) }
		plainStripOK = func(o, n string) bool {
			okOld := o == "/dev/null" || strings.HasPrefix(o, "a/")
			okNew := n == "/dev/null" || strings.HasPrefix(n, "b/")
			return okOld && okNew
		}
	)
	for _, line := range strings.Split(diff, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if oldN > 0 || newN > 0 {
			switch {
			case line == "" || line[0] == ' ':
				oldN--
				newN--
				continue
			case line[0] == '-':
				oldN--
				continue
			case line[0] == '+':
				newN--
				continue
			case line[0] == '\\':
				continue
			}
			oldN, newN = 0, 0 // malformed hunk: treat this line as a header
		}
		switch {
		case strings.HasPrefix(line, "diff --git "):
			git = true
			haveMinus = false
			if a, b, ok := splitGitHeader(line[len("diff --git "):]); ok {
				add(strip(a, "a/"))
				add(strip(b, "b/"))
			}
		case strings.HasPrefix(line, "diff --cc "), strings.HasPrefix(line, "diff --combined "):
			git = true
			haveMinus = false
			_, p, _ := strings.Cut(line[len("diff --"):], " ")
			add(headerPath(p))
		case strings.HasPrefix(line, "diff "):
			git = false // plain "diff -u old new" section
			haveMinus = false
		case strings.HasPrefix(line, "--- "):
			minus, haveMinus = headerPath(line[4:]), true
		case strings.HasPrefix(line, "+++ ") && haveMinus:
			plus := headerPath(line[4:])
			haveMinus = false
			if git || plainStripOK(minus, plus) {
				add(strip(minus, "a/"))
				add(strip(plus, "b/"))
			} else {
				add(minus)
				add(plus)
			}
		case strings.HasPrefix(line, "rename from "), strings.HasPrefix(line, "copy from "):
			add(headerPath(line[strings.Index(line, " from ")+6:]))
		case strings.HasPrefix(line, "rename to "), strings.HasPrefix(line, "copy to "):
			add(headerPath(line[strings.Index(line, " to ")+4:]))
		case strings.HasPrefix(line, "@@ "):
			oldN, newN = hunkCounts(line)
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// headerPath reads one path from a ---/+++/rename header: a C-quoted path, or
// everything up to an optional tab (GNU diff appends "\t<timestamp>").
func headerPath(s string) string {
	if strings.HasPrefix(s, `"`) {
		if v, n := unquoteC(s); n > 0 {
			return v
		}
	}
	if i := strings.IndexByte(s, '\t'); i >= 0 {
		s = s[:i]
	}
	return s
}

// splitGitHeader splits "a/X b/Y" from a diff --git line, honouring quotes.
// Unquoted names may contain spaces; they are split where both sides name
// the same path, or at the only " b/" when that is unambiguous.
func splitGitHeader(rest string) (string, string, bool) {
	if strings.HasPrefix(rest, `"`) {
		a, n := unquoteC(rest)
		if n == 0 || n >= len(rest) || rest[n] != ' ' {
			return "", "", false
		}
		return a, headerPath(rest[n+1:]), true
	}
	if strings.HasSuffix(rest, `"`) {
		if i := strings.Index(rest, ` "`); i >= 0 {
			b, n := unquoteC(rest[i+1:])
			if n > 0 {
				return rest[:i], b, true
			}
		}
	}
	for i := 0; i < len(rest); i++ {
		if rest[i] != ' ' {
			continue
		}
		l, r := rest[:i], rest[i+1:]
		if strings.HasPrefix(l, "a/") && strings.HasPrefix(r, "b/") && l[2:] == r[2:] {
			return l, r, true
		}
	}
	if strings.Count(rest, " b/") == 1 {
		i := strings.Index(rest, " b/")
		return rest[:i], rest[i+1:], true
	}
	return "", "", false
}

// unquoteC decodes a git C-style quoted string at the start of s. It returns
// the value and the number of bytes consumed (0 when s is not a complete
// quoted string).
func unquoteC(s string) (string, int) {
	if !strings.HasPrefix(s, `"`) {
		return "", 0
	}
	var b []byte
	for i := 1; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			return string(b), i + 1
		case '\\':
			if i+1 >= len(s) {
				return "", 0
			}
			i++
			switch e := s[i]; e {
			case 'a':
				b = append(b, '\a')
			case 'b':
				b = append(b, '\b')
			case 'f':
				b = append(b, '\f')
			case 'n':
				b = append(b, '\n')
			case 'r':
				b = append(b, '\r')
			case 't':
				b = append(b, '\t')
			case 'v':
				b = append(b, '\v')
			case '0', '1', '2', '3':
				if i+2 < len(s) {
					if v, err := strconv.ParseUint(s[i:i+3], 8, 8); err == nil {
						b = append(b, byte(v))
						i += 2
						continue
					}
				}
				b = append(b, e)
			default:
				b = append(b, e)
			}
		default:
			b = append(b, c)
		}
	}
	return "", 0
}

// hunkCounts parses "@@ -l[,n] +l[,n] @@"; an omitted count means 1.
func hunkCounts(line string) (int, int) {
	f := strings.Fields(line)
	if len(f) < 3 {
		return 0, 0
	}
	count := func(r string) int {
		if _, n, ok := strings.Cut(r[1:], ","); ok {
			v, err := strconv.Atoi(n)
			if err != nil {
				return 0
			}
			return v
		}
		return 1
	}
	if !strings.HasPrefix(f[1], "-") || !strings.HasPrefix(f[2], "+") {
		return 0, 0
	}
	return count(f[1]), count(f[2])
}
