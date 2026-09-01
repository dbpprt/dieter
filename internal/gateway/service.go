package gateway

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" // #nosec G505 -- coturn's REST credential protocol requires HMAC-SHA1.
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

type Service struct {
	gatewayv1.UnimplementedGatewayServiceServer
	store          *Store
	auth           *Auth
	keys           *Keys
	hub            *Hub
	config         Config
	enrollMu       sync.Mutex
	enrollAttempts map[string][]time.Time
}

func NewService(store *Store, auth *Auth, keys *Keys, hub *Hub, config Config) *Service {
	return &Service{store: store, auth: auth, keys: keys, hub: hub, config: config, enrollAttempts: map[string][]time.Time{}}
}

func (s *Service) GetAccount(ctx context.Context, _ *emptypb.Empty) (*gatewayv1.Account, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	return &gatewayv1.Account{GithubId: principal.GitHubID, Login: principal.Login}, nil
}

func (s *Service) ListDaemons(ctx context.Context, _ *emptypb.Empty) (*gatewayv1.ListDaemonsResponse, error) {
	principal, ok := PrincipalFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "authentication required")
	}
	items, err := s.store.ListDaemons(principal.GitHubID)
	if err != nil {
		return nil, status.Error(codes.Internal, "list daemons")
	}
	result := &gatewayv1.ListDaemonsResponse{}
	for _, item := range items {
		result.Daemons = append(result.Daemons, s.protoDaemon(item))
	}
	return result, nil
}

func (s *Service) WatchDaemons(request *gatewayv1.WatchDaemonsRequest, stream grpc.ServerStreamingServer[gatewayv1.DaemonPresenceUpdate]) error {
	interval := time.Duration(request.GetHeartbeatSeconds()) * time.Second
	if interval < 5*time.Second {
		interval = 15 * time.Second
	}
	if interval > time.Minute {
		interval = time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		response, err := s.ListDaemons(stream.Context(), &emptypb.Empty{})
		if err != nil {
			return err
		}
		if err := stream.Send(&gatewayv1.DaemonPresenceUpdate{Daemons: response.Daemons, Revision: s.hub.Revision()}); err != nil {
			return err
		}
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-ticker.C:
		case <-s.hub.Changed():
		}
	}
}

func (s *Service) BeginDaemonEnrollment(ctx context.Context, request *gatewayv1.BeginDaemonEnrollmentRequest) (*gatewayv1.DaemonEnrollment, error) {
	if !s.allowEnrollment(ctx) {
		return nil, status.Error(codes.ResourceExhausted, "too many daemon enrollment attempts")
	}
	name := strings.TrimSpace(request.GetName())
	if name == "" || len(name) > 80 {
		return nil, status.Error(codes.InvalidArgument, "daemon name is required and must be at most 80 characters")
	}
	value, err := x509.ParsePKIXPublicKey(request.GetPublicKey())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "daemon public key is invalid")
	}
	if _, ok := value.(ed25519.PublicKey); !ok {
		return nil, status.Error(codes.InvalidArgument, "daemon public key must be Ed25519")
	}
	secretRaw := make([]byte, 32)
	_, _ = rand.Read(secretRaw)
	secret := base64.RawURLEncoding.EncodeToString(secretRaw)
	codeRaw := make([]byte, 5)
	_, _ = rand.Read(codeRaw)
	code := strings.ToUpper(base64.RawURLEncoding.EncodeToString(codeRaw))
	expires := time.Now().UTC().Add(10 * time.Minute)
	id := randomID("enroll_")
	if err := s.store.CreateEnrollment(EnrollmentRecord{ID: id, SecretHash: s.auth.digest(secret), UserCode: code, Name: name, PublicKey: request.GetPublicKey(), ExpiresAt: expires}); err != nil {
		return nil, status.Error(codes.Internal, "create daemon enrollment")
	}
	query := "?enrollment_id=" + id + "&user_code=" + code
	return &gatewayv1.DaemonEnrollment{EnrollmentId: id, EnrollmentSecret: secret, VerificationUrl: strings.TrimRight(s.config.PublicURL.String(), "/") + "/auth/github/start" + query, UserCode: code, ExpiresAt: expires.Format(time.RFC3339Nano)}, nil
}

