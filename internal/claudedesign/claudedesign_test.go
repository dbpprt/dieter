package claudedesign

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/store"
)

type fakeHost struct {
	mu       sync.Mutex
	status   Status
	grants   []bool
	grantErr error
	signIn   func(ctx context.Context, codes <-chan string, event func(Event) error) error
}

func (h *fakeHost) Status(context.Context) (Status, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.status, nil
}

func (h *fakeHost) SignIn(ctx context.Context, codes <-chan string, event func(Event) error) error {
	return h.signIn(ctx, codes, event)
}

func (h *fakeHost) SetGrant(_ context.Context, granted bool) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.grantErr != nil {
		return "", h.grantErr
	}
	h.grants = append(h.grants, granted)
	return "ok", nil
}

func newTestManager(t *testing.T, host *fakeHost) *Manager {
	t.Helper()
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	return New(host, data)
}

func codeSignIn(ctx context.Context, codes <-chan string, event func(Event) error) error {
	if err := event(Event{Kind: "pages", URL: "https://claude.com/authorize?loopback", ManualURL: "https://claude.com/authorize?manual"}); err != nil {
		return err
	}
	for {
		select {
		case code := <-codes:
			if code == "good" {
				return event(Event{Kind: "done", OK: true, Message: "Signed in."})
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func TestSignInForwardsManualCodeAndReportsFreshStatus(t *testing.T) {
	host := &fakeHost{status: Status{RuntimeReady: true, Available: true, CanSignIn: true}}
	host.signIn = func(ctx context.Context, codes <-chan string, event func(Event) error) error {
		err := codeSignIn(ctx, codes, event)
		host.mu.Lock()
		host.status.SignedIn = true
		host.mu.Unlock()
		return err
	}
	manager := newTestManager(t, host)
	events := make(chan Event, 8)
	result := make(chan error, 1)
	go func() {
		result <- manager.SignIn(context.Background(), func(event Event) error {
			events <- event
			return nil
		})
	}()
	started := <-events
	if started.Kind != "started" || !strings.HasPrefix(started.SignInID, "cds_") {
		t.Fatalf("first event = %+v", started)
	}
	pages := <-events
	if pages.Kind != "pages" || pages.SignInID != started.SignInID || pages.ManualURL == "" {
		t.Fatalf("pages event = %+v", pages)
	}
	if snapshot, err := manager.Status(context.Background()); err != nil || !snapshot.SignInActive {
		t.Fatalf("status during sign-in = %+v, %v", snapshot, err)
	}
	if err := manager.SubmitCode("cds_other", "good"); !errors.Is(err, ErrNoSignIn) {
		t.Fatalf("code for another sign-in = %v", err)
	}
	if err := manager.SubmitCode(started.SignInID, "bad\x00code"); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("control character code = %v", err)
	}
	if err := manager.SubmitCode(started.SignInID, "  good  "); err != nil {
		t.Fatal(err)
	}
	done := <-events
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if done.Kind != "done" || !done.OK || done.Snapshot == nil || !done.Snapshot.SignedIn || done.Snapshot.SignInActive {
		t.Fatalf("done event = %+v snapshot=%+v", done, done.Snapshot)
	}
	if err := manager.SubmitCode(started.SignInID, "good"); !errors.Is(err, ErrNoSignIn) {
		t.Fatalf("code after sign-in = %v", err)
	}
}

func TestNewerSignInReplacesOlderOne(t *testing.T) {
	host := &fakeHost{status: Status{Available: true}, signIn: codeSignIn}
	manager := newTestManager(t, host)
	first := make(chan Event, 8)
	firstResult := make(chan error, 1)
	go func() {
		firstResult <- manager.SignIn(context.Background(), func(event Event) error { first <- event; return nil })
	}()
	<-first
	<-first
	second := make(chan Event, 8)
	ctx, cancel := context.WithCancel(context.Background())
	secondResult := make(chan error, 1)
	go func() {
		secondResult <- manager.SignIn(ctx, func(event Event) error { second <- event; return nil })
	}()
	<-second
	replaced := <-first
	if err := <-firstResult; err != nil {
		t.Fatal(err)
	}
	if replaced.Kind != "done" || replaced.OK || !strings.Contains(replaced.Message, "newer") {
		t.Fatalf("replaced sign-in ended with %+v", replaced)
	}
	pages := <-second
	cancel()
	if err := <-secondResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled stream returned %v", err)
	}
	// A phone that left for the browser lost its stream; its code still counts.
	if snapshot, _ := manager.Status(context.Background()); !snapshot.SignInActive {
		t.Fatal("the sign-in ended with its stream")
	}
	if err := manager.SubmitCode(pages.SignInID, "good"); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if snapshot, _ := manager.Status(context.Background()); !snapshot.SignInActive {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the detached sign-in did not finish after its code")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestCloseEndsARunningSignIn(t *testing.T) {
	host := &fakeHost{status: Status{Available: true}, signIn: codeSignIn}
	manager := newTestManager(t, host)
	events := make(chan Event, 8)
	result := make(chan error, 1)
	go func() {
		result <- manager.SignIn(context.Background(), func(event Event) error { events <- event; return nil })
	}()
	<-events
	<-events
	manager.Close()
	if done := <-events; done.Kind != "done" || done.OK || done.Snapshot == nil {
		t.Fatalf("closed sign-in ended with %+v", done)
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
}

func TestAccessGrantsBeforeEnablingAndDisablesLocallyFirst(t *testing.T) {
	host := &fakeHost{status: Status{Available: false, Reason: "Claude Design is not enabled for this account."}}
	manager := newTestManager(t, host)
	_, err := manager.SetAccess(context.Background(), true, false)
	var precondition FailedPrecondition
	if !errors.As(err, &precondition) || !strings.Contains(precondition.Message, "not enabled") || manager.AccessEnabled() {
		t.Fatalf("enable while unavailable = %v enabled=%v", err, manager.AccessEnabled())
	}
	host.status = Status{Available: true}
	host.grantErr = FailedPrecondition{Message: "Couldn't record Design agent access."}
	if _, err := manager.SetAccess(context.Background(), true, false); err == nil || manager.AccessEnabled() {
		t.Fatalf("failed grant enabled access: %v", err)
	}
	host.grantErr = nil
	snapshot, err := manager.SetAccess(context.Background(), true, false)
	if err != nil || !snapshot.AccessEnabled || snapshot.AccessUpdatedAt == "" || !manager.AccessEnabled() {
		t.Fatalf("enable = %+v, %v", snapshot, err)
	}
	snapshot, err = manager.SetAccess(context.Background(), false, false)
	if err != nil || snapshot.AccessEnabled || manager.AccessEnabled() {
		t.Fatalf("disable = %+v, %v", snapshot, err)
	}
	host.grantErr = errors.New("revoke failed")
	if _, err := manager.SetAccess(context.Background(), true, false); err == nil {
		t.Fatal("grant error was ignored")
	}
	host.grantErr = nil
	if _, err := manager.SetAccess(context.Background(), true, false); err != nil {
		t.Fatal(err)
	}
	host.grantErr = errors.New("revoke failed")
	if _, err := manager.SetAccess(context.Background(), false, true); err == nil || manager.AccessEnabled() {
		t.Fatalf("revoke failure must still leave local access off: %v enabled=%v", err, manager.AccessEnabled())
	}
	if got := host.grants; len(got) != 2 || !got[0] || !got[1] {
		t.Fatalf("grants = %v", got)
	}
}

// fakeHelper writes a shell script that imitates claude-design-host.mjs.
func fakeHelper(t *testing.T, script string) CommandFactory {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake helper is a POSIX shell script")
	}
	path := filepath.Join(t.TempDir(), "helper.sh")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script), 0o700); err != nil {
		t.Fatal(err)
	}
	return func(ctx context.Context, operation string) (*exec.Cmd, error) {
		return exec.CommandContext(ctx, path, operation), nil
	}
}

func TestProcessHostParsesStatusAndGrantResults(t *testing.T) {
	host := NewProcessHost(fakeHelper(t, `
case "$1" in
status) echo 'diagnostic'; echo '{"runtimeReady":true,"version":"2.1.285","available":true,"signedIn":true,"canSignIn":true,"reason":""}' ;;
consent) echo '{"ok":true,"message":"Design agent access granted for your Claude Design projects."}' ;;
revoke) echo '{"ok":false,"message":"Couldn'"'"'t revoke Design agent access."}'; exit 1 ;;
esac
`))
	status, err := host.Status(context.Background())
	if err != nil || !status.Available || !status.SignedIn || status.Version != "2.1.285" {
		t.Fatalf("status = %+v, %v", status, err)
	}
	if message, err := host.SetGrant(context.Background(), true); err != nil || !strings.HasPrefix(message, "Design agent access granted") {
		t.Fatalf("consent = %q, %v", message, err)
	}
	var precondition FailedPrecondition
	if _, err := host.SetGrant(context.Background(), false); !errors.As(err, &precondition) || !strings.Contains(precondition.Message, "revoke") {
		t.Fatalf("revoke = %v", err)
	}
}

func TestProcessHostSignInRelaysCodesAndRejectsUnsafePages(t *testing.T) {
	host := NewProcessHost(fakeHelper(t, `
echo '{"event":"preparing"}'
echo '{"event":"pages","url":"javascript:alert(1)","manual_url":"http://claude.com/manual"}'
echo '{"event":"pages","url":"https://claude.com/cai/oauth/authorize?a=1","manual_url":"https://claude.com/cai/oauth/authorize?a=2","manual_first":true}'
read line
case "$line" in
*'"code":"abc#state"'*) echo '{"event":"done","ok":true}'; exit 0 ;;
*) echo '{"event":"done","ok":false,"message":"bad code"}'; exit 1 ;;
esac
`))
	codes := make(chan string, 1)
	var events []Event
	err := host.SignIn(context.Background(), codes, func(event Event) error {
		events = append(events, event)
		if event.Kind == "pages" {
			codes <- "abc#state"
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 3 || events[0].Kind != "preparing" || events[1].Kind != "pages" || events[2].Kind != "done" {
		t.Fatalf("events = %+v", events)
	}
	if !events[1].ManualFirst || events[1].URL != "https://claude.com/cai/oauth/authorize?a=1" {
		t.Fatalf("pages = %+v", events[1])
	}
	if !events[2].OK || events[2].Message == "" {
		t.Fatalf("done = %+v", events[2])
	}
}

func TestProcessHostSignInStopsWhenCanceled(t *testing.T) {
	host := NewProcessHost(fakeHelper(t, `
echo '{"event":"pages","url":"https://claude.com/a","manual_url":"https://claude.com/b"}'
read line
`))
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		result <- host.SignIn(ctx, make(chan string), func(Event) error {
			cancel()
			return nil
		})
	}()
	select {
	case <-result:
	case <-time.After(10 * time.Second):
		t.Fatal("canceled sign-in did not stop its helper")
	}
}
