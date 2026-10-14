package filetransfer

import (
	"fmt"
	"path"
	"sort"
	"strings"
)

const MaxEntries = 100000

type Rule struct {
	Pattern string
	Include bool
}

func (r Rule) Validate() error {
	_, err := path.Match(strings.ReplaceAll(r.Pattern, "/", "\x01"), "")
	return err
}
func Included(name string, rules []Rule) bool {
	included := true
	for _, r := range rules {
		pattern := strings.ReplaceAll(r.Pattern, "/", "\x01")
		n := strings.ReplaceAll(name, "/", "\x01")
		match, _ := path.Match(pattern, n)
		if match {
			included = r.Include
		}
	}
	return included
}

type PlanOptions struct {
	Sync, Delete, Checksum, SizeOnly, NoClobber bool
	Rules                                       []Rule
}
type Action struct {
	Kind        string `json:"action"`
	Path        string `json:"path"`
	Source      Entry  `json:"-"`
	Destination Entry  `json:"-"`
}

// Plan is pure: the exact same action list drives dry runs and execution.
func Plan(source, destination map[string]Entry, options PlanOptions) ([]Action, error) {
	names := make([]string, 0, len(source)+len(destination))
	for n := range source {
		names = append(names, n)
	}
	for n := range destination {
		if _, ok := source[n]; !ok {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	actions := make([]Action, 0, len(names))
	for _, n := range names {
		if !Included(n, options.Rules) {
			continue
		}
		s, hasSource := source[n]
		d, hasDest := destination[n]
		if hasSource && s.Kind != "file" && s.Kind != "directory" || hasDest && d.Kind != "file" && d.Kind != "directory" {
			return nil, fmt.Errorf("unsupported file type: %s", n)
		}
		if hasSource && hasDest && s.Kind != d.Kind {
			return nil, fmt.Errorf("file/directory conflict: %s", n)
		}
		if hasSource && s.Kind == "directory" {
			continue
		}
		if !hasSource {
			if options.Delete && d.Kind == "file" {
				actions = append(actions, Action{Kind: "delete", Path: n, Destination: d})
			}
			continue
		}
		if !hasDest {
			d = Entry{Kind: Missing, Revision: Missing}
		}
		kind := "copy"
		if hasDest && options.NoClobber {
			kind = "skip"
		} else if options.Sync && hasDest && s.Size == d.Size {
			if options.SizeOnly || options.Checksum && s.SHA256 == d.SHA256 || !options.Checksum && s.Modified == d.Modified {
				kind = "skip"
			}
		}
		actions = append(actions, Action{Kind: kind, Path: n, Source: s, Destination: d})
	}
	return actions, nil
}
