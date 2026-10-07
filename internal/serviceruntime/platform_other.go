//go:build !linux

package serviceruntime

func PlatformRuntime(root string) Runtime {
	return Runtime{Root: root, SourceExecutablePrefix: "DieterDaemon.app/Contents/MacOS", Bundles: []string{"DieterDaemon.app"}}
}
