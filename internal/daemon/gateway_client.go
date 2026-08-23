package daemon

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"net/url"
	"strings"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type GatewayClient struct {
	Identity    *Identity
	LocalTarget string
	Version     string
	Routes      []*gatewayv1.DirectCandidate
	Log         *slog.Logger
	OnStatus    func(GatewayEvent)
}

func (c *GatewayClient) report(state string, err error) {
	if c.OnStatus == nil {
		return
	}
	message := ""
	if err != nil {
		message = err.Error()
	}
	c.OnStatus(GatewayEvent{State: state, Error: message})
}

func (c *GatewayClient) Run(ctx context.Context) error {
	if c.Identity == nil || !c.Identity.Enrolled() {
		return errors.New("daemon is not enrolled")
	}
	if c.Log == nil {
		c.Log = slog.Default()
	}
	backoff := time.Second
	for ctx.Err() == nil {
		c.report(GatewayConnecting, nil)
		err := c.runOnce(ctx)
		if ctx.Err() != nil {
			return nil
		}
		c.report(GatewayDisconnected, err)
		c.Log.Warn("gateway tunnel disconnected", "error", err, "retry", backoff)
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
	return nil
}

func (c *GatewayClient) runOnce(ctx context.Context) error {
	connection, err := dialGateway(ctx, c.Identity, true)
	if err != nil {
		return err
	}
	defer connection.Close()
	stream, err := gatewayv1.NewDaemonLinkServiceClient(connection).Connect(ctx)
	if err != nil {
		return err
	}
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: c.Identity.ID, Version: c.Version, DirectCandidates: c.Routes}); err != nil {
		return err
	}
	challenge, err := stream.Recv()
	if err != nil || challenge.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING || challenge.GetDaemonId() != c.Identity.ID || len(challenge.GetPayload()) != 32 {
		return errors.New("gateway did not provide a valid daemon challenge")
	}
	proof := linkauth.Sign(c.Identity.PrivateKey, c.Identity.GatewayURL, c.Identity.ID, challenge.GetPayload())
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: c.Identity.ID, RequestId: challenge.GetRequestId(), Payload: proof}); err != nil {
		return err
	}
	first, err := stream.Recv()
	if err != nil || first.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK || first.GetDaemonId() != c.Identity.ID || first.GetGeneration() != c.Identity.Generation {
		return errors.New("gateway rejected the daemon hello")
	}
	c.report(GatewayConnected, nil)
	local, err := grpc.NewClient(c.LocalTarget, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDefaultCallOptions(grpc.ForceCodec(rpcraw.Codec{}), grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)))
	if err != nil {
		return err
	}
	defer local.Close()
	prioritySend := make(chan *gatewayv1.DaemonLinkFrame, 16)
	streamSend := make(chan *gatewayv1.DaemonLinkFrame, 8)
	enqueue := func(frame *gatewayv1.DaemonLinkFrame, priority bool) bool {
		queue := streamSend
		if priority {
			queue = prioritySend
		}
		select {
		case <-ctx.Done():
			return false
		case queue <- frame:
			return true
		}
	}
	sendErr := make(chan error, 1)
	go func() {
		for {
			// Always drain command responses, terminal frames, and control
			// traffic before another streaming data frame. This keeps a busy
			// WatchSync/WatchConversation call from hiding a unary admission ack.
			select {
			case frame := <-prioritySend:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
				continue
			default:
			}
			select {
			case <-ctx.Done():
				sendErr <- ctx.Err()
				return
			case frame := <-prioritySend:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
			case frame := <-streamSend:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
			}
		}
	}()
	var calls sync.Map
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	recv := make(chan *gatewayv1.DaemonLinkFrame, 8)
	recvErr := make(chan error, 1)
	go func() {
		for {
			frame, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			recv <- frame
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-sendErr:
			return err
		case err := <-recvErr:
			return err
		case <-heartbeat.C:
			enqueue(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HEARTBEAT, DaemonId: c.Identity.ID, Version: c.Version, DirectCandidates: c.Routes}, true)
		case frame := <-recv:
			switch frame.GetKind() {
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC:
				callCtx, cancel := context.WithCancel(ctx)
				calls.Store(frame.GetStreamId(), cancel)
				go func(frame *gatewayv1.DaemonLinkFrame) {
					defer calls.Delete(frame.GetStreamId())
					c.relayLocal(callCtx, local, frame, enqueue)
				}(frame)
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_CANCEL_RPC:
				if value, ok := calls.LoadAndDelete(frame.GetStreamId()); ok {
					value.(context.CancelFunc)()
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING:
				enqueue(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG}, true)
			}
		}
	}
}

