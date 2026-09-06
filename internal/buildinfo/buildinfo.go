// Package buildinfo exposes linker-populated identity for Dieter binaries.
package buildinfo

// These defaults deliberately describe a development build. Release and image
// recipes replace them with -ldflags so the running process reports itself,
// rather than guessing a version from a client or deployment label.
var (
	ReleaseVersion = "0.4.1-dev"
	SourceRevision = "unknown"
	BuiltAt        = "unknown"
)
