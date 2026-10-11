package pipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// affected-checks is the only contract; Fastlane runs Maestro and writes its
// own results, so the removed catalog, result and product codecs stay gone.
func TestContractOffersOnlyAffectedChecks(t *testing.T) {
	var help bytes.Buffer
	if err := Contract(context.Background(), t.TempDir(), []string{"--help"}, strings.NewReader(""), &help); err != nil {
		t.Fatal(err)
	}
	if usage, _, _ := strings.Cut(help.String(), "\n"); usage != "pipeline-contract affected-checks" {
		t.Fatalf("usage = %q", usage)
	}
	for _, operation := range []string{"lint", "plan", "qualify", "report", "xctestrun", "mac-phases", "android-digest", "extract", "ios-console", "screen-normalize"} {
		var output bytes.Buffer
		if err := Contract(context.Background(), t.TempDir(), []string{operation}, strings.NewReader("{}"), &output); err == nil || !strings.Contains(err.Error(), "unknown contract operation") {
			t.Fatalf("%s: %v", operation, err)
		}
	}
}

func TestAffectedChecksContractDecodesBoundedRequest(t *testing.T) {
	var output bytes.Buffer
	request := `{"paths":["tests/maestro/mac/navigation.yaml"],"kind":"local"}`
	if err := Contract(context.Background(), t.TempDir(), []string{"affected-checks"}, strings.NewReader(request), &output); err != nil {
		t.Fatal(err)
	}
	var plan CheckPlan
	if err := json.Unmarshal(output.Bytes(), &plan); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(plan.Paths, []string{"tests/maestro/mac/navigation.yaml"}) || !checkExists(plan, "mac", "e2e") || !plan.CI["macos"] {
		t.Fatalf("plan = %+v", plan)
	}
	for _, request := range []string{`{"platform":"ios"}`, `{"cases":[]}`, `{} {}`, `[]`} {
		if err := Contract(context.Background(), t.TempDir(), []string{"affected-checks"}, strings.NewReader(request), &output); err == nil {
			t.Fatalf("accepted %s", request)
		}
	}
}

func TestDeviceLeaseOwnership(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lease")
	unlock, err := acquireLease(path)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := acquireLease(path); err == nil {
		second()
		t.Fatal("admitted concurrent device owner")
	}
	unlock()
	next, err := acquireLease(path)
	if err != nil {
		t.Fatal(err)
	}
	next()
	if _, err = os.Stat(path); err != nil {
		t.Fatal("lease inode must remain")
	}
}

func TestSupportRejectsUnknownPrimitives(t *testing.T) {
	if err := Support(context.Background(), []string{"device-lease", "serial"}); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Fatalf("device-lease without a command: %v", err)
	}
	if err := Support(context.Background(), []string{"run"}); err == nil || !strings.Contains(err.Error(), "unknown primitive") {
		t.Fatalf("unknown primitive: %v", err)
	}
}

func TestCommandCancellation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := command(ctx, t.TempDir(), nil, "/bin/sleep", "30")
	if err == nil || time.Since(start) > time.Second {
		t.Fatal("cancellation did not stop child promptly")
	}
}

func TestBoundedOutput(t *testing.T) {
	b := &tailBuffer{limit: 4}
	_, _ = b.Write([]byte("abcdef"))
	if b.String() != "cdef" {
		t.Fatal(b.String())
	}
}
