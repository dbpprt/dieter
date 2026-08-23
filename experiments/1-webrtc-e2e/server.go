package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const maxSignalingBytes = 1 << 20

//go:embed web/index.html
var indexHTML []byte

type experimentConfig struct {
	listen         string
	token          string
	source         string
	ffmpegPath     string
	display        string
	fps            int
	bitrateKbps    int
	iceServers     []webrtc.ICEServer
	gatherTimeout  time.Duration
	sessionTimeout time.Duration
}

type experimentServer struct {
	config  experimentConfig
	api     *webrtc.API
	source  FrameSource
	logger  *log.Logger
	offerMu sync.Mutex
	mu      sync.RWMutex
	session *desktopSession
}

type desktopSession struct {
	id        string
	createdAt time.Time
	pc        *webrtc.PeerConnection
	cancel    context.CancelFunc
	closeOnce sync.Once
	startOnce sync.Once
	frames    atomic.Uint64
	bytes     atomic.Uint64

	mu          sync.RWMutex
	peerState   string
	iceState    string
	sourceState string
	lastError   string
}

type browserConfig struct {
	ICEServers []browserICEServer `json:"iceServers"`
	Source     string             `json:"source"`
	FPS        int                `json:"fps"`
	Bitrate    int                `json:"bitrateKbps"`
}

type browserICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential any      `json:"credential,omitempty"`
}

type sessionStatus struct {
	Active      bool   `json:"active"`
	ID          string `json:"id,omitempty"`
	CreatedAt   string `json:"createdAt,omitempty"`
	PeerState   string `json:"peerState,omitempty"`
	ICEState    string `json:"iceState,omitempty"`
	SourceState string `json:"sourceState,omitempty"`
	LastError   string `json:"lastError,omitempty"`
	Frames      uint64 `json:"frames,omitempty"`
	Bytes       uint64 `json:"bytes,omitempty"`
	Route       string `json:"route,omitempty"`
}

func newExperimentServer(config experimentConfig, source FrameSource, logger *log.Logger) *experimentServer {
	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetIncludeLoopbackCandidate(true)
	return &experimentServer{
		config: config,
		api:    webrtc.NewAPI(webrtc.WithSettingEngine(settingEngine)),
		source: source,
		logger: logger,
	}
}

func (s *experimentServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", s.handleIndex)
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /config", s.requireToken(s.handleConfig))
	mux.HandleFunc("GET /status", s.requireToken(s.handleStatus))
	mux.HandleFunc("POST /offer", s.requireToken(s.handleOffer))
	mux.HandleFunc("POST /close", s.requireToken(s.handleClose))
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; media-src blob:")
		next.ServeHTTP(w, r)
	})
}

func (s *experimentServer) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		provided := strings.TrimPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ")
		if len(provided) != len(s.config.token) || subtle.ConstantTimeCompare([]byte(provided), []byte(s.config.token)) != 1 {
			http.Error(w, "experiment token required", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *experimentServer) handleIndex(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(indexHTML)
}

func (s *experimentServer) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *experimentServer) handleConfig(w http.ResponseWriter, _ *http.Request) {
	servers := make([]browserICEServer, 0, len(s.config.iceServers))
	for _, server := range s.config.iceServers {
		servers = append(servers, browserICEServer{
			URLs:       append([]string(nil), server.URLs...),
			Username:   server.Username,
			Credential: server.Credential,
		})
	}
	writeJSON(w, http.StatusOK, browserConfig{
		ICEServers: servers,
		Source:     s.source.Description(),
		FPS:        s.config.fps,
		Bitrate:    s.config.bitrateKbps,
	})
}

func (s *experimentServer) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.status())
}

func (s *experimentServer) handleOffer(w http.ResponseWriter, r *http.Request) {
	s.offerMu.Lock()
	defer s.offerMu.Unlock()

	r.Body = http.MaxBytesReader(w, r.Body, maxSignalingBytes)
	defer r.Body.Close()
	var offer webrtc.SessionDescription
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&offer); err != nil {
		http.Error(w, "invalid WebRTC offer: "+err.Error(), http.StatusBadRequest)
		return
	}
	if offer.Type != webrtc.SDPTypeOffer || strings.TrimSpace(offer.SDP) == "" {
		http.Error(w, "an SDP offer is required", http.StatusBadRequest)
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		http.Error(w, "invalid trailing signaling data", http.StatusBadRequest)
		return
	}

	session, answer, err := s.answer(r.Context(), offer)
	if err != nil {
		s.logger.Printf("offer failed: %v", err)
		http.Error(w, "create WebRTC answer: "+err.Error(), http.StatusBadGateway)
		return
	}
	s.replaceSession(session)
	writeJSON(w, http.StatusOK, answer)
}

