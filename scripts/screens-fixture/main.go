// Command screens-fixture serves the real Dieter gRPC API and native capture
// backend with disposable identity and storage on a random loopback listener.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/trust"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
	"google.golang.org/protobuf/proto"
)

func main() {
	helper := flag.String("helper", "", "signed macOS capture helper")
	source := flag.String("source", "native-synthetic", "screen or native-synthetic")
	ready := flag.String("ready", "", "write connection JSON to this file")
	flag.Parse()
	if err := run(*helper, *source, *ready); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(helper, kind, ready string) error {
	if helper == "" || ready == "" || (kind != "screen" && kind != "native-synthetic") {
		return fmt.Errorf("helper, ready and a native source are required")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	parent := os.Getppid()
	go func() {
		timer := time.NewTicker(time.Second)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
				if syscall.Kill(parent, 0) != nil {
					cancel()
					return
				}
			}
		}
	}()
	root, err := os.MkdirTemp("", "dieter-screens-fixture-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	data := store.New(root)
	if err = data.Ensure(); err != nil {
		return err
	}
	if _, err = data.UpdateRemoteDesktopSettings(true, true); err != nil {
		return err
	}
	gp, gk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	dp, dk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	publicDER, err := x509.MarshalPKIXPublicKey(gp)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Isolated screens fixture"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, dp, dk)
	if err != nil {
		return err
	}
	config := &gatewayv1.RTCConfiguration{ExpiresAt: now.Add(30 * time.Minute).Format(time.RFC3339Nano), DaemonId: "d_screens_fixture", OperatorSubject: "github:1", ConfigurationId: "rtc_screens_fixture", DaemonGeneration: 1, IssuedAt: now.Format(time.RFC3339Nano)}
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(config)
	if err != nil {
		return err
	}
	hash := sha256.Sum256(raw)
	envelope, err := trust.SignCompact(gk, trust.RTCConfigurationClaims{Issuer: "http://screens.fixture", Audience: "board-daemon:d_screens_fixture", Subject: "github:1", ID: config.ConfigurationId, ConfigurationHash: base64.RawURLEncoding.EncodeToString(hash[:]), DaemonGeneration: 1, IssuedAt: now.Unix(), ExpiresAt: now.Add(30 * time.Minute).Unix()})
	if err != nil {
		return err
	}
	config.SignedEnvelope = []byte(envelope)
	manager := remotedesktop.New(remotedesktop.Options{Identity: remotedesktop.Identity{DaemonID: config.DaemonId, GatewayURL: "http://screens.fixture", Generation: 1, PrivateKey: dk, GatewaySigningPublicKey: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER})}, Source: remotedesktop.SourceOptions{Kind: kind, HelperPath: helper}})
	defer manager.Shutdown(context.Background())
	api := server.NewWithOptions(data, slog.Default(), server.Options{RemoteDesktop: manager})
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer listener.Close()
	handler := api.Handler()
	httpServer := &http.Server{Handler: h2c.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("x-dieter-operator-subject", "github:1")
		handler.ServeHTTP(w, r)
	}), &http2.Server{})}
	defer httpServer.Close()
	go func() { _ = httpServer.Serve(listener) }()
	configRaw, _ := proto.Marshal(config)
	output, _ := json.Marshal(map[string]any{"url": "http://" + listener.Addr().String(), "certificate": pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), "rtc": configRaw})
	if err = os.WriteFile(ready, output, 0600); err != nil {
		return err
	}
	<-ctx.Done()
	return nil
}
