//go:build linux

package remotedesktop

import (
	"testing"
)

func TestLinuxNativeScreenCapabilitiesDoNotAdvertiseSyntheticResources(t *testing.T) {
	capabilities := New(Options{Source: SourceOptions{Kind: "screen"}}).Capabilities(false, false)
	if capabilities.GetReady() || len(capabilities.GetDisplays()) != 0 || len(capabilities.GetCodecs()) != 0 || capabilities.GetHelperVersion() != "" {
		t.Fatalf("unsupported Linux capabilities advertised resources: %#v", capabilities)
	}
	if capabilities.GetUnavailableReason() != "Native screen sharing is currently supported on macOS only" {
		t.Fatalf("reason = %q", capabilities.GetUnavailableReason())
	}
}
