//go:build e2e

package gateway

import "github.com/dbpprt/dieter/internal/transport/relay"

// Exports for the external e2e tests in this directory, which run full
// topologies and therefore cannot live in package gateway.

// LaneLink is one authenticated link connection of a daemon lane.
type LaneLink = daemonLink

// LaneLink returns the current link of daemonID's lane, or nil.
func (h *Hub) LaneLink(daemonID string, lane relay.Lane) *LaneLink {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.relayLinks[daemonID][lane]
}

// Close drops the link connection as a lost transport does; the daemon
// reconnects that lane.
func (l *daemonLink) Close() { l.close() }
