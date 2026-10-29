// Package catalog embeds Dieter's self-contained default harness registry.
package catalog

import _ "embed"

// YAML is the default harness registry shipped with each release.
//
//go:embed harnesses.yaml
var YAML []byte
