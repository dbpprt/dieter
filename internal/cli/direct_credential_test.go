package cli

import (
	"bytes"
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestDirectCredentialSharesRefreshAndHonorsCancellation(t *testing.T) {
	var exchanges atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	credential := &directCredential{timeout: time.Second, exchange: func(ctx context.Context) (*gatewayv1.DaemonAccessToken, error) {
		exchanges.Add(1)
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return &gatewayv1.DaemonAccessToken{TokenType: "Bearer", AccessToken: "fresh", ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano)}, nil
	}}
	var group sync.WaitGroup
	for range 16 {
		group.Go(func() {
			metadata, err := credential.GetRequestMetadata(t.Context())
			if err != nil || metadata["authorization"] != "Bearer fresh" {
				t.Errorf("metadata=%v err=%v", metadata, err)
			}
		})
	}
	<-entered
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
	defer cancel()
	if _, err := credential.GetRequestMetadata(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("waiting caller: %v", err)
	}
	close(release)
	group.Wait()
	if exchanges.Load() != 1 {
		t.Fatalf("refresh exchanges=%d", exchanges.Load())
	}
}

func TestDirectCredentialRejectsInvalidRefresh(t *testing.T) {
	for _, access := range []*gatewayv1.DaemonAccessToken{nil, {TokenType: "Bearer", AccessToken: "expired", ExpiresAt: time.Now().Add(-time.Minute).Format(time.RFC3339Nano)}, {TokenType: "Other", AccessToken: "wrong-type", ExpiresAt: time.Now().Add(time.Hour).Format(time.RFC3339Nano)}} {
		credential := &directCredential{timeout: time.Second, exchange: func(context.Context) (*gatewayv1.DaemonAccessToken, error) { return access, nil }}
		if _, err := credential.GetRequestMetadata(t.Context()); status.Code(err) != codes.Unauthenticated {
			t.Fatalf("invalid credential accepted: %v", err)
		}
	}
}

type expiringExecutionServer struct {
	dieterv1.UnimplementedDieterServiceServer
	requests chan uint64
}

func (*expiringExecutionServer) Health(context.Context, *emptypb.Empty) (*dieterv1.HealthResponse, error) {
	return &dieterv1.HealthResponse{Status: "ok", ReleaseVersion: "0.4.1-dev"}, nil
}

func (*expiringExecutionServer) GetExecution(context.Context, *dieterv1.ExecutionRef) (*dieterv1.Execution, error) {
	return &dieterv1.Execution{Id: "exec_security", Status: "running"}, nil
}

func (s *expiringExecutionServer) WatchExecution(request *dieterv1.WatchExecutionRequest, stream grpc.ServerStreamingServer[dieterv1.ExecutionEvent]) error {
	s.requests <- request.GetAfterSequence()
	sequence := request.GetAfterSequence() + 1
	event := &dieterv1.ExecutionEvent{Sequence: sequence, Stream: dieterv1.ExecutionStream_EXECUTION_STREAM_STDOUT, Data: []byte("one")}
	switch sequence {
	case 2:
		event.Stream, event.Data = dieterv1.ExecutionStream_EXECUTION_STREAM_STDERR, []byte("two")
	case 3:
		event.Data, event.Eof, event.Execution = nil, true, &dieterv1.Execution{Id: "exec_security", Status: "exited", ExitCode: new(int32(23))}
	default:
		if sequence != 1 {
			return status.Error(codes.InvalidArgument, "unexpected resume cursor")
		}
	}
	if err := stream.Send(event); err != nil {
		return err
	}
	if sequence == 3 {
		return nil
	}
	<-stream.Context().Done()
	return status.FromContextError(stream.Context().Err()).Err()
}

// Exercise the real CLI, certificate verification, per-RPC credential renewal,
// server token deadline (including skew), and output/exit semantics over two
// successive token lifetimes. All identities, listeners and state are isolated.
func TestRemoteWaitSurvivesTwoDirectTokenExpirations(t *testing.T) {
	keys, err := gateway.LoadOrCreateKeys(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	identity, err := daemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), "security", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	public, err := identity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	certificate, expires, err := keys.IssueDaemonCertificate("d_security", public)
	if err != nil {
		t.Fatal(err)
	}
	signing, err := keys.SigningPublicPEM()
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential("d_security", "security", certificate, keys.DaemonCAPEM, signing, expires.Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	localListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	local := grpc.NewServer()
	execution := &expiringExecutionServer{requests: make(chan uint64, 4)}
	dieterv1.RegisterDieterServiceServer(local, execution)
	go func() { _ = local.Serve(localListener) }()
	t.Cleanup(local.Stop)
	direct, err := daemon.NewDirectServer(identity, localListener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	directListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = direct.Serve(directListener) }()
	t.Cleanup(direct.Stop)
	var exchanges atomic.Int32
	credential := &directCredential{timeout: time.Second, exchange: func(context.Context) (*gatewayv1.DaemonAccessToken, error) {
		exchanges.Add(1)
		token, expiry, err := keys.SignDaemonToken(identity.GatewayURL, identity.ID, 123, 1, "", time.Second)
		return &gatewayv1.DaemonAccessToken{TokenType: "Bearer", AccessToken: token, ExpiresAt: expiry.Format(time.RFC3339Nano)}, err
	}}
	connection, err := daemon.DialDirectWithCredentials(t.Context(), directListener.Addr().String(), identity.ID, keys.DaemonCAPEM, credential)
	if err != nil {
		t.Fatal(err)
	}
	client := New(store.New(t.TempDir()))

	client.transport = &dieterTransport{conn: connection, client: dieterv1.NewDieterServiceClient(readResumingConn{connection}), route: "direct", daemonID: identity.ID}
	t.Cleanup(client.Close)
	var stdout, stderr bytes.Buffer
	client.Out, client.Err = &stdout, &stderr
	result := make(chan error, 1)
	go func() { result <- client.Run([]string{"remote", "wait", "exec_security"}) }()
	select {
	case err := <-result:
		var exit *remoteExitError
		if !errors.As(err, &exit) || exit.Code() != 23 {
			t.Fatalf("remote wait: %v", err)
		}
	case <-time.After(35 * time.Second):
		t.Fatal("remote wait did not resume across token expiration")
	}
	if stdout.String() != "one" || stderr.String() != "two" {
		t.Fatalf("stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
	for _, want := range []uint64{0, 1, 2} {
		select {
		case got := <-execution.requests:
			if got != want {
				t.Fatalf("resume=%d want=%d", got, want)
			}
		default:
			t.Fatal("missing resumed subscription")
		}
	}
	if len(execution.requests) != 0 || exchanges.Load() < 3 {
		t.Fatalf("extra watches=%d exchanges=%d", len(execution.requests), exchanges.Load())
	}
}
