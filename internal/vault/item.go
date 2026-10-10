package vault

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"math/big"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Item is the decrypted content of one vault entry. It is never replicated or
// persisted in plaintext.
type Item struct {
	Name      string   `json:"name"`
	URLs      []string `json:"urls,omitempty"`
	Username  string   `json:"username,omitempty"`
	Password  string   `json:"password,omitempty"`
	TOTP      string   `json:"totp,omitempty"`
	Notes     string   `json:"notes,omitempty"`
	CreatedAt string   `json:"createdAt"`
	UpdatedAt string   `json:"updatedAt"`
	UpdatedBy string   `json:"updatedBy,omitempty"`
}

const (
	MaxNameRunes    = 200
	MaxURLs         = 16
	MaxURLBytes     = 2048
	MaxSecretBytes  = 4096
	MaxNotesBytes   = 8192
	MinPasswordSize = 8
	MaxPasswordSize = 256
)

// Fields are the names accepted by reveal and exec.
var Fields = []string{"password", "username", "totp", "url", "notes", "name"}

func (item Item) Validate() error {
	name := strings.TrimSpace(item.Name)
	if name == "" || name != item.Name || utf8.RuneCountInString(name) > MaxNameRunes || strings.ContainsAny(name, "\r\n\t") {
		return errors.New("item name is required, single-line, trimmed and at most 200 characters")
	}
	if strings.HasPrefix(name, "vi_") {
		return errors.New("item names cannot start with the item ID prefix vi_")
	}
	if len(item.URLs) > MaxURLs {
		return fmt.Errorf("at most %d URLs are allowed", MaxURLs)
	}
	for _, value := range item.URLs {
		if err := ValidateURL(value); err != nil {
			return err
		}
	}
	if len(item.Username) > MaxSecretBytes || len(item.Password) > MaxSecretBytes {
		return errors.New("username and password are limited to 4096 bytes")
	}
	if strings.ContainsAny(item.Username, "\r\n") {
		return errors.New("username must be a single line")
	}
	if len(item.Notes) > MaxNotesBytes {
		return errors.New("notes are limited to 8192 bytes")
	}
	if item.TOTP != "" {
		if _, err := ParseTOTP(item.TOTP); err != nil {
			return err
		}
	}
	return nil
}

func ValidateURL(value string) error {
	if len(value) > MaxURLBytes || strings.TrimSpace(value) != value || value == "" {
		return errors.New("URLs must be non-empty, trimmed and at most 2048 bytes")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" && parsed.Opaque == "" {
		return fmt.Errorf("invalid URL %q; include a scheme such as https://", value)
	}
	return nil
}

// Field returns one named value of the item.
func (item Item) Field(name string, now time.Time) (string, error) {
	switch name {
	case "password":
		return item.Password, nil
	case "username":
		return item.Username, nil
	case "notes":
		return item.Notes, nil
	case "name":
		return item.Name, nil
	case "url":
		if len(item.URLs) == 0 {
			return "", nil
		}
		return item.URLs[0], nil
	case "totp":
		if item.TOTP == "" {
			return "", errors.New("item has no TOTP secret")
		}
		config, err := ParseTOTP(item.TOTP)
		if err != nil {
			return "", err
		}
		code, _ := config.Code(now)
		return code, nil
	}
	return "", fmt.Errorf("unknown vault field %q; use %s", name, strings.Join(Fields, ", "))
}

// TOTP is an RFC 6238 configuration.
type TOTP struct {
	Secret    []byte
	Algorithm string
	Digits    int
	Period    int
	Issuer    string
	Account   string
}

