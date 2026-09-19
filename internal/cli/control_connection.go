package cli

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/controlrtc"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (c *CLI) dialControl(ctx context.Context, gateway *gatewayTransport, route *gatewayv1.DaemonRoute) (*dieterTransport, error) {
	id := route.GetDaemonId()
	credential := &directCredential{timeout: c.connectionTimeout(), exchange: func(ctx context.Context) (*gatewayv1.DaemonAccessToken, error) {
		return gateway.client.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: id})
	}}
	var mu sync.Mutex
	var sessionID string
	bootstrap := dieterv1.NewDieterServiceClient(gateway.conn)
	dialer := func(ctx context.Context, _ string) (net.Conn, error) {
		ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
		defer cancel()
		configuration, err := gateway.client.GetRTCConfiguration(ctx, &gatewayv1.DaemonRef{DaemonId: id})
		if err != nil {
			return nil, err
		}
		stream, session, err := controlrtc.Dial(ctx, configuration, func(ctx context.Context, r *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
			return bootstrap.StartControlConnection(metadata.AppendToOutgoingContext(ctx, "x-dieter-daemon-id", id), r)
		})
		if err == nil {
			mu.Lock()
			sessionID = session.GetSessionId()
			mu.Unlock()
		}
		return stream, err
	}
	connection, err := dieterdaemon.DialDirectWithCredentials(ctx, "passthrough:///webrtc-control", id, route.GetDaemonCaPem(), credential, grpc.WithContextDialer(dialer))
	if err != nil {
		return nil, err
	}
	client := dieterv1.NewDieterServiceClient(readResumingConn{connection})
	if _, err = client.Health(ctx, &emptypb.Empty{}); err != nil {
		connection.Close()
		return nil, err
	}
	mu.Lock()
	session := sessionID
	mu.Unlock()
	info, err := client.GetControlConnection(ctx, &dieterv1.ControlConnectionRef{SessionId: session})
	if err != nil {
		connection.Close()
		return nil, err
	}
	mode := "webrtc-" + info.GetMode()
	return &dieterTransport{conn: connection, client: client, daemonID: id, route: mode}, nil
}

func (c *CLI) controlConnectionCommand(args []string) error {
	const group = "Usage: dieter machine connection <start|show|close> [options]\n\nInspect or manage data-only WebRTC signaling on the selected daemon.\nUse --machine ID|NAME for a remote daemon. Normal commands select WebRTC automatically.\nstart requires protobuf JSON containing rtcConfiguration and offerSdp.\n"
	if groupHelp(args) {
		fmt.Fprint(c.Out, group)
		return nil
	}
	action := args[0]
	if action != "start" && action != "show" && action != "close" {
		return fmt.Errorf("unknown connection action %q", action)
	}
	usage := fmt.Sprintf("Usage: dieter machine connection %s [--request FILE] [SESSION]\n\nStart with a signed RTC configuration and gathered SDP offer; show reports the\nselected ICE mode (direct or turn); close disconnects only this transport.\n", action)
	set := flags("machine connection " + action)
	requestPath := set.String("request", "", "protobuf JSON offer file (start only)")
	help, err := parse(set, args[1:], usage, c.Out)
	if help || err != nil {
		return err
	}
	if action == "start" && (*requestPath == "" || set.NArg() != 0) {
		return errors.New("start requires --request FILE and no positional arguments")
	}
	if action != "start" && (set.NArg() != 1 || *requestPath != "") {
		return errors.New("show/close requires exactly one session ID")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	switch action {
	case "start":
		raw, err := os.ReadFile(*requestPath)
		if err != nil {
			return err
		}
		if len(raw) > 128<<10 {
			return errors.New("control request exceeds 128 KiB")
		}
		request := &dieterv1.StartControlConnectionRequest{}
		if err = protojson.Unmarshal(raw, request); err != nil {
			return err
		}
		value, err := client.StartControlConnection(rpcCtx, request)
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "show":
		value, err := client.GetControlConnection(rpcCtx, &dieterv1.ControlConnectionRef{SessionId: set.Arg(0)})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	default:
		_, err = client.CloseControlConnection(rpcCtx, &dieterv1.ControlConnectionRef{SessionId: set.Arg(0)})
		return err
	}
}
