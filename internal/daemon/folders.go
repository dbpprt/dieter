package daemon

import (
	"context"

	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

// FolderPeerDialer reaches the other daemons of the account for synced
// folders over the same roster-pinned carriers peer sync uses: a direct
// candidate, a WebRTC data channel or a relay tunnel on the replication lane.
func FolderPeerDialer(identity *link.Identity, trust *link.Trust) hostfolders.Dialer {
	return func(ctx context.Context, daemonID string) (dieterclient.Client, func(), error) {
		gateway, err := link.DialGateway(ctx, identity, false)
		if err != nil {
			return nil, nil, err
		}
		peer, err := peersync.DialPeer(ctx, identity, trust, gateway, daemonID)
		if err != nil {
			gateway.Close()
			return nil, nil, err
		}
		return peer.Client, func() {
			peer.Close()
			gateway.Close()
		}, nil
	}
}
