package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

// localTokenTransport authenticates test requests to the raw local API.
type localTokenTransport struct{ root string }

func (t localTokenTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	token, err := localauth.Read(t.root)
	if err != nil {
		return nil, err
	}
	request = request.Clone(request.Context())
	request.Header.Set(localauth.Header, token)
	return http.DefaultTransport.RoundTrip(request)
}

type idleRunner struct{}

func (idleRunner) Run(context.Context, harness.Request, func(harness.Output) error) error {
	return errors.New("idle daemon fixture never runs turns")
}

type activationRecoveryRunner struct {
	heartbeat chan struct{}
	park      chan struct{}
	request   chan harness.Request
	parkOnce  sync.Once
}

func (runner *activationRecoveryRunner) PrepareRuntime(_ context.Context, digest string) (harness.RuntimeReference, error) {
	if digest != "runtime-a" {
		return harness.RuntimeReference{}, errors.New("unexpected runtime digest " + digest)
	}
	return harness.RuntimeReference{Digest: digest, ProtocolVersion: harness.RuntimeProtocolVersion, Directory: "/runtime/" + digest}, nil
}

func (runner *activationRecoveryRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.request <- request
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-runner.heartbeat:
	}
	if err := emit(harness.Output{Type: "heartbeat"}); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-runner.park:
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"thread":"fixture"},"continueFrom":{"type":"continue-turn","data":{"cursor":2}}}`)})
}

func (runner *activationRecoveryRunner) Suspend(_, _ string) error {
	runner.parkOnce.Do(func() { close(runner.park) })
	return nil
}

func TestCandidateActivationWaitsForRecoveredWorkerHeartbeat(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Activation", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{
		Project: project.ID, ID: "chat_activation", Title: "Activation recovery", Prompt: "Keep working",
		Provider: "codex", Model: "gpt-5.6-sol", Effort: "low", WorkspaceMode: model.WorkspaceModeProject,
	})
	if err != nil {
		t.Fatal(err)
	}
	const turnID = "turn_activation"
	if _, err := data.Conversations.StartTurn(chat.ID, turnID, "user_activation", chat.InitialPrompt); err != nil {
		t.Fatal(err)
	}
	if _, err := data.Conversations.SetActiveTurn(chat.ID, model.ConversationTurn{
		ID: turnID, UserMessageID: "user_activation", ResponseMessageID: "assistant_activation",
		HarnessRuntimeDigest: "runtime-a", HarnessRuntimeProtocol: harness.RuntimeProtocolVersion,
		Selection: &model.HarnessSelection{Provider: "codex", Model: "gpt-5.6-sol", Effort: "low"},
	}); err != nil {
		t.Fatal(err)
	}
	continuation := json.RawMessage(`{"type":"resume-session","data":{"thread":"fixture"},"continueFrom":{"type":"continue-turn","data":{"cursor":1}}}`)
	if _, err := data.Conversations.SetSession(chat.ID, turnID, continuation); err != nil {
		t.Fatal(err)
	}
	if _, err := data.Kanban.UpdateCardCache(chat.ID, kanban.CardCacheInput{Provider: "codex", Model: "gpt-5.6-sol", Runtime: "running"}); err != nil {
		t.Fatal(err)
	}

	runner := &activationRecoveryRunner{
		heartbeat: make(chan struct{}), park: make(chan struct{}), request: make(chan harness.Request, 1),
	}
	ready := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		services := NewServices(data, slog.New(slog.NewTextHandler(io.Discard, nil)), ServiceOptions{Runner: runner})
		done <- services.Serve(ctx, listener, true, func() error {
			close(ready)
			return nil
		})
	}()
	select {
	case request := <-runner.request:
		if !request.Continue || request.RuntimeDigest != "runtime-a" {
			t.Fatalf("recovery request=%#v", request)
		}
	case <-time.After(5 * time.Second):
		cancel()
		t.Fatal("candidate did not start the recovered turn")
	}
	select {
	case <-ready:
		cancel()
		t.Fatal("candidate committed before the recovered worker heartbeat")
	case <-time.After(100 * time.Millisecond):
	}
	close(runner.heartbeat)
	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		cancel()
		t.Fatal("candidate did not commit after the recovered worker heartbeat")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			t.Fatal(err)
		}
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("candidate daemon did not shut down cleanly")
	}
	conversation, err := data.Conversations.Get(chat.ID)
	if err != nil || conversation.Status != "running" || conversation.ActiveTurn == nil || conversation.ActiveTurn.HarnessRuntimeDigest != "runtime-a" {
		t.Fatalf("parked conversation=%#v err=%v", conversation, err)
	}
}

func TestIdleDaemonStreamsOnlyHeartbeatsAndRecordsNoChanges(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	daemonCtx, stopDaemon := context.WithCancel(context.Background())
	daemonDone := make(chan error, 1)
	go func() {
		services := NewServices(data, slog.New(slog.NewTextHandler(io.Discard, nil)), ServiceOptions{Runner: idleRunner{}})
		daemonDone <- services.Serve(daemonCtx, listener, false, nil)
	}()
	defer func() {
		stopDaemon()
		select {
		case <-daemonDone:
		case <-time.After(5 * time.Second):
			t.Error("idle daemon did not stop")
		}
	}()
	client := dieterclient.NewConnect(&http.Client{Transport: localTokenTransport{root: data.Root}}, "http://"+address)
	for deadline := time.Now().Add(testkit.Budget(30 * time.Second)); ; {
		readyCtx, cancelReady := context.WithTimeout(context.Background(), 250*time.Millisecond)
		_, healthErr := client.Health(readyCtx, &emptypb.Empty{})
		cancelReady()
		if healthErr == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("idle daemon did not become ready: %v", healthErr)
		}
		time.Sleep(20 * time.Millisecond)
	}
	before, err := data.ChangeCount()
	if err != nil {
		t.Fatal(err)
	}
	watchCtx, stopWatch := context.WithCancel(context.Background())
	stream, err := client.WatchChanges(watchCtx, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	if err != nil {
		stopWatch()
		t.Fatal(err)
	}
	if !stream.Receive() || !stream.Msg().GetCaughtUp() {
		stopWatch()
		t.Fatalf("initial idle frame=%#v err=%v", stream.Msg(), stream.Err())
	}
	started := time.Now()
	timer := time.AfterFunc(25*time.Second, stopWatch)
	heartbeats := 0
	var violations []string
	for stream.Receive() {
		if frame := stream.Msg(); !frame.GetHeartbeat() {
			violations = append(violations, fmt.Sprintf("data frame: %#v", frame))
			continue
		}
		heartbeats++
	}
	timer.Stop()
	if elapsed := time.Since(started); elapsed < 25*time.Second {
		t.Fatalf("idle observation ended early after %s: %v", elapsed, stream.Err())
	}
	if heartbeats < 20 {
		t.Errorf("idle heartbeats=%d, want at least 20", heartbeats)
	}
	if after, err := data.ChangeCount(); err != nil || after != before {
		violations = append(violations, fmt.Sprintf("store recorded changes %d -> %d (%v)", before, after, err))
	}
	if len(violations) != 0 {
		t.Fatalf("idle daemon changed: %v", violations)
	}
}
