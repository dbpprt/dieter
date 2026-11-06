// Package relay owns the gateway and daemon's tunnel resource contract. Lanes
// change scheduling, never authorization or execution ownership. Tunnels carry
// opaque bytes: the gateway never parses what flows through them.
package relay

import (
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/reflect/protoreflect"
)

type Lane = gatewayv1.RelayLane

const (
	Control       = gatewayv1.RelayLane_RELAY_LANE_CONTROL
	Replication   = gatewayv1.RelayLane_RELAY_LANE_REPLICATION
	Command       = gatewayv1.RelayLane_RELAY_LANE_COMMAND
	Subscription  = gatewayv1.RelayLane_RELAY_LANE_SUBSCRIPTION
	ChunkBytes    = 64 << 10
	BufferedBytes = 64 << 20
	WriteTimeout  = 10 * time.Second
)

var Lanes = [...]Lane{Control, Replication, Command, Subscription}

// TunnelWindow is how many DATA frames of ChunkBytes a tunnel side may send
// before the other side credits them. Credits are end to end between client
// and daemon; the gateway only forwards them and enforces the window.
const TunnelWindow = 8

// TunnelLimit bounds the concurrent tunnels of one daemon on lane. A tunnel
// multiplexes every call of one client connection.
func TunnelLimit(lane Lane) int {
	switch lane {
	case Control:
		return 4
	case Replication:
		return 8
	case Command, Subscription:
		return 32
	default:
		return 0
	}
}

func Valid(lane Lane) bool { return lane >= Control && lane <= Subscription }

const dieterPackage = protoreflect.FullName("dieter.v1")

// FullMethod is the gRPC path of a method: "/dieter.v1.CardService/CreateCard".
func FullMethod(method protoreflect.MethodDescriptor) string {
	return "/" + string(method.Parent().FullName()) + "/" + string(method.Name())
}

// DaemonMethod reports whether a gRPC path belongs to the daemon API: any
// dieter.v1 service. It is the only API a daemon's direct endpoint serves. It
// checks the package rather than a method list; daemons answer unknown
// methods with Unimplemented.
func DaemonMethod(method string) bool {
	rest, ok := strings.CutPrefix(method, "/"+string(dieterPackage)+".")
	if !ok {
		return false
	}
	service, name, ok := strings.Cut(rest, "/")
	return ok && service != "" && name != "" && !strings.ContainsAny(service, "./") && !strings.Contains(name, "/")
}