func (c *GatewayClient) relayLocal(ctx context.Context, local *grpc.ClientConn, frame *gatewayv1.DaemonLinkFrame, send func(*gatewayv1.DaemonLinkFrame, bool) bool) {
	started := time.Now()
	priority := relayMethodPriority(frame.GetMethod())
	defer func() {
		c.Log.Debug("relayed Dieter RPC", "method", frame.GetMethod(), "stream_id", frame.GetStreamId(), "priority", priority, "elapsed", time.Since(started))
	}()
	emit := func(value *gatewayv1.DaemonLinkFrame) bool { return send(value, priority) }
	public, err := trust.PublicKeyFromPEM(c.Identity.GatewaySigningPublicKey)
	if err == nil {
		_, err = trust.ParseAndVerifyDelegation(public, frame.GetDelegationAssertion(), c.Identity.GatewayURL, c.Identity.ID, frame.GetRequestId(), frame.GetMethod(), frame.GetPayload(), frame.GetGeneration(), time.Now().UTC())
	}
	if err != nil {
		emit(relayError(frame.GetStreamId(), codes.Unauthenticated, "relay assertion is invalid"))
		return
	}
	if deadline := frame.GetDeadlineUnixMillis(); deadline > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, time.UnixMilli(deadline))
		defer cancel()
	}
	description := &grpc.StreamDesc{ServerStreams: true, ClientStreams: false}
	call, err := local.NewStream(ctx, description, frame.GetMethod(), grpc.ForceCodec(rpcraw.Codec{}))
	if err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if err := call.SendMsg(&rpcraw.Message{Data: frame.GetPayload()}); err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if err := call.CloseSend(); err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if headers, err := call.Header(); err == nil {
		if !emit(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_HEADER, StreamId: frame.GetStreamId(), Metadata: firstMetadata(headers)}) {
			return
		}
	}
	for {
		var response rpcraw.Message
		err := call.RecvMsg(&response)
		if errors.Is(err, io.EOF) {
			emit(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END, StreamId: frame.GetStreamId(), StatusCode: int32(codes.OK), Metadata: firstMetadata(call.Trailer())})
			return
		}
		if err != nil {
			result := relayStatusError(frame.GetStreamId(), err)
			result.Metadata = firstMetadata(call.Trailer())
			emit(result)
			return
		}
		if len(response.Data) > 16<<20 {
			emit(relayError(frame.GetStreamId(), codes.ResourceExhausted, "local response exceeds 16 MiB"))
			return
		}
		if !emit(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: frame.GetStreamId(), Payload: response.Data}) {
			return
		}
	}
}

func relayMethodPriority(method string) bool {
	return !strings.HasSuffix(method, "/WatchSync") &&
		!strings.HasSuffix(method, "/WatchConversation") &&
		!strings.HasSuffix(method, "/WatchState") &&
		!strings.HasSuffix(method, "/WatchTerminal")
}

func relayStatusError(streamID uint64, err error) *gatewayv1.DaemonLinkFrame {
	value := status.Convert(err)
	return relayError(streamID, value.Code(), value.Message())
}

func relayError(streamID uint64, code codes.Code, message string) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR, StreamId: streamID, StatusCode: int32(code), StatusMessage: message}
}

func firstMetadata(values metadata.MD) map[string]string {
	result := map[string]string{}
	for key, items := range values {
		if len(items) > 0 && key != "authorization" && key != "cookie" && !strings.HasPrefix(key, "x-dieter-") {
			result[key] = items[0]
		}
	}
	return result
}

func dialGateway(ctx context.Context, identity *Identity, withCertificate bool) (*grpc.ClientConn, error) {
	parsed, err := url.Parse(identity.GatewayURL)
	if err != nil || parsed.Host == "" {
		return nil, errors.New("gateway URL is invalid")
	}
	var transport credentials.TransportCredentials
	if parsed.Scheme == "http" {
		transport = insecure.NewCredentials()
	} else if parsed.Scheme == "https" {
		tlsConfig := &tls.Config{MinVersion: tls.VersionTLS13, ServerName: parsed.Hostname()}
		if withCertificate {
			certificate, err := tls.X509KeyPair(identity.CertificatePEM, privateKeyPEM(identity.PrivateKey))
			if err != nil {
				return nil, err
			}
			tlsConfig.Certificates = []tls.Certificate{certificate}
		}
		transport = credentials.NewTLS(tlsConfig)
	} else {
		return nil, errors.New("gateway URL must use HTTPS")
	}
	return grpc.NewClient(parsed.Host, grpc.WithTransportCredentials(transport), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)))
}

func privateKeyPEM(private ed25519.PrivateKey) []byte {
	raw, _ := x509.MarshalPKCS8PrivateKey(private)
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw})
}

func BeginEnrollment(ctx context.Context, identity *Identity) (*gatewayv1.DaemonEnrollment, error) {
	connection, err := dialGateway(ctx, identity, false)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	public, _ := identity.PublicKeyDER()
	return gatewayv1.NewGatewayServiceClient(connection).BeginDaemonEnrollment(ctx, &gatewayv1.BeginDaemonEnrollmentRequest{Name: identity.Name, PublicKey: public})
}

func CompleteEnrollment(ctx context.Context, identity *Identity, enrollmentID, secret string) (*gatewayv1.DaemonCredential, error) {
	connection, err := dialGateway(ctx, identity, false)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	return gatewayv1.NewGatewayServiceClient(connection).CompleteDaemonEnrollment(ctx, &gatewayv1.CompleteDaemonEnrollmentRequest{EnrollmentId: enrollmentID, EnrollmentSecret: secret})
}

func Unenroll(ctx context.Context, identity *Identity) error {
	if identity == nil || !identity.Enrolled() {
		return errors.New("daemon is not enrolled")
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	connection, err := dialGateway(ctx, identity, false)
	if err != nil {
		return err
	}
	defer connection.Close()
	_, err = gatewayv1.NewGatewayServiceClient(connection).UnenrollDaemon(ctx, &gatewayv1.UnenrollDaemonRequest{
		DaemonId:  identity.ID,
		Nonce:     nonce,
		Signature: linkauth.SignUnenrollment(identity.PrivateKey, identity.GatewayURL, identity.ID, nonce),
	})
	return err
}
