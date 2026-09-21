// gateway-turn-probe verifies bidirectional relay payloads with short-lived
// credentials supplied on stdin. It never prints credentials or payloads.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

type request struct {
	ExpectedCertificateSHA256 string `json:"expectedCertificateSHA256,omitempty"`
	Address                   string `json:"address"`
	ServerName                string `json:"serverName"`
	Transport                 string `json:"transport"`
	Username                  string `json:"username"`
	Password                  string `json:"password"`
	ExpectedRelayIP           string `json:"expectedRelayIP"`
	CAFile                    string `json:"caFile,omitempty"`
	HoldSeconds               int    `json:"holdSeconds,omitempty"`
}

type allocation struct {
	client *turn.Client
	socket net.PacketConn
	relay  net.PacketConn
}

func (a *allocation) close() {
	if a.relay != nil {
		_ = a.relay.Close()
	}
	if a.client != nil {
		a.client.Close()
	}
	if a.socket != nil {
		_ = a.socket.Close()
	}
}
func allocate(r request) (_ *allocation, err error) {
	a := &allocation{}
	defer func() {
		if err != nil {
			a.close()
		}
	}()
	switch r.Transport {
	case "udp":
		a.socket, err = net.ListenPacket("udp4", "0.0.0.0:0")
	case "tcp", "tls":
		var c net.Conn
		d := &net.Dialer{Timeout: 8 * time.Second}
		if r.Transport == "tls" {
			config := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: r.ServerName}
			if r.CAFile != "" {
				data, readErr := os.ReadFile(r.CAFile)
				if readErr != nil {
					return nil, readErr
				}
				config.RootCAs = x509.NewCertPool()
				if !config.RootCAs.AppendCertsFromPEM(data) {
					return nil, errors.New("invalid CA")
				}
			}
			c, err = tls.DialWithDialer(d, "tcp4", r.Address, config)
		} else {
			c, err = d.Dial("tcp4", r.Address)
		}
		if err == nil {
			if r.Transport == "tls" && r.ExpectedCertificateSHA256 != "" {
				state := c.(*tls.Conn).ConnectionState()
				if fmt.Sprintf("%x", sha256.Sum256(state.PeerCertificates[0].Raw)) != r.ExpectedCertificateSHA256 {
					_ = c.Close()
					return nil, errors.New("TURN certificate mismatch")
				}
			}
			a.socket = turn.NewSTUNConn(c)
		}
	default:
		return nil, errors.New("unsupported transport")
	}
	if err != nil {
		return nil, err
	}
	factory := logging.NewDefaultLoggerFactory()
	factory.DefaultLogLevel = logging.LogLevelDisabled
	a.client, err = turn.NewClient(&turn.ClientConfig{TURNServerAddr: r.Address, STUNServerAddr: r.Address, Conn: a.socket,
		Username: r.Username, Password: r.Password, RTO: 300 * time.Millisecond, LoggerFactory: factory,
		RequestedAddressFamily: turn.RequestedAddressFamilyIPv4})
	if err != nil {
		return nil, err
	}
	if err = a.client.Listen(); err != nil {
		return nil, err
	}
	a.relay, err = a.client.Allocate()
	if err != nil {
		return nil, err
	}
	ip, _, err := net.SplitHostPort(a.relay.LocalAddr().String())
	if err != nil || ip != r.ExpectedRelayIP {
		return nil, errors.New("incorrect relay address")
	}
	return a, nil
}

func exchange(a, b *allocation) error {
	// Establish both permissions before sending the actual measured payload.
	if err := a.client.CreatePermission(b.relay.LocalAddr()); err != nil {
		return err
	}
	if err := b.client.CreatePermission(a.relay.LocalAddr()); err != nil {
		return err
	}
	payload := make([]byte, 1024)
	if _, err := rand.Read(payload); err != nil {
		return err
	}
	buffer := make([]byte, 2048)
	for _, pair := range [][2]*allocation{{a, b}, {b, a}} {
		if err := pair[1].relay.SetReadDeadline(time.Now().Add(8 * time.Second)); err != nil {
			return err
		}
		if _, err := pair[0].relay.WriteTo(payload, pair[1].relay.LocalAddr()); err != nil {
			return err
		}
		n, from, err := pair[1].relay.ReadFrom(buffer)
		if err != nil {
			return err
		}
		if from.String() != pair[0].relay.LocalAddr().String() || !bytes.Equal(buffer[:n], payload) {
			return errors.New("relay payload mismatch")
		}
	}
	return nil
}

