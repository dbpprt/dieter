package folders

import (
	"path"
	"slices"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// MaxRules bounds a folder's rules (the shared `strings` field cap).
const MaxRules = 64

// DefaultRules exclude operating system and editor droppings at any depth.
var DefaultRules = []string{
	"-.DS_Store", "-*/.DS_Store", "-._*", "-*/._*", "-Thumbs.db", "-*/Thumbs.db",
	"-desktop.ini", "-*/desktop.ini", "-~$*", "-*/~$*", "-*.tmp", "-*.swp",
}

// Rule is one parsed rule: "+PATTERN" includes, "-PATTERN" excludes.
// Patterns use Go's path.Match syntax where '*' also matches '/'.
type Rule struct {
	Pattern string
	Include bool
}

// ParseRules parses and validates rules.
func ParseRules(values []string) ([]Rule, error) {
	if len(values) > MaxRules {
		return nil, fault.New(fault.ResourceExhausted, "a folder has at most 64 rules")
	}
	rules := make([]Rule, 0, len(values))
	for _, value := range values {
		if len(value) < 2 || len(value) > 512 || value[0] != '+' && value[0] != '-' {
			return nil, fault.Invalidf("a rule is +PATTERN or -PATTERN: %q", value)
		}
		rule := Rule{Pattern: value[1:], Include: value[0] == '+'}
		if _, err := path.Match(slashless(rule.Pattern), ""); err != nil {
			return nil, fault.Invalidf("invalid rule pattern %q", rule.Pattern)
		}
		rules = append(rules, rule)
	}
	return rules, nil
}

func slashless(s string) string { return strings.ReplaceAll(s, "/", "\x01") }

// matches applies rules to one path; the last matching rule wins.
func matches(p string, rules []Rule) bool {
	included := true
	name := slashless(p)
	for _, rule := range rules {
		if ok, _ := path.Match(slashless(rule.Pattern), name); ok {
			included = rule.Include
		}
	}
	return included
}

// Included reports whether p syncs: neither it nor any of its ancestors is
// excluded, and no component is protected.
func Included(p string, rules []Rule) bool {
	parts := strings.Split(p, "/")
	if slices.ContainsFunc(parts, Protected) {
		return false
	}
	for index := range parts {
		if !matches(strings.Join(parts[:index+1], "/"), rules) {
			return false
		}
	}
	return true
}
