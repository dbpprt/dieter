// Package mail contains the report used by the real Mail reader flows and renderer tests.
package mail

import _ "embed"

//go:embed rich.md
var Rich string

//go:embed backgrounds.md
var Backgrounds string
