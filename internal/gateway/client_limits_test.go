package gateway

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"google.golang.org/grpc/peer"
)

func TestClientNetworkKeyGroupsIPv6ByPrefix(t *testing.T) {
	for _, test := range []struct{ address, want string }{
		{"192.0.2.1", "192.0.2.1"},
		{"2001:db8:1:2:aaaa::1", "2001:db8:1:2::/64"},
		{"2001:db8:1:2:bbbb::9", "2001:db8:1:2::/64"},
		{"2001:db8:1:3::1", "2001:db8:1:3::/64"},
		{"unknown", "unknown"},
	} {
		if got := clientNetworkKey(test.address); got != test.want {
			t.Fatalf("clientNetworkKey(%q)=%q want %q", test.address, got, test.want)
		}
	}
}

func TestClientSlotsBoundEachNetworkIndependently(t *testing.T) {
	slots := newClientSlots(2)
	first, ok := slots.acquire("2001:db8::1")
	if !ok {
		t.Fatal("first slot refused")
	}
	if _, ok := slots.acquire("2001:db8::2"); !ok {
		t.Fatal("second slot refused")
	}
	if _, ok := slots.acquire("2001:db8::3"); ok {
		t.Fatal("rotating addresses in one /64 escaped the limit")
	}
	if release, ok := slots.acquire("192.0.2.1"); !ok {
		t.Fatal("one network blocked another")
	} else {
		release()
	}
	first()
	first()
	if _, ok := slots.acquire("2001:db8::4"); !ok {
		t.Fatal("released slot was not reusable")
	}
	if _, ok := slots.acquire("2001:db8::5"); ok {
		t.Fatal("a repeated release freed a second slot")
	}
}

func TestEnrollmentReservationsAreBoundedPerNetworkUntilExpiry(t *testing.T) {
	service := NewService(nil, nil, nil, nil, Config{})
	from := func(address string) *peer.Peer {
		return &peer.Peer{Addr: &net.TCPAddr{IP: net.ParseIP(address), Port: 1234}}
	}
	expires := time.Now().Add(10 * time.Minute)
	for index := range maxActiveEnrollmentsPerClient {
		address := fmt.Sprintf("2001:db8::%x", index+1)
		if !service.reserveEnrollment(peer.NewContext(t.Context(), from(address)), expires) {
			t.Fatalf("reservation %d refused", index)
		}
	}
	if service.reserveEnrollment(peer.NewContext(t.Context(), from("2001:db8::ffff")), expires) {
		t.Fatal("one network exceeded its pending enrollments")
	}
	if !service.reserveEnrollment(peer.NewContext(t.Context(), from("192.0.2.1")), expires) {
		t.Fatal("one network blocked another")
	}
	for key, active := range service.enrollActive {
		for index := range active {
			active[index] = time.Now().Add(-time.Second)
		}
		service.enrollActive[key] = active
	}
	if !service.reserveEnrollment(peer.NewContext(t.Context(), from("2001:db8::ffff")), expires) {
		t.Fatal("expired reservations were not released")
	}
}

func TestGatewayBoundsHandshakesPerClientBeforeReadingBody(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	gateway, err := NewServer(Config{}, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.APIGRPC.Stop()
	defer gateway.RelayGRPC.Stop()
	gateway.Hub.handshakeClients.held["192.0.2.1"] = maxDaemonHandshakesPerClient
	connect := func(remote string, body *repeatedBody) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "/dieter.gateway.v1.DaemonLinkService/Connect", body)
		request.ProtoMajor, request.RemoteAddr = 2, remote
		request.Header.Set("Content-Type", "application/grpc")
		response := httptest.NewRecorder()
		gateway.HTTPHandler.ServeHTTP(response, request)
		return response
	}
	saturated := &repeatedBody{}
	if response := connect("192.0.2.1:1234", saturated); response.Header().Get("Grpc-Status") != "8" || saturated.read != 0 {
		t.Fatalf("saturated client read %d bytes, headers=%v", saturated.read, response.Header())
	}
	if len(gateway.Hub.handshakes) != 0 {
		t.Fatal("a refused client consumed a global handshake slot")
	}
	other := &repeatedBody{}
	connect("192.0.2.2:1234", other)
	if other.read == 0 {
		t.Fatal("one client's handshakes blocked another")
	}
	if len(gateway.Hub.handshakes) != 0 || gateway.Hub.handshakeClients.held["192.0.2.2"] != 0 {
		t.Fatal("a finished handshake retained its slots")
	}
}
