package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const protocolVersion = 1

type Case struct {
	Build      string            `yaml:"build,omitempty" json:"build,omitempty"`
	Version    int               `yaml:"version" json:"version"`
	ID         string            `yaml:"id" json:"id"`
	Platform   string            `yaml:"platform" json:"platform"`
	Suites     []string          `yaml:"suites" json:"suites"`
	Components []string          `yaml:"components" json:"components"`
	Fixture    string            `yaml:"fixture" json:"fixture"`
	Timeout    string            `yaml:"timeout" json:"timeout"`
	Native     *Native           `yaml:"native,omitempty" json:"native,omitempty"`
	Steps      []Step            `yaml:"steps,omitempty" json:"steps,omitempty"`
	Arguments  map[string]string `yaml:"arguments,omitempty" json:"arguments,omitempty"`
	Source     string            `yaml:"-" json:"source"`
}
type Native struct {
	Suite   string   `yaml:"suite,omitempty" json:"suite,omitempty"`
	Checks  []string `yaml:"checks,omitempty" json:"checks,omitempty"`
	Class   string   `yaml:"class,omitempty" json:"class,omitempty"`
	Methods []string `yaml:"methods,omitempty" json:"methods,omitempty"`
}
type Target struct {
	ID          string `yaml:"id,omitempty" json:"id,omitempty"`
	Text        string `yaml:"text,omitempty" json:"text,omitempty"`
	Description string `yaml:"description,omitempty" json:"description,omitempty"`
}
type Expect struct {
	Target   `yaml:",inline"`
	Visible  *bool   `yaml:"visible,omitempty" json:"visible,omitempty"`
	Enabled  *bool   `yaml:"enabled,omitempty" json:"enabled,omitempty"`
	Selected *bool   `yaml:"selected,omitempty" json:"selected,omitempty"`
	Value    *string `yaml:"value,omitempty" json:"value,omitempty"`
}
type Type struct {
	Target `yaml:",inline"`
	Value  *string `yaml:"value" json:"value"`
}
type Scroll struct {
	Within Target `yaml:"within" json:"within"`
	Until  Target `yaml:"until" json:"until"`
}
type Step struct {
	Launch     string  `yaml:"launch,omitempty" json:"launch,omitempty"`
	Tap        *Target `yaml:"tap,omitempty" json:"tap,omitempty"`
	Expect     *Expect `yaml:"expect,omitempty" json:"expect,omitempty"`
	Type       *Type   `yaml:"type,omitempty" json:"type,omitempty"`
	Press      string  `yaml:"press,omitempty" json:"press,omitempty"`
	Scroll     *Scroll `yaml:"scroll,omitempty" json:"scroll,omitempty"`
	Screenshot string  `yaml:"screenshot,omitempty" json:"screenshot,omitempty"`
	Probe      string  `yaml:"probe,omitempty" json:"probe,omitempty"`
	Line       int     `yaml:"-" json:"line"`
}

