package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net"
	"sort"
	"sync/atomic"
	"time"

	"github.com/dbpprt/dieter/internal/controlrtc"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// peerGatewayConn authenticates autonomous peers with short-lived possession
// proofs. The gateway resolves the account from current enrollment, never input.
type peerGatewayConn struct {
	grpc.ClientConnInterface
	identity *Identity
	target   string
}

func (c peerGatewayConn) auth(ctx context.Context) context.Context {
	values, _ := metadata.FromOutgoingContext(ctx)
	values = values.Copy()
	values.Set("authorization", "Bearer "+linkauth.SignPeer(c.identity.PrivateKey, c.identity.ID, c.identity.GatewayURL, c.identity.Generation, time.Now()))
	if c.target != "" {
		values.Set("x-dieter-daemon-id", c.target)
	}
	return metadata.NewOutgoingContext(ctx, values)
}
func (c peerGatewayConn) Invoke(ctx context.Context, method string, in, out any, opts ...grpc.CallOption) error {
	return c.ClientConnInterface.Invoke(c.auth(ctx), method, in, out, opts...)
}
func (c peerGatewayConn) NewStream(ctx context.Context, desc *grpc.StreamDesc, method string, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	return c.ClientConnInterface.NewStream(c.auth(ctx), desc, method, opts...)
}

type PeerConnection struct {
	Client dieterv1.DieterServiceClient
	Route  string
	close  func()
}

func (c *PeerConnection) Close() {
	if c != nil && c.close != nil {
		c.close()
	}
}

// DialPeer reuses enrolled TLS identity and existing controlrtc byte framing.
// Connections are short-lived anti-entropy rounds; bearer renewal is performed
// by the next round, well within the five-minute access-token lifetime.
func DialPeer(ctx context.Context, identity *Identity, gatewayConnection grpc.ClientConnInterface, target string) (*PeerConnection, error) {
	return dialPeer(ctx, identity, gatewayConnection, target, false)
}

func dialPeer(ctx context.Context, identity *Identity, gatewayConnection grpc.ClientConnInterface, target string, relayOnly bool) (*PeerConnection, error) {
	gateway := gatewayv1.NewGatewayServiceClient(peerGatewayConn{gatewayConnection, identity, ""})
	route, err := gateway.ResolveDaemonRoute(ctx, &gatewayv1.DaemonRef{DaemonId: target})
	if err != nil {
		return nil, err
	}
	token, err := gateway.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: target})
	if err != nil {
		return nil, err
	}
	for i, candidate := range route.GetDirectCandidates() {
		if i >= 4 || relayOnly {
			break
		}
		attempt, cancel := context.WithTimeout(ctx, time.Second)
		connection, e := DialDirect(attempt, net.JoinHostPort(candidate.GetHost(), fmt.Sprint(candidate.GetPort())), target, route.GetDaemonCaPem(), token.GetAccessToken())
		if e == nil {
			_, e = dieterv1.NewDieterServiceClient(connection).GetPeerStoreStatus(attempt, &emptypb.Empty{})
		}
		cancel()
		if e == nil {
			return &PeerConnection{dieterv1.NewDieterServiceClient(connection), "direct-tls", func() { _ = connection.Close() }}, nil
		}
		if connection != nil {
			_ = connection.Close()
		}
	}
	relay := dieterv1.NewDieterServiceClient(peerGatewayConn{gatewayConnection, identity, target})
	if route.GetControlWebrtc() {
		attempt, cancel := context.WithTimeout(ctx, 15*time.Second)
		configuration, e := gateway.GetRTCConfiguration(attempt, &gatewayv1.DaemonRef{DaemonId: target})
		if e == nil {
			stream, session, dialErr := controlrtc.DialWithPolicy(attempt, configuration, func(call context.Context, r *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
				return relay.StartControlConnection(call, r)
			}, relayOnly)
			if dialErr == nil {
				var used atomic.Bool
				connection, tlsErr := DialDirectWithCredentials(attempt, "passthrough:///peer-control", target, route.GetDaemonCaPem(), daemonTokenCredential{token.GetAccessToken()}, grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
					if used.Swap(true) {
						return nil, controlrtc.ErrUnavailable
					}
					return stream, nil
				}))
				if tlsErr == nil {
					client := dieterv1.NewDieterServiceClient(connection)
					_, tlsErr = client.GetPeerStoreStatus(attempt, &emptypb.Empty{})
					if tlsErr == nil {
						info, infoErr := client.GetControlConnection(attempt, &dieterv1.ControlConnectionRef{SessionId: session.GetSessionId()})
						if infoErr == nil {
							cancel()
							return &PeerConnection{client, "webrtc-" + info.GetMode(), func() { _ = connection.Close(); _ = stream.Close() }}, nil
						}
					}
				}
				if connection != nil {
					_ = connection.Close()
				}
				_ = stream.Close()
			}
		}
		cancel()
	}
	if !route.GetRelayAvailable() {
		return nil, fmt.Errorf("peer %s has no available route", target)
	}
	return &PeerConnection{relay, "relay", func() {}}, nil
}