// ParseTOTP accepts an otpauth://totp URI or a bare base32 secret.
func ParseTOTP(input string) (TOTP, error) {
	input = strings.TrimSpace(input)
	config := TOTP{Algorithm: "SHA1", Digits: 6, Period: 30}
	secret := input
	if strings.HasPrefix(strings.ToLower(input), "otpauth://") {
		parsed, err := url.Parse(input)
		if err != nil || !strings.EqualFold(parsed.Host, "totp") {
			return TOTP{}, errors.New("only otpauth://totp URIs are supported")
		}
		query := parsed.Query()
		secret = query.Get("secret")
		label := strings.TrimPrefix(parsed.Path, "/")
		if issuer, account, found := strings.Cut(label, ":"); found {
			config.Issuer, config.Account = strings.TrimSpace(issuer), strings.TrimSpace(account)
		} else {
			config.Account = label
		}
		if issuer := query.Get("issuer"); issuer != "" {
			config.Issuer = issuer
		}
		if value := query.Get("algorithm"); value != "" {
			config.Algorithm = strings.ToUpper(value)
		}
		if value := query.Get("digits"); value != "" {
			digits, err := strconv.Atoi(value)
			if err != nil {
				return TOTP{}, errors.New("invalid TOTP digits")
			}
			config.Digits = digits
		}
		if value := query.Get("period"); value != "" {
			period, err := strconv.Atoi(value)
			if err != nil {
				return TOTP{}, errors.New("invalid TOTP period")
			}
			config.Period = period
		}
	}
	normalized := strings.ToUpper(strings.NewReplacer(" ", "", "-", "", "=", "").Replace(secret))
	decoded, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(normalized)
	if err != nil || len(decoded) < 10 || len(decoded) > 128 {
		return TOTP{}, errors.New("TOTP secret must be base32 encoded and 80 to 1024 bits")
	}
	config.Secret = decoded
	if config.Algorithm != "SHA1" && config.Algorithm != "SHA256" && config.Algorithm != "SHA512" {
		return TOTP{}, errors.New("TOTP algorithm must be SHA1, SHA256 or SHA512")
	}
	if config.Digits < 6 || config.Digits > 8 {
		return TOTP{}, errors.New("TOTP digits must be 6 to 8")
	}
	if config.Period < 10 || config.Period > 300 {
		return TOTP{}, errors.New("TOTP period must be 10 to 300 seconds")
	}
	return config, nil
}

// URI is the canonical stored form.
func (t TOTP) URI() string {
	label := t.Account
	if t.Issuer != "" {
		label = t.Issuer + ":" + t.Account
	}
	query := url.Values{}
	query.Set("secret", base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(t.Secret))
	if t.Issuer != "" {
		query.Set("issuer", t.Issuer)
	}
	query.Set("algorithm", t.Algorithm)
	query.Set("digits", strconv.Itoa(t.Digits))
	query.Set("period", strconv.Itoa(t.Period))
	return (&url.URL{Scheme: "otpauth", Host: "totp", Path: "/" + label, RawQuery: query.Encode()}).String()
}

// Code returns the code valid at now and the time until it changes.
func (t TOTP) Code(now time.Time) (string, time.Duration) {
	counter := uint64(now.Unix()) / uint64(t.Period)
	var factory func() hash.Hash
	switch t.Algorithm {
	case "SHA256":
		factory = sha256.New
	case "SHA512":
		factory = sha512.New
	default:
		factory = sha1.New
	}
	mac := hmac.New(factory, t.Secret)
	var message [8]byte
	binary.BigEndian.PutUint64(message[:], counter)
	mac.Write(message[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	modulus := uint32(1)
	for range t.Digits {
		modulus *= 10
	}
	next := time.Unix(int64((counter+1)*uint64(t.Period)), 0)
	return fmt.Sprintf("%0*d", t.Digits, value%modulus), next.Sub(now)
}

const (
	passwordLetters = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ"
	passwordDigits  = "23456789"
	passwordSymbols = "!#$%&*+-=?@^_~"
)

// GeneratePassword returns a uniformly random password containing at least one
// letter, digit and, unless symbols is false, one symbol.
func GeneratePassword(length int, symbols bool) (string, error) {
	if length < MinPasswordSize || length > MaxPasswordSize {
		return "", fmt.Errorf("password length must be %d to %d", MinPasswordSize, MaxPasswordSize)
	}
	alphabet := passwordLetters + passwordDigits
	if symbols {
		alphabet += passwordSymbols
	}
	pick := func(set string) byte {
		index, err := rand.Int(rand.Reader, big.NewInt(int64(len(set))))
		if err != nil {
			panic(err)
		}
		return set[index.Int64()]
	}
	for {
		value := make([]byte, length)
		for i := range value {
			value[i] = pick(alphabet)
		}
		text := string(value)
		if strings.ContainsAny(text, passwordLetters) && strings.ContainsAny(text, passwordDigits) && (!symbols || strings.ContainsAny(text, passwordSymbols)) {
			return text, nil
		}
	}
}
