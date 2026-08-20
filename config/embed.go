package config

import _ "embed"

// HarnessesYAML is Nauclio's self-contained default harness registry.
//
//go:embed harnesses.yaml
var HarnessesYAML []byte
