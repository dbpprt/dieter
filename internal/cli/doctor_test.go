package cli

import "testing"

func TestDoctorRequiresNPMOnlyForSourceBuilds(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if check := npmDoctorCheck(true); !check.Required || check.Status != "missing" {
		t.Fatalf("source build: %#v", check)
	}
	if check := npmDoctorCheck(false); check.Required || check.Status != "warning" || check.Detail != "not found in PATH; only the DSH harness needs npm" {
		t.Fatalf("release build: %#v", check)
	}
}
