package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
)

type onboardingPrivacyFixture struct {
	mu                   sync.Mutex
	available, requested bool
	setupCalls, setCalls int
	failure              error
}

func (f *onboardingPrivacyFixture) snapshot() *dieterv1.MachinePrivacy {
	state := dieterv1.MachinePrivacy_STATE_OFF
	if f.requested {
		state = dieterv1.MachinePrivacy_STATE_ON
	}
	return &dieterv1.MachinePrivacy{Supported: f.available, Requested: f.requested, State: state, HelperSetupRequired: !f.available}
}
func (f *onboardingPrivacyFixture) Snapshot(context.Context) (*dieterv1.MachinePrivacy, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.snapshot(), nil
}
func (f *onboardingPrivacyFixture) Setup(context.Context) (*dieterv1.MachinePrivacy, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.setupCalls++
	if f.failure != nil {
		return nil, f.failure
	}
	f.available = true
	return f.snapshot(), nil
}
func (f *onboardingPrivacyFixture) Set(context.Context, bool) (*dieterv1.MachinePrivacy, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.setCalls++
	return nil, errors.New("onboarding must never enable or disable privacy")
}

func privacyOnboardingCLI(t *testing.T, driver *onboardingPrivacyFixture) (*CLI, *bytes.Buffer) {
	t.Helper()
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	identity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(data.Root, "fixture", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential("d_fixture", "fixture", []byte("certificate"), nil, nil, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	application := server.NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), server.Options{
		Runner: &fakeRunner{}, PrivacyDriver: driver,
		PrivacyBootID: func(context.Context) (string, error) { return "fixture-boot", nil },
		RemoteDesktop: remotedesktop.New(remotedesktop.Options{Source: remotedesktop.SourceOptions{Kind: "synthetic"}}),
	})
	host := httptest.NewServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := dieterdaemon.NewStatusWriter(data.Root, dieterdaemon.RuntimeStatus{PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://")}); err != nil {
		t.Fatal(err)
	}
	output := &bytes.Buffer{}
	client := New(data)
	client.Out, client.Err = output, output
	t.Cleanup(client.Close)
	return client, output
}

func TestSetupPrivacyHelperRegistersWithoutEnablingAndPreservesExistingState(t *testing.T) {
	for _, test := range []struct {
		name                       string
		available, requested, skip bool
		failure                    error
		calls                      int
	}{
		{name: "new helper", calls: 1},
		{name: "already approved", available: true},
		{name: "privacy requested", available: true, requested: true},
		{name: "deferred", skip: true},
		{name: "registration failure", failure: errors.New("registration denied"), calls: 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			driver := &onboardingPrivacyFixture{available: test.available, requested: test.requested, failure: test.failure}
			client, output := privacyOnboardingCLI(t, driver)
			err := client.setupPrivacyHelper(test.skip)
			if (err != nil) != (test.failure != nil) {
				t.Fatalf("setup error=%v output=%s", err, output)
			}
			if test.failure == nil {
				if err := client.setupPrivacyHelper(test.skip); err != nil {
					t.Fatal(err)
				}
			}
			driver.mu.Lock()
			defer driver.mu.Unlock()
			if driver.setupCalls != test.calls || driver.setCalls != 0 || driver.requested != test.requested {
				t.Fatalf("setup=%d privacy mutations=%d requested=%v", driver.setupCalls, driver.setCalls, driver.requested)
			}
			if test.calls == 1 && test.failure == nil && !strings.Contains(output.String(), "Dieter Privacy Helper") {
				t.Fatalf("missing approval guidance: %s", output)
			}
		})
	}
}

func TestSetupHomebrewOnboardingInstallsPrivacyHelperThroughDaemon(t *testing.T) {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		t.Skip("Homebrew onboarding requires Apple Silicon macOS")
	}
	for _, flag := range []string{"", "--no-open", "--no-start"} {
		t.Run("setup"+flag, func(t *testing.T) {
			driver := &onboardingPrivacyFixture{}
			client, output := privacyOnboardingCLI(t, driver)
			bin := t.TempDir()
			log := filepath.Join(bin, "brew.log")
			brew := "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >>\"$DIETER_TEST_SETUP_BREW_LOG\"\ncase \"$*\" in\n  'list --formula dieter'|'services restart dieter'|'services list --json') exit 0;;\n  *) exit 1;;\nesac\n"
			if err := os.WriteFile(filepath.Join(bin, "brew"), []byte(brew), 0755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			t.Setenv("DIETER_TEST_SETUP_BREW_LOG", log)
			args := []string{"setup"}
			if flag != "" {
				args = append(args, flag)
			}
			if err := client.Run(args); err != nil {
				t.Fatalf("onboarding: %v\n%s", err, output)
			}
			driver.mu.Lock()
			defer driver.mu.Unlock()
			want := 0
			if flag == "" {
				want = 1
			}
			if driver.setupCalls != want || driver.setCalls != 0 || driver.requested {
				t.Fatalf("setup=%d mutations=%d requested=%v", driver.setupCalls, driver.setCalls, driver.requested)
			}
			if flag == "" || flag == "--no-open" {
				raw, err := os.ReadFile(log)
				if err != nil || !strings.Contains(string(raw), "services restart dieter") {
					t.Fatalf("Homebrew workflow: %s %v", raw, err)
				}
			} else if _, err := os.Stat(log); !os.IsNotExist(err) {
				t.Fatal("--no-start invoked Homebrew")
			}
		})
	}
}

func TestSetupRejectsRemoteMachineBeforeOnboarding(t *testing.T) {
	client := New(store.New(t.TempDir()))
	defer client.Close()
	client.Machine = "remote-fixture"
	if err := client.Run([]string{"setup", "--no-open", "--no-start"}); err == nil || !strings.Contains(err.Error(), "local-only") {
		t.Fatalf("remote setup: %v", err)
	}
}