func (s *Service) allowEnrollment(ctx context.Context) bool {
	host := "unknown"
	if value, ok := peer.FromContext(ctx); ok && value.Addr != nil {
		host = value.Addr.String()
		if parsed, _, err := net.SplitHostPort(host); err == nil {
			host = parsed
		}
	}
	now := time.Now().UTC()
	cutoff := now.Add(-time.Minute)
	s.enrollMu.Lock()
	defer s.enrollMu.Unlock()
	previous := s.enrollAttempts[host]
	kept := previous[:0]
	for _, attempt := range previous {
		if attempt.After(cutoff) {
			kept = append(kept, attempt)
		}
	}
	if len(kept) >= 10 {
		s.enrollAttempts[host] = kept
		return false
	}
	s.enrollAttempts[host] = append(kept, now)
	return true
}

func (s *Service) CompleteDaemonEnrollment(_ context.Context, request *gatewayv1.CompleteDaemonEnrollmentRequest) (*gatewayv1.DaemonCredential, error) {
	record, err := s.store.Enrollment(request.GetEnrollmentId())
	if err != nil || !hmacEqual(record.SecretHash, s.auth.digest(request.GetEnrollmentSecret())) {
		return nil, status.Error(codes.Unauthenticated, "daemon enrollment is invalid")
	}
	if record.ExpiresAt.Before(time.Now().UTC()) {
		return nil, status.Error(codes.DeadlineExceeded, "daemon enrollment expired")
	}
	if record.ConsumedAt != nil {
		daemon, daemonErr := s.store.Daemon(record.DaemonID)
		if daemonErr != nil {
			return nil, status.Error(codes.Internal, "load enrolled daemon")
		}
		return s.credential(daemon), nil
	}
	if !record.Approved || !s.config.AllowsGitHubUser(record.GitHubID) {
		return nil, status.Error(codes.FailedPrecondition, "daemon enrollment is awaiting GitHub authorization")
	}
	daemonID := randomID("d_")
	certificate, expires, err := s.keys.IssueDaemonCertificate(daemonID, record.PublicKey)
	if err != nil {
		return nil, status.Error(codes.Internal, "issue daemon certificate")
	}
	daemon := DaemonRecord{ID: daemonID, Name: record.Name, GitHubID: record.GitHubID, Login: record.Login, PublicKey: record.PublicKey, Certificate: certificate, Generation: 1, CreatedAt: time.Now().UTC()}
	if err := s.store.FinishEnrollment(daemon, record.ID); err != nil {
		return nil, status.Error(codes.Aborted, err.Error())
	}
	credential := s.credential(daemon)
	credential.ExpiresAt = expires.Format(time.RFC3339Nano)
	return credential, nil
}

func (s *Service) UnenrollDaemon(_ context.Context, request *gatewayv1.UnenrollDaemonRequest) (*emptypb.Empty, error) {
	if len(request.GetNonce()) != 32 || len(request.GetSignature()) != ed25519.SignatureSize {
		return nil, status.Error(codes.Unauthenticated, "daemon unenrollment proof is invalid")
	}
	record, err := s.store.Daemon(request.GetDaemonId())
	if err != nil || linkauth.VerifyUnenrollment(record.Certificate, s.config.PublicURL.String(), record.ID, request.GetNonce(), request.GetSignature()) != nil {
		return nil, status.Error(codes.Unauthenticated, "daemon unenrollment proof is invalid")
	}
	if !record.Revoked {
		if _, err := s.store.RevokeDaemon(record.ID, record.GitHubID); err != nil {
			return nil, status.Error(codes.Aborted, "unenroll daemon")
		}
	}
	s.hub.CloseDaemon(record.ID)
	s.hub.signalChanged()
	return &emptypb.Empty{}, nil
}

