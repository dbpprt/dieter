package gateway

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

const publicGatewayMessageBytes = 8 << 10

type gatewayClientAddressKey struct{}
type gatewayLinkAuthenticatedKey struct{}
type gatewayLinkAdmittedKey struct{}

// Only the explicitly configured loopback proxy may supply a client address.
// It must overwrite X-Forwarded-For with one IP, not append an untrusted chain.
func gatewayClientAddress(r *http.Request, proxyMode bool) string {
	host := canonicalPeerHost(r.RemoteAddr)
	address, err := netip.ParseAddr(host)
	if !proxyMode || err != nil || !address.IsLoopback() {
		return host
	}
	values := r.Header.Values("X-Forwarded-For")
	if len(values) == 1 {
		forwarded, err := netip.ParseAddr(strings.TrimSpace(values[0]))
		if err == nil && forwarded.Zone() == "" {
			return forwarded.Unmap().String()
		}
	}
	return host
}

// clientNetworkKey groups IPv6 clients by /64, the smallest prefix a host is
// usually assigned, so rotating addresses inside one network cannot multiply a
// per-client limit.
func clientNetworkKey(address string) string {
	ip, err := netip.ParseAddr(address)
	if err != nil || ip.Is4() {
		return address
	}
	prefix, err := ip.Prefix(64)
	if err != nil {
		return address
	}
	return prefix.String()
}

// clientSlots bounds concurrent unauthenticated work per client network. The
// global pools stay as a backstop; this keeps one source from holding all of
// a pool that every daemon and client shares.
type clientSlots struct {
	mu    sync.Mutex
	limit int
	held  map[string]int
}

func newClientSlots(limit int) *clientSlots {
	return &clientSlots{limit: limit, held: map[string]int{}}
}

func (s *clientSlots) acquire(client string) (func(), bool) {
	key := clientNetworkKey(client)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.held[key] >= s.limit {
		return nil, false
	}
	s.held[key]++
	return sync.OnceFunc(func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.held[key]--; s.held[key] <= 0 {
			delete(s.held, key)
		}
	}), true
}

func canonicalPeerHost(address string) string {
	if host, _, err := net.SplitHostPort(address); err == nil {
		address = host
	}
	if ip, err := netip.ParseAddr(address); err == nil {
		return ip.Unmap().String()
	}
	return address
}

func gatewayContextClientAddress(ctx context.Context) string {
	if address, ok := ctx.Value(gatewayClientAddressKey{}).(string); ok {
		return address
	}
	if value, ok := peer.FromContext(ctx); ok && value.Addr != nil {
		return canonicalPeerHost(value.Addr.String())
	}
	return "unknown"
}

// gRPC allocates from the five-byte envelope before protobuf validation or
// unary interceptors run. Validate public envelopes before returning even the
// header to gRPC. A byte-limited HTTP body alone does not prevent allocation.
// The daemon's first two messages are HELLO and its challenge proof; only
// subsequent, authenticated messages may use the full relay payload limit.
type gatewayEnvelopeReader struct {
	io.ReadCloser
	ctx           context.Context
	cancel        context.CancelFunc
	authenticated <-chan struct{}
	messages      int
	limit         uint32
	header        [5]byte
	headerPos     int
	remaining     uint32
	err           error
}

func limitGatewayEnvelopes(ctx context.Context, body io.ReadCloser, messages int, limit uint32) *gatewayEnvelopeReader {
	ctx, cancel := context.WithCancel(ctx)
	return &gatewayEnvelopeReader{ReadCloser: body, ctx: ctx, cancel: cancel, messages: messages, limit: limit, headerPos: 5}
}

func (r *gatewayEnvelopeReader) Close() error {
	r.cancel()
	return r.ReadCloser.Close()
}

func (r *gatewayEnvelopeReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if r.err != nil {
		return 0, r.err
	}
	if r.headerPos < len(r.header) {
		n := copy(p, r.header[r.headerPos:])
		r.headerPos += n
		return n, nil
	}
	if r.remaining > 0 {
		n, err := r.ReadCloser.Read(p[:min(len(p), int(r.remaining))])
		r.remaining -= uint32(n)
		return n, err
	}
	if r.messages == 0 {
		// ServeHTTP's gRPC transport reads ahead independently of RecvMsg.
		// Do not let it buffer a pipelined third message before proof succeeds.
		if r.authenticated != nil {
			select {
			case <-r.authenticated:
			case <-r.ctx.Done():
				return 0, r.ctx.Err()
			}
		}
		return r.ReadCloser.Read(p)
	}
	if _, r.err = io.ReadFull(r.ReadCloser, r.header[:]); r.err != nil {
		return 0, r.err
	}
	r.remaining = binary.BigEndian.Uint32(r.header[1:])
	if r.header[0] != 0 {
		r.err = status.Error(codes.ResourceExhausted, "compressed public gateway messages are not accepted")
	} else if r.remaining > r.limit {
		r.err = status.Error(codes.ResourceExhausted, "public gateway message exceeds its size limit")
	}
	if r.err != nil {
		return 0, r.err
	}
	r.messages--
	r.headerPos = 0
	return r.Read(p)
}
