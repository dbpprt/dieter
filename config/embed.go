package config

import _ "embed"

// HarnessesYAML is Dieter's self-contained default harness registry.
//
//go:embed harnesses.yaml
var HarnessesYAML []byte