func (s *Service) RenameDaemon(ctx context.Context, request *gatewayv1.RenameDaemonRequest) (*gatewayv1.Daemon, error) {
	principal, _ := PrincipalFromContext(ctx)
	name := strings.TrimSpace(request.GetName())
	if name == "" || len(name) > 80 {
		return nil, status.Error(codes.InvalidArgument, "daemon name is required and must be at most 80 characters")
	}
	if err := s.store.RenameDaemon(request.GetDaemonId(), name, principal.GitHubID); err != nil {
		return nil, status.Error(codes.NotFound, "daemon not found")
	}
	record, _ := s.store.Daemon(request.GetDaemonId())
	s.hub.signalChanged()
	return s.protoDaemon(record), nil
}

func (s *Service) RevokeDaemon(ctx context.Context, request *gatewayv1.DaemonRef) (*emptypb.Empty, error) {
	principal, _ := PrincipalFromContext(ctx)
	if _, err := s.store.RevokeDaemon(request.GetDaemonId(), principal.GitHubID); err != nil {
		return nil, status.Error(codes.NotFound, "daemon not found")
	}
	s.hub.CloseDaemon(request.GetDaemonId())
	s.hub.signalChanged()
	return &emptypb.Empty{}, nil
}

func (s *Service) ExchangeDaemonToken(ctx context.Context, request *gatewayv1.ExchangeDaemonTokenRequest) (*gatewayv1.DaemonAccessToken, error) {
	principal, _ := PrincipalFromContext(ctx)
	record, err := s.ownedDaemon(request.GetDaemonId(), principal.GitHubID)
	if err != nil {
		return nil, err
	}
	token, expires, err := s.keys.SignDaemonToken(s.config.PublicURL.String(), record.ID, principal.GitHubID, record.Generation, request.GetClientKeyThumbprint(), 5*time.Minute)
	if err != nil {
		return nil, status.Error(codes.Internal, "issue daemon access token")
	}
	return &gatewayv1.DaemonAccessToken{AccessToken: token, TokenType: "Bearer", ExpiresAt: expires.Format(time.RFC3339Nano), DaemonGeneration: record.Generation}, nil
}

func (s *Service) ResolveDaemonRoute(ctx context.Context, request *gatewayv1.DaemonRef) (*gatewayv1.DaemonRoute, error) {
	principal, _ := PrincipalFromContext(ctx)
	record, err := s.ownedDaemon(request.GetDaemonId(), principal.GitHubID)
	if err != nil {
		return nil, err
	}
	daemon := s.protoDaemon(record)
	return &gatewayv1.DaemonRoute{DaemonId: record.ID, RelayAvailable: daemon.Online, DirectCandidates: daemon.DirectCandidates, Generation: record.Generation, DaemonCaPem: s.keys.DaemonCAPEM, DaemonCertificatePem: append([]byte(nil), record.Certificate...)}, nil
}