func (s *experimentServer) answer(requestContext context.Context, offer webrtc.SessionDescription) (*desktopSession, *webrtc.SessionDescription, error) {
	pc, err := s.api.NewPeerConnection(webrtc.Configuration{ICEServers: s.config.iceServers})
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.config.sessionTimeout)
	session := &desktopSession{
		id:          randomID(),
		createdAt:   time.Now().UTC(),
		pc:          pc,
		cancel:      cancel,
		peerState:   webrtc.PeerConnectionStateNew.String(),
		iceState:    webrtc.ICEConnectionStateNew.String(),
		sourceState: "waiting for peer connection",
	}
	fail := func(cause error) (*desktopSession, *webrtc.SessionDescription, error) {
		session.close()
		return nil, nil, cause
	}

	videoTrack, err := webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90_000},
		"screen",
		"dieter-experiment",
	)
	if err != nil {
		return fail(err)
	}
	sender, err := pc.AddTrack(videoTrack)
	if err != nil {
		return fail(err)
	}
	go drainRTCP(ctx, sender)

	pc.OnDataChannel(func(channel *webrtc.DataChannel) {
		if channel.Label() != "probe" {
			return
		}
		channel.OnMessage(func(message webrtc.DataChannelMessage) {
			text := string(message.Data)
			if strings.HasPrefix(text, "ping:") {
				_ = channel.SendText("pong:" + strings.TrimPrefix(text, "ping:"))
			}
		})
	})
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		session.update(func(value *desktopSession) { value.iceState = state.String() })
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		session.update(func(value *desktopSession) { value.peerState = state.String() })
		switch state {
		case webrtc.PeerConnectionStateConnected:
			session.startOnce.Do(func() {
				go s.streamSource(ctx, session, videoTrack)
			})
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			session.cancel()
		}
	})

	if err := pc.SetRemoteDescription(offer); err != nil {
		return fail(err)
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return fail(err)
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		return fail(err)
	}
	select {
	case <-gatherComplete:
	case <-requestContext.Done():
		return fail(requestContext.Err())
	case <-time.After(s.config.gatherTimeout):
		return fail(errors.New("ICE gathering timed out"))
	}
	local := pc.LocalDescription()
	if local == nil {
		return fail(errors.New("local WebRTC description is missing"))
	}
	copy := *local
	go func() {
		<-ctx.Done()
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			session.setError("session lease expired")
		}
		session.close()
	}()
	return session, &copy, nil
}

func (s *experimentServer) streamSource(ctx context.Context, session *desktopSession, track *webrtc.TrackLocalStaticSample) {
	session.update(func(value *desktopSession) { value.sourceState = "streaming " + s.source.Description() })
	err := s.source.Stream(ctx, func(sample media.Sample) error {
		if err := track.WriteSample(sample); err != nil {
			return err
		}
		session.frames.Add(1)
		session.bytes.Add(uint64(len(sample.Data)))
		return nil
	})
	if err != nil && ctx.Err() == nil {
		session.setError(err.Error())
		s.logger.Printf("session %s capture stopped: %v", session.id, err)
		_ = session.pc.Close()
		return
	}
	session.update(func(value *desktopSession) { value.sourceState = "stopped" })
}

func drainRTCP(ctx context.Context, sender *webrtc.RTPSender) {
	buffer := make([]byte, 1500)
	for {
		if _, _, err := sender.Read(buffer); err != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

func (s *experimentServer) handleClose(w http.ResponseWriter, _ *http.Request) {
	s.replaceSession(nil)
	w.WriteHeader(http.StatusNoContent)
}

func (s *experimentServer) replaceSession(next *desktopSession) {
	s.mu.Lock()
	previous := s.session
	s.session = next
	s.mu.Unlock()
	if previous != nil && previous != next {
		previous.close()
	}
}

func (s *experimentServer) status() sessionStatus {
	s.mu.RLock()
	session := s.session
	s.mu.RUnlock()
	if session == nil {
		return sessionStatus{Active: false}
	}
	session.mu.RLock()
	status := sessionStatus{
		Active:      true,
		ID:          session.id,
		CreatedAt:   session.createdAt.Format(time.RFC3339Nano),
		PeerState:   session.peerState,
		ICEState:    session.iceState,
		SourceState: session.sourceState,
		LastError:   session.lastError,
		Frames:      session.frames.Load(),
		Bytes:       session.bytes.Load(),
	}
	session.mu.RUnlock()
	status.Route = selectedRoute(session.pc)
	return status
}

func selectedRoute(pc *webrtc.PeerConnection) string {
	if pc == nil || pc.SCTP() == nil || pc.SCTP().Transport() == nil || pc.SCTP().Transport().ICETransport() == nil {
		return ""
	}
	pair, err := pc.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local == nil || pair.Remote == nil {
		return ""
	}
	return fmt.Sprintf("%s/%s -> %s/%s", pair.Local.Typ, pair.Local.Protocol, pair.Remote.Typ, pair.Remote.Protocol)
}

func (s *experimentServer) close() {
	s.replaceSession(nil)
}

func (s *desktopSession) update(change func(*desktopSession)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	change(s)
}

func (s *desktopSession) setError(message string) {
	s.update(func(value *desktopSession) {
		value.lastError = message
		value.sourceState = "failed"
	})
}

func (s *desktopSession) close() {
	s.closeOnce.Do(func() {
		s.cancel()
		_ = s.pc.Close()
	})
}

func randomID() string {
	value := make([]byte, 12)
	if _, err := rand.Read(value); err != nil {
		panic(fmt.Sprintf("read system randomness: %v", err))
	}
	return base64.RawURLEncoding.EncodeToString(value)
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); errors.Is(err, io.EOF) {
		return nil
	} else if err != nil {
		return err
	}
	return errors.New("multiple JSON values")
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
