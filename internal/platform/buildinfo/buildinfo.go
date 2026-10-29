// Package buildinfo exposes linker-populated identity for Dieter binaries.
package buildinfo

// These defaults deliberately describe a development build. Release and image
// recipes replace them with -ldflags so the running process reports itself,
// rather than guessing a version from a client or deployment label.
var (
	ReleaseVersion = "0.0.0-dev.0"
	SourceRevision = "unknown"
	BuiltAt        = "unknown"
)

// The prebuilt harness runtime of a release daemon. The release lanes build
// dieter-harness-runtime-<goos>-<goarch>.tar.gz for each platform and pin its
// SHA-256 here; the daemon then installs that archive instead of running npm.
// Source builds leave HarnessRuntimeSHA256 empty and install with npm.
// HarnessRuntimeBaseURL replaces the release's download directory
// (ReleasesURL/download/vReleaseVersion) for local end-to-end builds only.
var (
	HarnessRuntimeSHA256  = ""
	HarnessRuntimeBaseURL = ""
)
