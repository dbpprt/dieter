// Package relaypolicy owns the gateway and daemon's transport resource contract.
// Lanes change scheduling, never authorization or execution ownership.
package relay

import (
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
)

type Lane = gatewayv1.RelayLane

const (
	ControlCalls      = 4
	ReplicationCalls  = 4
	CommandCalls      = 16
	SubscriptionCalls = 64
	Control           = gatewayv1.RelayLane_RELAY_LANE_CONTROL
	Replication       = gatewayv1.RelayLane_RELAY_LANE_REPLICATION
	Command           = gatewayv1.RelayLane_RELAY_LANE_COMMAND
	Subscription      = gatewayv1.RelayLane_RELAY_LANE_SUBSCRIPTION
	ChunkBytes        = 64 << 10
	MessageBytes      = 16 << 20
	BufferedBytes     = 64 << 20
	WriteTimeout      = 10 * time.Second
	AssemblyTimeout   = 30 * time.Second
)

var Lanes = [...]Lane{Control, Replication, Command, Subscription}

func Valid(lane Lane) bool { return lane >= Control && lane <= Subscription }
func Limit(lane Lane) int {
	switch lane {
	case Control:
		return ControlCalls
	case Replication:
		return ReplicationCalls
	case Command:
		return CommandCalls
	case Subscription:
		return SubscriptionCalls
	default:
		return 0
	}
}

// subscriptions holds the server-streaming methods of every dieter.v1
// service, including WatchKV and StartRemoteDesktop, keyed by full method path.
// Unknown methods receive ordinary admission and remain subject to the
// daemon's explicit Unimplemented response.
var subscriptions = func() map[string]bool {
	result := map[string]bool{}
	protoregistry.GlobalFiles.RangeFilesByPackage(dieterPackage, func(file protoreflect.FileDescriptor) bool {
		services := file.Services()
		for i := 0; i < services.Len(); i++ {
			methods := services.Get(i).Methods()
			for j := 0; j < methods.Len(); j++ {
				if method := methods.Get(j); method.IsStreamingServer() {
					result[FullMethod(method)] = true
				}
			}
		}
		return true
	})
	return result
}()

const dieterPackage = protoreflect.FullName("dieter.v1")

// FullMethod is the gRPC path of a method: "/dieter.v1.CardService/CreateCard".
func FullMethod(method protoreflect.MethodDescriptor) string {
	return "/" + string(method.Parent().FullName()) + "/" + string(method.Name())
}

// Method assigns a relayed Dieter RPC to its lane.
func Method(method string) Lane {
	switch method {
	case dieterv1.MachineService_Health_FullMethodName, dieterv1.MachineService_GetRuntimeStatus_FullMethodName:
		return Control
	}
	switch method {
	case dieterv1.PeerService_GetPeerChanges_FullMethodName, dieterv1.PeerService_GetPeerRecord_FullMethodName,
		dieterv1.PeerService_GetPeerStoreStatus_FullMethodName, dieterv1.PeerService_ListPeerRecords_FullMethodName,
		dieterv1.PeerService_MergePeerRecords_FullMethodName:
		return Replication
	}
	if subscriptions[method] {
		return Subscription
	}
	return Command
}

// DaemonMethod reports whether a gRPC path belongs to the daemon API: any
// dieter.v1 service. It is the only API the gateway relays and direct routes
// serve. It checks the package rather than a method list, so a gateway that is
// older than its daemons still relays newer RPCs; daemons answer unknown
// methods with Unimplemented.
func DaemonMethod(method string) bool {
	rest, ok := strings.CutPrefix(method, "/"+string(dieterPackage)+".")
	if !ok {
		return false
	}
	service, name, ok := strings.Cut(rest, "/")
	return ok && service != "" && name != "" && !strings.ContainsAny(service, "./") && !strings.Contains(name, "/")
}