// PeerSync runs only from serve. No handler construction starts background work.
// One peer at a time and two peers per round bound connections and fanout. All
// actors can write; rounds rotate through online account members without a leader.
type PeerSync struct {
	Identity  *Identity
	Store     *store.Store
	Log       *slog.Logger
	Interval  time.Duration
	RelayOnly bool // Require TURN for isolated qualification; false preserves normal route preference.
	next      int
}

func (p *PeerSync) Run(ctx context.Context) {
	interval := p.Interval
	if interval <= 0 {
		interval = 15 * time.Second
	}
	logger := p.Log
	if logger == nil {
		logger = slog.Default()
	}
	delay := interval
	changes := p.Store.PeerChangesAvailable()
	for ctx.Err() == nil {
		round, cancel := context.WithTimeout(ctx, 100*time.Second)
		err := p.Round(round)
		cancel()
		if err != nil && ctx.Err() == nil {
			logger.Warn("peer store synchronization pending", "error", err)
		}
		if err != nil {
			delay = min(max(delay*2, interval), 2*time.Minute)
		} else {
			delay = interval
		}
		timer := time.NewTimer(delay + time.Duration(rand.Int64N(int64(interval/4+1))))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		case <-changes:
			timer.Stop()
			// Coalesce bursts and forwarded pages, and retain backoff when the
			// account control plane is unavailable. No tight retry on failures.
			pause := time.Second
			if err != nil {
				pause = delay
			}
			coalesce := time.NewTimer(pause)
			select {
			case <-ctx.Done():
				coalesce.Stop()
				return
			case <-coalesce.C:
			}
		}
	}
}
func (p *PeerSync) Round(ctx context.Context) error {
	if err := p.Store.FlushSharedOutbox(); err != nil {
		return err
	}
	current, err := LoadIdentity(p.Store.Root)
	if err != nil || !current.Enrolled() || current.ID != p.Identity.ID || current.GatewayURL != p.Identity.GatewayURL || current.Generation != p.Identity.Generation {
		return fmt.Errorf("peer enrollment changed; restart daemon")
	}

	conn, err := dialGateway(ctx, p.Identity, false)
	if err != nil {
		return err
	}
	defer conn.Close()
	gateway := gatewayv1.NewGatewayServiceClient(peerGatewayConn{conn, p.Identity, ""})
	discovery, cancel := context.WithTimeout(ctx, 10*time.Second)
	account, err := gateway.GetAccount(discovery, &emptypb.Empty{})
	cancel()
	if err != nil {
		return err
	}
	if account.GetGithubId() <= 0 {
		return fmt.Errorf("invalid peer account")
	}
	subject := fmt.Sprintf("github:%d", account.GetGithubId())
	scope := peerstore.Revision([]string{p.Identity.GatewayURL, subject})
	binding, err := p.Store.BindPeerAccount(scope, subject, p.Identity.ID, p.Identity.GatewayURL)
	if err != nil {
		return err
	}
	discovery, cancel = context.WithTimeout(ctx, 10*time.Second)
	directory, err := gateway.ListDaemons(discovery, &emptypb.Empty{})
	cancel()
	if err != nil {
		return err
	}
	peers := []string{}
	var lastErr error
	for _, d := range directory.GetDaemons() {
		if d.GetId() != p.Identity.ID && d.GetOnline() {
			if d.GetApiVersion() != protocol.Version {
				lastErr = fmt.Errorf("machine %s requires update to contract %s", d.GetName(), protocol.Version)
				continue
			}
			peers = append(peers, d.GetId())
		}
	}
	sort.Strings(peers)
	if len(peers) == 0 {
		return lastErr
	}
	for n := 0; n < 2 && n < len(peers); n++ {
		target := peers[p.next%len(peers)]
		p.next++
		attempt, cancel := context.WithTimeout(ctx, 40*time.Second)
		connection, e := dialPeer(attempt, p.Identity, conn, target, p.RelayOnly)
		if e == nil {
			e = p.Exchange(attempt, binding, connection.Client)
			if e == nil {
				e = p.Store.PeerSynced(binding, target, connection.Route)
			}
			connection.Close()
		}
		cancel()
		if e != nil {
			lastErr = fmt.Errorf("peer %s: %w", target, e)
		}
	}
	return lastErr
}

