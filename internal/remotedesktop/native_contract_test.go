package remotedesktop

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestCaptureHelperRequiresCurrentContract(t *testing.T) {
	for _, version := range []uint32{0, inputProtocolVersion, inputProtocolVersion + 1} {
		t.Run(fmt.Sprint(version), func(t *testing.T) {
			helper := filepath.Join(t.TempDir(), "capture")
			script := fmt.Sprintf("#!/bin/sh\nprintf '%%s' '{\"input_protocol_version\":%d}'\n", version)
			if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			caps, err := ProbeCapabilities(context.Background(), SourceOptions{HelperPath: helper})
			if version == inputProtocolVersion {
				if err != nil || caps.InputProtocolVersion != version {
					t.Fatalf("caps=%v err=%v", caps, err)
				}
			} else if err == nil {
				t.Fatalf("accepted unsupported helper contract %d", version)
			}
		})
	}
}