func (s *Service) GetRTCConfiguration(ctx context.Context, request *gatewayv1.DaemonRef) (*gatewayv1.RTCConfiguration, error) {
	principal, _ := PrincipalFromContext(ctx)
	record, err := s.ownedDaemon(request.GetDaemonId(), principal.GitHubID)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	expires := now.Add(s.config.RTCTTL)
	subject := fmt.Sprintf("github:%d", principal.GitHubID)
	configuration := &gatewayv1.RTCConfiguration{
		ExpiresAt: expires.Format(time.RFC3339Nano), DaemonId: record.ID,
		OperatorSubject: subject, ConfigurationId: randomID("rtc_"),
		DaemonGeneration: record.Generation, IssuedAt: now.Format(time.RFC3339Nano),
	}
	if len(s.config.RTCSTUNURLs) > 0 {
		configuration.IceServers = append(configuration.IceServers, &gatewayv1.RTCIceServer{Urls: append([]string(nil), s.config.RTCSTUNURLs...)})
	}
	if len(s.config.RTCTURNURLs) > 0 {
		username := fmt.Sprintf("%d:dieter:%d:%s", expires.Unix(), principal.GitHubID, record.ID)
		mac := hmac.New(sha1.New, s.config.RTCTURNSecret) // #nosec G401 -- required by coturn REST authentication.
		_, _ = mac.Write([]byte(username))
		configuration.IceServers = append(configuration.IceServers, &gatewayv1.RTCIceServer{
			Urls: append([]string(nil), s.config.RTCTURNURLs...), Username: username,
			Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil)),
		})
	}
	digest, err := rtcConfigurationDigest(configuration)
	if err != nil {
		return nil, status.Error(codes.Internal, "encode RTC configuration")
	}
	envelope, err := s.keys.SignRTCConfiguration(s.config.PublicURL.String(), RTCConfigurationClaims{
		Audience: "board-daemon:" + record.ID, Subject: subject, ID: configuration.ConfigurationId,
		ConfigurationHash: base64.RawURLEncoding.EncodeToString(digest), DaemonGeneration: record.Generation,
		IssuedAt: now.Unix(), ExpiresAt: expires.Unix(),
	})
	if err != nil {
		return nil, status.Error(codes.Internal, "sign RTC configuration")
	}
	configuration.SignedEnvelope = []byte(envelope)
	return configuration, nil
}

func rtcConfigurationDigest(configuration *gatewayv1.RTCConfiguration) ([]byte, error) {
	copy := proto.Clone(configuration).(*gatewayv1.RTCConfiguration)
	copy.SignedEnvelope = nil
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(copy)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(raw)
	return digest[:], nil
}

func (s *Service) ownedDaemon(id string, githubID int64) (DaemonRecord, error) {
	record, err := s.store.Daemon(id)
	if err != nil || record.Revoked || record.GitHubID != githubID {
		return record, status.Error(codes.NotFound, "daemon not found")
	}
	return record, nil
}

func (s *Service) protoDaemon(record DaemonRecord) *gatewayv1.Daemon {
	var routes []*gatewayv1.DirectCandidate
	_ = json.Unmarshal(record.RoutesJSON, &routes)
	remoteDesktop := &gatewayv1.RemoteDesktopPresence{}
	_ = json.Unmarshal(record.RemoteDesktopJSON, remoteDesktop)
	return &gatewayv1.Daemon{Id: record.ID, Name: record.Name, Online: s.hub.Online(record.ID), LastSeenAt: record.LastSeenAt.Format(time.RFC3339Nano), Version: record.Version, Generation: record.Generation, DirectCandidates: routes, RemoteDesktop: remoteDesktop}
}

func (s *Service) credential(record DaemonRecord) *gatewayv1.DaemonCredential {
	public, _ := s.keys.SigningPublicPEM()
	expires := ""
	if block, _ := pemDecode(record.Certificate); block != nil {
		if certificate, err := x509.ParseCertificate(block); err == nil {
			expires = certificate.NotAfter.UTC().Format(time.RFC3339Nano)
		}
	}
	return &gatewayv1.DaemonCredential{DaemonId: record.ID, DaemonName: record.Name, CertificatePem: record.Certificate, DaemonCaPem: s.keys.DaemonCAPEM, GatewaySigningPublicKey: public, ExpiresAt: expires, Generation: record.Generation}
}

func hmacEqual(left, right string) bool {
	return hmac.Equal([]byte(left), []byte(right))
}

func pemDecode(raw []byte) ([]byte, []byte) {
	block, rest := pem.Decode(raw)
	if block == nil {
		return nil, rest
	}
	return block.Bytes, rest
}