func edge(r request) error {
	var roots *x509.CertPool
	if r.CAFile != "" {
		data, err := os.ReadFile(r.CAFile)
		if err != nil {
			return err
		}
		roots = x509.NewCertPool()
		if !roots.AppendCertsFromPEM(data) {
			return errors.New("invalid edge CA")
		}
	}
	transport := &http.Transport{ForceAttemptHTTP2: true, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, ServerName: r.ServerName},
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "tcp4", r.Address)
		}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, path := range []string{"/healthz", "/", "/dieter.gateway.v1.GatewayService/ListDaemons"} {
		method := "GET"
		var body io.Reader
		if path != "/" && path != "/healthz" {
			method = "POST"
			body = bytes.NewReader(make([]byte, 5))
		}
		req, err := http.NewRequest(method, "https://"+r.ServerName+path, body)
		if err != nil {
			return err
		}
		if method == "POST" {
			req.Header.Set("Content-Type", "application/grpc")
			req.Header.Set("TE", "trailers")
		}
		response, err := client.Do(req)
		if err != nil {
			return err
		}
		_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 32768))
		_ = response.Body.Close()
		if err != nil {
			return err
		}
		if response.ProtoMajor != 2 || response.TLS.Version != tls.VersionTLS13 || response.Header.Get("Alt-Svc") != "" {
			return errors.New("edge protocol mismatch")
		}
		if r.ExpectedCertificateSHA256 != "" && fmt.Sprintf("%x", sha256.Sum256(response.TLS.PeerCertificates[0].Raw)) != r.ExpectedCertificateSHA256 {
			return errors.New("edge certificate mismatch")
		}
		if path == "/healthz" && response.StatusCode != 200 || path == "/" && response.StatusCode != 404 {
			return errors.New("edge status mismatch")
		}
		if method == "POST" && response.Header.Get("Grpc-Status") != "16" && response.Trailer.Get("Grpc-Status") != "16" {
			return errors.New("unauthenticated RPC was not rejected")
		}
	}
	return nil
}

func rejectedTLS(r request) error {
	certificateReceived := false
	// This negative probe never accepts a certificate or sends application data.
	// It must distinguish an edge rejection from a hostname-validation failure.
	config := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: r.ServerName,
		InsecureSkipVerify: true, // verification below deliberately rejects every certificate
		VerifyConnection: func(tls.ConnectionState) error {
			certificateReceived = true
			return errors.New("unexpected certificate")
		},
	}
	if r.Transport == "reject-tls12" {
		config.MaxVersion = tls.VersionTLS12
	}
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 8 * time.Second}, "tcp4", r.Address, config)
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil || certificateReceived {
		return errors.New("edge accepted a forbidden TLS handshake")
	}
	return nil
}

func probe(r request) error {
	if r.Transport == "reject-sni" || r.Transport == "reject-tls12" {
		return rejectedTLS(r)
	}
	if r.Transport == "https" {
		return edge(r)
	}
	if r.HoldSeconds < 0 || r.HoldSeconds > 3600 || r.Username == "" || r.Password == "" || net.ParseIP(r.ExpectedRelayIP) == nil {
		return errors.New("invalid probe request")
	}
	a, err := allocate(r)
	if err != nil {
		return err
	}
	defer a.close()
	b, err := allocate(r)
	if err != nil {
		return err
	}
	defer b.close()
	deadline := time.Now().Add(time.Duration(r.HoldSeconds) * time.Second)
	for {
		if err := exchange(a, b); err != nil {
			return err
		}
		if !time.Now().Before(deadline) {
			break
		}
		time.Sleep(time.Second)
	}
	return nil
}
func main() {
	decoder := json.NewDecoder(io.LimitReader(os.Stdin, 32768))
	decoder.DisallowUnknownFields()
	var r request
	if err := decoder.Decode(&r); err != nil {
		fmt.Fprintln(os.Stderr, "invalid probe input")
		os.Exit(2)
	}
	// An outer deadline also bounds authentication retries in the TURN library.
	timer := time.AfterFunc(time.Duration(r.HoldSeconds+45)*time.Second, func() { fmt.Fprintln(os.Stderr, "probe deadline exceeded"); os.Exit(1) })
	defer timer.Stop()
	if err := probe(r); err != nil {
		fmt.Fprintf(os.Stderr, "TURN %s payload probe failed: %T\n", r.Transport, err)
		os.Exit(1)
	}
	result := map[string]any{"transport": r.Transport, "checksPassed": true}
	if r.Transport == "https" {
		result["http2"] = true
		result["unauthenticatedRejected"] = true
	} else if r.Transport == "udp" || r.Transport == "tcp" || r.Transport == "tls" {
		result["relayAddressVerified"] = true
		result["payloadBidirectional"] = true
		result["heldSeconds"] = r.HoldSeconds
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
}