// Exchange resumes each direction from a durable local transport checkpoint.
// Merge commits before checkpoint advancement; lost replies only repeat joins.
func (p *PeerSync) Exchange(ctx context.Context, binding store.PeerIdentity, client dieterv1.DieterServiceClient) error {
	statusInfo, err := client.GetPeerStoreStatus(ctx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if statusInfo.GetAccount() != binding.Account {
		return fmt.Errorf("peer account mismatch")
	}
	peer := statusInfo.GetActor()
	pull, err := p.Store.PeerCheckpoint(binding.Account, peer, "pull")
	if err != nil {
		return err
	}
	for page := 0; page < peerstore.MaxRecords/peerstore.PageSize+1; page++ {
		changes, e := client.GetPeerChanges(ctx, &dieterv1.PeerChangesRequest{Account: binding.Account, Epoch: pull.Epoch, AfterSequence: pull.Sequence})
		if status.Code(e) == codes.Aborted && pull.Epoch != "" {
			pull = store.PeerCheckpoint{}
			continue
		}
		if e != nil {
			return e
		}
		if changes.GetEpoch() == "" || changes.GetAfterSequence() < pull.Sequence || len(changes.GetRecords()) > peerstore.PageSize {
			return fmt.Errorf("invalid peer changes")
		}
		records := make([]peerstore.Record, 0, len(changes.GetRecords()))
		for _, r := range changes.GetRecords() {
			record := peerstore.Record{Kind: r.GetKind(), ID: r.GetId()}
			for _, v := range r.GetVersions() {
				record.Versions = append(record.Versions, peerstore.Version{Clock: v.GetClock(), Value: v.GetValueJson(), Deleted: v.GetDeleted(), Provenance: v.GetProvenanceJson()})
			}
			records = append(records, record)
		}
		if err = p.Store.MergePeerRecords(binding, records); err != nil {
			return err
		}
		if changes.GetMore() && changes.GetAfterSequence() == pull.Sequence {
			return fmt.Errorf("peer made no progress")
		}
		pull = store.PeerCheckpoint{Epoch: changes.GetEpoch(), Sequence: changes.GetAfterSequence()}
		if err = p.Store.SavePeerCheckpoint(binding, peer, "pull", pull); err != nil {
			return err
		}
		if !changes.GetMore() {
			break
		}
	}
	push, err := p.Store.PeerCheckpoint(binding.Account, peer, "push")
	if err != nil {
		return err
	}
	for page := 0; page < peerstore.MaxRecords/peerstore.PageSize+1; page++ {
		changes, e := p.Store.PeerChanges(binding.Account, push.Epoch, push.Sequence)
		if errors.Is(e, peerstore.ErrConflict) && push.Epoch != "" {
			push = store.PeerCheckpoint{}
			continue
		}
		if e != nil {
			return e
		}
		request := &dieterv1.MergePeerRecordsRequest{Account: binding.Account}
		for _, r := range changes.Records {
			record := &dieterv1.PeerRecord{Kind: r.Kind, Id: r.ID}
			for _, v := range r.Versions {
				record.Versions = append(record.Versions, &dieterv1.PeerVersion{Clock: v.Clock, ValueJson: v.Value, Deleted: v.Deleted, ProvenanceJson: v.Provenance})
			}
			request.Records = append(request.Records, record)
		}
		if len(request.Records) > 0 {
			if _, err = client.MergePeerRecords(ctx, request); err != nil {
				return err
			}
		}
		push = store.PeerCheckpoint{Epoch: changes.Epoch, Sequence: changes.After}
		if err = p.Store.SavePeerCheckpoint(binding, peer, "push", push); err != nil {
			return err
		}
		if !changes.More {
			break
		}
	}
	return nil
}
