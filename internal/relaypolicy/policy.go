// Package relaypolicy owns the gateway and daemon's transport resource contract.
// Lanes change scheduling, never authorization or execution ownership.
package relaypolicy

import (
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
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

// Method uses the declared service's streaming contract, including WatchKV and
// StartRemoteDesktop. Unknown methods receive ordinary admission and remain
// subject to the daemon's explicit Unimplemented response.
var subscriptions = func() map[string]bool {
	result := map[string]bool{}
	methods := dieterv1.File_dieter_v1_dieter_proto.Services().ByName("DieterService").Methods()
	for i := 0; i < methods.Len(); i++ {
		m := methods.Get(i)
		if m.IsStreamingServer() {
			result[string(m.Name())] = true
		}
	}
	return result
}()

func Method(method string) Lane {
	if !strings.HasPrefix(method, "/dieter.v1.DieterService/") {
		return Command
	}
	name := strings.TrimPrefix(method, "/dieter.v1.DieterService/")
	switch name {
	case "Health", "GetRuntimeStatus":
		return Control
	case "GetPeerChanges", "GetPeerRecord", "GetPeerStoreStatus", "ListPeerRecords", "MergePeerRecords":
		return Replication
	}
	if subscriptions[name] {
		return Subscription
	}
	return Command
}
