package linkauth

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

const PeerPrefix = "dieter-peer-v1."

type PeerClaims struct {
	DaemonID   string `json:"daemon"`
	Gateway    string `json:"gateway"`
	Generation uint64 `json:"generation"`
	Issued     int64  `json:"issued"`
	Expires    int64  `json:"expires"`
}

func SignPeer(private ed25519.PrivateKey, daemon, gateway string, generation uint64, now time.Time) string {
	raw, _ := json.Marshal(PeerClaims{daemon, strings.TrimRight(gateway, "/"), generation, now.Unix(), now.Add(time.Minute).Unix()})
	body := base64.RawURLEncoding.EncodeToString(raw)
	return PeerPrefix + body + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, []byte(PeerPrefix+body)))
}
func ParsePeer(token string) (PeerClaims, []byte, []byte, error) {
	var c PeerClaims
	if len(token) > 2048 || !strings.HasPrefix(token, PeerPrefix) {
		return c, nil, nil, errors.New("invalid peer proof")
	}
	body, sig, ok := strings.Cut(strings.TrimPrefix(token, PeerPrefix), ".")
	if !ok {
		return c, nil, nil, errors.New("invalid peer proof")
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return c, nil, nil, err
	}
	if err = json.Unmarshal(raw, &c); err != nil {
		return c, nil, nil, err
	}
	signature, err := base64.RawURLEncoding.DecodeString(sig)
	return c, []byte(PeerPrefix + body), signature, err
}
func VerifyPeer(public ed25519.PublicKey, token, gateway string, generation uint64, now time.Time) (PeerClaims, error) {
	c, body, sig, err := ParsePeer(token)
	if err != nil {
		return c, err
	}
	if c.Gateway != strings.TrimRight(gateway, "/") || c.Generation != generation || c.DaemonID == "" || c.Issued > now.Unix()+5 || c.Expires <= now.Unix() || c.Expires-c.Issued != 60 || !ed25519.Verify(public, body, sig) {
		return c, errors.New("invalid or expired peer proof")
	}
	return c, nil
}
