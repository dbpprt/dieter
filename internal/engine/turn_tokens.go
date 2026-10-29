package engine

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"slices"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// Turn tokens identify the conversation behind a CLI call made from inside an
// agent turn. The key exists only in this Service instance, so a token is valid
// exactly while its turn is active here and stops working when the turn
// finishes or the daemon restarts. Tokens identify; they do not sandbox: a process that
// omits its token is treated as the operator.

const turnTokenPrefix = "dtt1"

func newTurnTokenKey() []byte {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		panic(err)
	}
	return key
}

var ErrTurnTokenInvalid = fault.New(fault.PermissionDenied, "the agent turn token is invalid or its turn has finished")

func (s *Service) turnTokenMAC(cardID, turnID string) string {
	mac := hmac.New(sha256.New, s.turnTokenKey)
	mac.Write([]byte(turnTokenPrefix + "\x00" + cardID + "\x00" + turnID))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *Service) turnToken(cardID, turnID string) string {
	return strings.Join([]string{turnTokenPrefix, cardID, turnID, s.turnTokenMAC(cardID, turnID)}, ":")
}

// VerifyTurnToken returns the card of a currently active turn.
func (s *Service) VerifyTurnToken(token string) (string, error) {
	cardID, _, err := s.VerifyTurn(token)
	return cardID, err
}

// VerifyTurn returns the card and turn of a currently active turn.
func (s *Service) VerifyTurn(token string) (cardID, turnID string, err error) {
	parts := strings.Split(strings.TrimSpace(token), ":")
	if len(parts) != 4 || parts[0] != turnTokenPrefix || !hmac.Equal([]byte(parts[3]), []byte(s.turnTokenMAC(parts[1], parts[2]))) {
		return "", "", ErrTurnTokenInvalid
	}
	s.mu.Lock()
	active := s.active[parts[1]]
	current := active != nil && active.turnID == parts[2] && !active.finishing
	s.mu.Unlock()
	if !current {
		return "", "", ErrTurnTokenInvalid
	}
	return parts[1], parts[2], nil
}

// agentEnvironment is added to every harness worker. Commands an agent runs
// inherit it, so `dieter` reaches this daemon and identifies the turn.
func (s *Service) agentEnvironment(cardID, turnID string) map[string]string {
	return map[string]string{
		"DIETER_HOME":       s.Store.Root,
		"DIETER_CARD_ID":    cardID,
		"DIETER_TURN_TOKEN": s.turnToken(cardID, turnID),
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

func (s *Service) turnVaultSecrets(cardID, turnID string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if active := s.active[cardID]; active != nil && active.turnID == turnID {
		return slices.Clone(active.vaultSecrets)
	}
	return nil
}

// jsonForms are secrets as they appear inside JSON strings, plain and
// HTML-escaped.
func jsonForms(secrets []string) [][]byte {
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
	return forms
}

func redactForms(value []byte, forms [][]byte) []byte {
	for _, form := range forms {
		if len(form) > 0 && bytes.Contains(value, form) {
			value = bytes.ReplaceAll(value, form, []byte(redactedVaultSecret))
		}
	}
	return value
}

func (s *Service) redactVaultSecrets(cardID, turnID string, chunks []json.RawMessage) []json.RawMessage {
	secrets := s.turnVaultSecrets(cardID, turnID)
	if len(secrets) == 0 {
		return chunks
	}
	forms := jsonForms(secrets)
	result := make([]json.RawMessage, len(chunks))
	for i, chunk := range chunks {
		result[i] = redactForms([]byte(chunk), forms)
	}
	return result
}

// RedactVaultText replaces the vault values revealed to a card's active turn
// in text that turn wrote, such as a mail subject and body, as its stored
// transcript does: the values themselves and their JSON string forms.
func (s *Service) RedactVaultText(cardID, turnID string, values ...*string) {
	secrets := s.turnVaultSecrets(cardID, turnID)
	if len(secrets) == 0 {
		return
	}
	forms := jsonForms(secrets)
	for _, secret := range secrets {
		forms = append(forms, []byte(secret))
	}
	// Longer forms first, so no value is left partly replaced.
	slices.SortStableFunc(forms, func(a, b []byte) int { return len(b) - len(a) })
	for _, value := range values {
		*value = string(redactForms([]byte(*value), forms))
	}
}
