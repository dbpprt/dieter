package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/pion/webrtc/v4"
)

func main() {
	config, err := parseConfig(os.Args[1:])
	if err != nil {
		log.Fatal(err)
	}
	logger := log.New(os.Stderr, "screenshare-experiment: ", log.LstdFlags|log.Lmicroseconds)
	source, err := newFrameSource(config, logger)
	if err != nil {
		logger.Fatal(err)
	}
	server := newExperimentServer(config, source, logger)
	defer server.close()

	listener, err := net.Listen("tcp", config.listen)
	if err != nil {
		logger.Fatalf("listen on %s: %v", config.listen, err)
	}
	defer listener.Close()

	httpServer := &http.Server{
		Handler:           server.handler(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- httpServer.Serve(listener) }()

	viewerURL := viewerURL(listener.Addr(), config.token)
	logger.Printf("source: %s", source.Description())
	logger.Printf("viewer: %s", viewerURL)
	if !isLoopbackListener(listener.Addr()) {
		logger.Printf("warning: signaling is plain HTTP on a non-loopback listener; use only on a trusted network or through an SSH tunnel")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	select {
	case <-ctx.Done():
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Fatalf("serve: %v", err)
		}
	}
	shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server.close()
	if err := httpServer.Shutdown(shutdownContext); err != nil {
		logger.Printf("HTTP shutdown: %v", err)
	}
}

func parseConfig(arguments []string) (experimentConfig, error) {
	flags := flag.NewFlagSet("1-webrtc-e2e", flag.ContinueOnError)
	listen := flags.String("listen", "127.0.0.1:8787", "HTTP signaling/viewer listen address")
	token := flags.String("token", "", "viewer bearer token; generated when empty")
	source := flags.String("source", "screen", "frame source: screen or synthetic")
	ffmpegPath := flags.String("ffmpeg", "ffmpeg", "FFmpeg executable")
	display := flags.String("display", "", "capture display: macOS AVFoundation index, Windows source, or X11 DISPLAY")
	fps := flags.Int("fps", 30, "capture frames per second")
	bitrateKbps := flags.Int("bitrate-kbps", 4_000, "VP8 target bitrate in kbps")
	stunURLs := flags.String("stun", "", "comma-separated STUN URLs, for example stun:stun.example.com:3478")
	turnURLs := flags.String("turn", "", "comma-separated TURN URLs")
	turnUsername := flags.String("turn-username", "", "TURN username")
	turnPassword := flags.String("turn-password", "", "TURN credential")
	gatherTimeout := flags.Duration("gather-timeout", 12*time.Second, "non-trickle ICE gathering timeout")
	sessionTimeout := flags.Duration("session-timeout", 30*time.Minute, "maximum capture session lifetime")
	if err := flags.Parse(arguments); err != nil {
		return experimentConfig{}, err
	}
	if flags.NArg() != 0 {
		return experimentConfig{}, fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if *fps < 1 || *fps > 120 {
		return experimentConfig{}, fmt.Errorf("fps must be between 1 and 120")
	}
	if *bitrateKbps < 100 || *bitrateKbps > 100_000 {
		return experimentConfig{}, fmt.Errorf("bitrate-kbps must be between 100 and 100000")
	}
	if *gatherTimeout <= 0 || *gatherTimeout > time.Minute {
		return experimentConfig{}, fmt.Errorf("gather-timeout must be greater than zero and at most one minute")
	}
	if *sessionTimeout < time.Minute || *sessionTimeout > 24*time.Hour {
		return experimentConfig{}, fmt.Errorf("session-timeout must be between one minute and 24 hours")
	}
	if *token == "" {
		generated, err := randomToken()
		if err != nil {
			return experimentConfig{}, err
		}
		*token = generated
	}
	iceServers, err := parseICEServers(*stunURLs, *turnURLs, *turnUsername, *turnPassword)
	if err != nil {
		return experimentConfig{}, err
	}
	return experimentConfig{
		listen:         *listen,
		token:          *token,
		source:         *source,
		ffmpegPath:     *ffmpegPath,
		display:        *display,
		fps:            *fps,
		bitrateKbps:    *bitrateKbps,
		iceServers:     iceServers,
		gatherTimeout:  *gatherTimeout,
		sessionTimeout: *sessionTimeout,
	}, nil
}

func parseICEServers(stunCSV, turnCSV, username, credential string) ([]webrtc.ICEServer, error) {
	servers := make([]webrtc.ICEServer, 0, 2)
	if urls := splitURLs(stunCSV); len(urls) > 0 {
		for _, raw := range urls {
			if !strings.HasPrefix(raw, "stun:") && !strings.HasPrefix(raw, "stuns:") {
				return nil, fmt.Errorf("invalid STUN URL %q", raw)
			}
		}
		servers = append(servers, webrtc.ICEServer{URLs: urls})
	}
	if urls := splitURLs(turnCSV); len(urls) > 0 {
		if username == "" || credential == "" {
			return nil, errors.New("TURN URLs require -turn-username and -turn-password")
		}
		for _, raw := range urls {
			if !strings.HasPrefix(raw, "turn:") && !strings.HasPrefix(raw, "turns:") {
				return nil, fmt.Errorf("invalid TURN URL %q", raw)
			}
		}
		servers = append(servers, webrtc.ICEServer{URLs: urls, Username: username, Credential: credential})
	}
	return servers, nil
}

func splitURLs(value string) []string {
	var urls []string
	for _, item := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			urls = append(urls, trimmed)
		}
	}
	return urls
}

func randomToken() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("read system randomness: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func viewerURL(address net.Addr, token string) string {
	host := "127.0.0.1"
	port := "8787"
	if tcp, ok := address.(*net.TCPAddr); ok {
		port = strconv.Itoa(tcp.Port)
		if tcp.IP != nil && !tcp.IP.IsUnspecified() {
			host = tcp.IP.String()
		}
	}
	return (&url.URL{
		Scheme:   "http",
		Host:     net.JoinHostPort(host, port),
		Path:     "/",
		Fragment: "token=" + token,
	}).String()
}

func isLoopbackListener(address net.Addr) bool {
	tcp, ok := address.(*net.TCPAddr)
	return ok && tcp.IP != nil && tcp.IP.IsLoopback()
}
