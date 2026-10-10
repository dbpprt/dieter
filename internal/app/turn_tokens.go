package app

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
)

// Turn tokens identify the conversation behind a CLI call made from inside an
// agent turn. The key exists only in this process, so a token is valid exactly
// while its turn is active here and stops working when the turn finishes or
// the daemon restarts. Tokens identify; they do not sandbox: a process that
// omits its token is treated as the operator.

const turnTokenPrefix = "dtt1"

var turnTokenKey = func() []byte {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		panic(err)
	}
	return key
}()

var ErrTurnTokenInvalid = errors.New("the agent turn token is invalid or its turn has finished")

func turnTokenMAC(cardID, turnID string) string {
	mac := hmac.New(sha256.New, turnTokenKey)
	mac.Write([]byte(turnTokenPrefix + "\x00" + cardID + "\x00" + turnID))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func turnToken(cardID, turnID string) string {
	return strings.Join([]string{turnTokenPrefix, cardID, turnID, turnTokenMAC(cardID, turnID)}, ":")
}

// VerifyTurnToken returns the card of a currently active turn.
func (s *Service) VerifyTurnToken(token string) (string, error) {
	parts := strings.Split(strings.TrimSpace(token), ":")
	if len(parts) != 4 || parts[0] != turnTokenPrefix || !hmac.Equal([]byte(parts[3]), []byte(turnTokenMAC(parts[1], parts[2]))) {
		return "", ErrTurnTokenInvalid
	}
	s.mu.Lock()
	active := s.active[parts[1]]
	current := active != nil && active.turnID == parts[2] && !active.finishing
	s.mu.Unlock()
	if !current {
		return "", ErrTurnTokenInvalid
	}
	return parts[1], nil
}

// agentEnvironment is added to every harness worker. Commands an agent runs
// inherit it, so `dieter` reaches this daemon and identifies the turn.
func (s *Service) agentEnvironment(cardID, turnID string) map[string]string {
	return map[string]string{
		"DIETER_HOME":       s.Store.Root,
		"DIETER_CARD_ID":    cardID,
		"DIETER_TURN_TOKEN": turnToken(cardID, turnID),
	}
}

const (
	maxVaultSecretsPerTurn = 64
	minRedactedSecretBytes = 6
	redactedVaultSecret    = "[redacted vault secret]"
)

// RegisterVaultSecrets records values revealed to a card's active turn. Later
// transcript chunks of that turn replace them. The provider may still see the
// tool output; this keeps secrets out of Dieter's durable transcript.
func (s *Service) RegisterVaultSecrets(cardID string, values ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	active := s.active[cardID]
	if active == nil {
		return
	}
	for _, value := range values {
		if len(value) < minRedactedSecretBytes || len(active.vaultSecrets) >= maxVaultSecretsPerTurn {
			continue
		}
		known := false
		for _, existing := range active.vaultSecrets {
			known = known || existing == value
		}
		if !known {
			active.vaultSecrets = append(active.vaultSecrets, value)
		}
	}
}

func (s *Service) redactVaultSecrets(cardID, turnID string, chunks []json.RawMessage) []json.RawMessage {
	s.mu.Lock()
	var secrets []string
	if active := s.active[cardID]; active != nil && active.turnID == turnID {
		secrets = append(secrets, active.vaultSecrets...)
	}
	s.mu.Unlock()
	if len(secrets) == 0 {
		return chunks
	}
	var forms [][]byte
	for _, secret := range secrets {
		for _, escapeHTML := range []bool{false, true} {
			var buffer bytes.Buffer
			encoder := json.NewEncoder(&buffer)
			encoder.SetEscapeHTML(escapeHTML)
			if encoder.Encode(secret) == nil {
				encoded := bytes.TrimSuffix(buffer.Bytes(), []byte("\n"))
				forms = append(forms, encoded[1:len(encoded)-1])
			}
		}
	}
	result := make([]json.RawMessage, len(chunks))
	for i, chunk := range chunks {
		redacted := []byte(chunk)
		for _, form := range forms {
			if len(form) > 0 && bytes.Contains(redacted, form) {
				redacted = bytes.ReplaceAll(redacted, form, []byte(redactedVaultSecret))
			}
		}
		result[i] = redacted
	}
	return result
}
