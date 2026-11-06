package linuxfs

import "dieter.spike/workspaces/core"

// BwrapPath is the bubblewrap binary Wrap uses.
var BwrapPath = "bwrap"

// Wrap returns the argv prefix that runs a command in a fresh user+mount
// namespace with the overlay mounted at Mount and the working directory set
// to it. The rest of the filesystem is the host's (--dev-bind / /); the
// caller's uid and gid are kept.
func (o Overlay) Wrap() []string { return o.WrapWith() }

// WrapWith is Wrap with extra bwrap options (for example "--unshare-pid")
// placed before the "--" separator.
func (o Overlay) WrapWith(extra ...string) []string {
	args := []string{
		BwrapPath,
		"--dev-bind", "/", "/",
		"--overlay-src", o.Lower,
		"--overlay", o.Upper, o.Work, o.Mount,
		"--chdir", o.Mount,
		"--die-with-parent",
	}
	args = append(args, extra...)
	return append(args, "--")
}

// Launcher describes how a driver starts its harness inside the view.
func (o Overlay) Launcher(env []string) core.Launcher {
	return core.Launcher{Dir: o.Mount, Wrap: o.Wrap(), Env: env}
}