var identifier = regexp.MustCompile(`^[a-z][a-z0-9.-]{0,100}$`)
var nativeClass = regexp.MustCompile(`^(com\.dbpprt\.dieter\.|org\.webrtc\.)[A-Za-z0-9_.]+$`)
var nativeMethod = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]+$`)
var variable = regexp.MustCompile(`\$\{([^}]+)\}`)
var variables = []string{"fixture.endpointId", "fixture.cardId", "fixture.chatId", "fixture.activityPrefix"}

func decodeCase(data []byte, source string) (Case, error) {
	var c Case
	if len(data) > 256<<10 {
		return c, fmt.Errorf("%s: exceeds 256 KiB", source)
	}
	d := yaml.NewDecoder(bytes.NewReader(data))
	d.KnownFields(true)
	if err := d.Decode(&c); err != nil {
		return c, fmt.Errorf("%s: %w", source, err)
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return c, fmt.Errorf("%s: expected exactly one YAML document", source)
	}
	var tree yaml.Node
	if err := yaml.Unmarshal(data, &tree); err != nil {
		return c, err
	}
	var inspect func(*yaml.Node) error
	inspect = func(n *yaml.Node) error {
		if n.Kind == yaml.AliasNode || n.Anchor != "" || n.Tag == "!!merge" {
			return fmt.Errorf("%s:%d: YAML aliases/anchors/merges are not supported", source, n.Line)
		}
		if n.Kind == yaml.ScalarNode {
			for _, m := range variable.FindAllStringSubmatch(n.Value, -1) {
				if !slices.Contains(variables, m[1]) {
					return fmt.Errorf("%s:%d: unknown variable %s", source, n.Line, m[1])
				}
			}
		}
		for _, child := range n.Content {
			if err := inspect(child); err != nil {
				return err
			}
		}
		return nil
	}
	if err := inspect(&tree); err != nil {
		return c, err
	}
	if len(tree.Content) > 0 {
		n := tree.Content[0]
		for i := 0; i+1 < len(n.Content); i += 2 {
			if n.Content[i].Value == "steps" {
				for j, s := range n.Content[i+1].Content {
					c.Steps[j].Line = s.Line
				}
			}
		}
	}
	c.Source = source
	if err := c.validate(); err != nil {
		return c, fmt.Errorf("%s: %w", source, err)
	}
	return c, nil
}
func (t Target) validate() error {
	n := 0
	for _, v := range []string{t.ID, t.Text, t.Description} {
		if v != "" {
			n++
		}
	}
	if n != 1 {
		return fmt.Errorf("target requires exactly one of id, text, description")
	}
	return nil
}
func (c Case) validate() error {
	if c.Version != protocolVersion {
		return fmt.Errorf("unsupported version %d", c.Version)
	}
	if !identifier.MatchString(c.ID) {
		return fmt.Errorf("invalid case ID %q", c.ID)
	}
	if c.Platform != "android" && c.Platform != "ios" && c.Platform != "mac" {
		return fmt.Errorf("unsupported platform %q", c.Platform)
	}
	if c.Build != "" && c.Build != "performance" {
		return fmt.Errorf("unsupported build %q", c.Build)
	}
	if c.Build == "performance" && (c.Platform != "android" || c.Native == nil || c.Fixture != "none") {
		return fmt.Errorf("performance requires native Android without a service fixture")
	}
	if len(c.Suites) == 0 || len(c.Components) == 0 {
		return fmt.Errorf("suites and components are required")
	}
	for _, v := range append(slices.Clone(c.Suites), c.Components...) {
		if !identifier.MatchString(v) {
			return fmt.Errorf("invalid suite/component %q", v)
		}
	}
	if !slices.Contains([]string{"none", "gateway", "activity", "screen"}, c.Fixture) {
		return fmt.Errorf("unknown fixture %q", c.Fixture)
	}
	t, err := time.ParseDuration(c.Timeout)
	if err != nil || t < time.Second || t > 10*time.Minute {
		return fmt.Errorf("timeout must be between 1s and 10m")
	}
	if (c.Native == nil) == (len(c.Steps) == 0) {
		return fmt.Errorf("exactly one of native or steps is required")
	}
	if len(c.Steps) > 100 {
		return fmt.Errorf("at most 100 steps are allowed")
	}
	if c.Platform == "mac" {
		if c.Fixture != "none" && c.Fixture != "gateway" {
			return fmt.Errorf("Mac fixtures are none or gateway")
		}
		if len(c.Arguments) != 0 {
			return fmt.Errorf("Mac cases do not accept Android instrumentation arguments")
		}
		if c.Native != nil {
			if err := validateMacNative(*c.Native, c.Fixture); err != nil {
				return err
			}
		}
	} else if c.Native != nil && (c.Native.Suite != "" || len(c.Native.Checks) != 0) {
		return fmt.Errorf("suite/checks are Mac-only")
	}
	if c.Native != nil && c.Platform != "mac" {
		if (c.Platform == "android" && !nativeClass.MatchString(c.Native.Class)) || (c.Platform == "ios" && !nativeMethod.MatchString(c.Native.Class)) || len(c.Native.Methods) == 0 {
			return fmt.Errorf("native class and explicit methods required")
		}
		seen := map[string]bool{}
		for _, m := range c.Native.Methods {
			if !nativeMethod.MatchString(m) || seen[m] {
				return fmt.Errorf("invalid/duplicate native method %q", m)
			}
			seen[m] = true
		}
	}
	for k, v := range c.Arguments {
		if !slices.Contains([]string{"idleSampleMillis", "idleSampleWindows", "dieterPerformanceFrames", "screenLowLatency", "screenSurface", "screenDirectSurface", "forceTURN"}, k) || !regexp.MustCompile(`^[0-9a-z]{1,12}$`).MatchString(v) {
			return fmt.Errorf("unsupported instrumentation argument %q", k)
		}
	}
	for _, s := range c.Steps {
		if c.Platform == "mac" && (s.Type != nil || s.Scroll != nil || s.Press != "" || s.Probe != "") {
			return fmt.Errorf("Mac flows support launch, tap, expect and screenshot; use native suites for other actions")
		}
		if c.Platform == "mac" && c.Fixture != "gateway" {
			return fmt.Errorf("Mac navigation flows require gateway fixture")
		}
		b, _ := json.Marshal(s)
		var fields map[string]any
		_ = json.Unmarshal(b, &fields)
		delete(fields, "line")
		if len(fields) != 1 {
			return fmt.Errorf("line %d: exactly one action required", s.Line)
		}
		var targets []Target
		if s.Tap != nil {
			targets = append(targets, *s.Tap)
		}
		if s.Expect != nil {
			if s.Expect.Visible != nil && !*s.Expect.Visible && (s.Expect.Enabled != nil || s.Expect.Selected != nil || s.Expect.Value != nil) {
				return fmt.Errorf("line %d: absence cannot assert properties", s.Line)
			}
			targets = append(targets, s.Expect.Target)
			if s.Expect.Visible == nil && s.Expect.Enabled == nil && s.Expect.Selected == nil && s.Expect.Value == nil {
				return fmt.Errorf("line %d: expect needs an assertion", s.Line)
			}
		}
		if s.Type != nil {
			if s.Type.Value == nil {
				return fmt.Errorf("line %d: type requires an explicit value", s.Line)
			}
			targets = append(targets, s.Type.Target)
		}
		if s.Scroll != nil {
			targets = append(targets, s.Scroll.Within, s.Scroll.Until)
		}
		for _, t := range targets {
			if err := t.validate(); err != nil {
				return fmt.Errorf("line %d: %w", s.Line, err)
			}
		}
		if s.Launch != "" && s.Launch != "connected" {
			return fmt.Errorf("unknown launch mode")
		}
		if s.Press != "" && s.Press != "back" {
			return fmt.Errorf("unknown key")
		}
		if s.Probe != "" && s.Probe != "machine-telemetry" && s.Probe != "activity-replies-unread" &&
			s.Probe != "activity-card-seen" && s.Probe != "activity-chat-seen" {
			return fmt.Errorf("unknown probe")
		}
		if s.Screenshot != "" && !identifier.MatchString(s.Screenshot) {
			return fmt.Errorf("invalid screenshot name")
		}
	}
	return nil
}
func catalog(root string) ([]Case, error) {
	var cases []Case
	seen := map[string]bool{}
	err := filepath.WalkDir(filepath.Join(root, "tests/e2e/cases"), func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".yaml") {
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("case symlinks are not allowed: %s", path)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if info.Size() > 256<<10 {
			return fmt.Errorf("case too large: %s", path)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		c, err := decodeCase(data, rel)
		if err != nil {
			return err
		}
		if seen[c.ID] {
			return fmt.Errorf("duplicate case ID %s", c.ID)
		}
		seen[c.ID] = true
		cases = append(cases, c)
		return nil
	})
	if err == nil {
		err = validateReferences(root, cases)
	}
	return cases, err
}
