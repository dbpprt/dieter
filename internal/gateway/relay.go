package gateway

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type relayHandler struct {
	store  *Store
	auth   *Auth
	keys   *Keys
	hub    *Hub
	config Config
}

func newRelayServer(store *Store, auth *Auth, keys *Keys, hub *Hub, config Config) *grpc.Server {
	handler := &relayHandler{store: store, auth: auth, keys: keys, hub: hub, config: config}
	return grpc.NewServer(
		grpc.ForceServerCodec(rpcraw.Codec{}),
		grpc.UnknownServiceHandler(handler.handle),
		grpc.MaxRecvMsgSize(maxRelayPayload), grpc.MaxSendMsgSize(maxRelayPayload),
	)
}

func (r *relayHandler) handle(_ any, stream grpc.ServerStream) error {
	ctx := stream.Context()
	method, ok := grpc.Method(ctx)
	if !ok || !strings.HasPrefix(method, "/dieter.v1.DieterService/") {
		return status.Error(codes.Unimplemented, "only DieterService can be relayed")
	}
	values, _ := metadata.FromIncomingContext(ctx)
	authorization := values.Get("authorization")
	daemonIDs := values.Get("x-dieter-daemon-id")
	if len(authorization) != 1 || len(daemonIDs) != 1 {
		return status.Error(codes.Unauthenticated, "gateway session and daemon ID are required")
	}
	principal, authenticated := r.auth.AuthenticateBearer(authorization[0])
	if !authenticated {
		return status.Error(codes.Unauthenticated, "authentication required")
	}
	record, err := r.store.Daemon(daemonIDs[0])
	if err != nil || record.Revoked || record.GitHubID != principal.GitHubID {
		return status.Error(codes.NotFound, "daemon not found")
	}
	var request rpcraw.Message
	if err := stream.RecvMsg(&request); err != nil {
		return err
	}
	if len(request.Data) > maxRelayPayload {
		return status.Error(codes.ResourceExhausted, "request exceeds 16 MiB")
	}
	requestID := randomID("rpc_")
	digest := sha256.Sum256(request.Data)
	now := time.Now().UTC()
	// The short-lived delegation assertion authorizes opening this RPC. It is
	// not the RPC lifetime: Dieter's watch methods intentionally remain open.
	// Only propagate a deadline when the client actually supplied one.
	deadlineUnixMillis := relayDeadlineUnixMillis(ctx)
	assertion, err := r.keys.SignDelegation(r.config.PublicURL.String(), DelegationClaims{
		Audience: "board-daemon:" + record.ID, Subject: fmt.Sprintf("github:%d", principal.GitHubID), ID: randomID("relay_"),
		RequestID: requestID, Method: method, PayloadHash: base64.RawURLEncoding.EncodeToString(digest[:]), Generation: record.Generation,
		IssuedAt: now.Unix(), ExpiresAt: now.Add(30 * time.Second).Unix(),
	})
	if err != nil {
		return status.Error(codes.Internal, "create relay assertion")
	}
	relay, err := r.hub.Open(ctx, record.ID, &gatewayv1.DaemonLinkFrame{
		Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC, RequestId: requestID, Method: method,
		Payload: request.Data, PayloadSha256: digest[:], DelegationAssertion: assertion, DeadlineUnixMillis: deadlineUnixMillis, Generation: record.Generation,
	})
	if err != nil {
		return err
	}
	defer relay.Close()
	for {
		frame, err := relay.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		switch frame.GetKind() {
		case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_HEADER:
			if headers := frameMetadata(frame.GetMetadata()); len(headers) > 0 {
				if err := stream.SendHeader(headers); err != nil {
					return err
				}
			}
		case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE:
			if len(frame.GetPayload()) > maxRelayPayload {
				return status.Error(codes.ResourceExhausted, "response exceeds 16 MiB")
			}
			if err := stream.SendMsg(&rpcraw.Message{Data: frame.GetPayload()}); err != nil {
				return err
			}
		case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END:
			stream.SetTrailer(frameMetadata(frame.GetMetadata()))
			if frame.GetStatusCode() != int32(codes.OK) {
				return status.Error(codes.Code(frame.GetStatusCode()), frame.GetStatusMessage())
			}
			return nil
		case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR:
			return status.Error(codes.Code(frame.GetStatusCode()), frame.GetStatusMessage())
		}
	}
}

func relayDeadlineUnixMillis(ctx context.Context) int64 {
	if deadline, ok := ctx.Deadline(); ok {
		return deadline.UnixMilli()
	}
	return 0
}

func frameMetadata(values map[string]string) metadata.MD {
	result := metadata.MD{}
	for key, value := range values {
		key = strings.ToLower(strings.TrimSpace(key))
		if key == "" || key == "authorization" || key == "cookie" || strings.HasPrefix(key, "x-dieter-") {
			continue
		}
		result.Set(key, value)
	}
	return result
}
