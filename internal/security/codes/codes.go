// Package codes encodes the short codes people read and type: unpadded
// Crockford base32 in hyphenated groups, compared ignoring case, separators
// and confusable characters. Vault join codes, recovery keys and device
// pairing codes use it.
package codes

import (
	"crypto/subtle"
	"errors"
	"strings"
)

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

var ErrInvalid = errors.New("invalid character")

// Encode returns unpadded Crockford base32.
func Encode(data []byte) string {
	var out strings.Builder
	var buffer, bits uint
	for _, value := range data {
		buffer = buffer<<8 | uint(value)
		bits += 8
		for bits >= 5 {
			bits -= 5
			out.WriteByte(alphabet[(buffer>>bits)&31])
		}
	}
	if bits > 0 {
		out.WriteByte(alphabet[(buffer<<(5-bits))&31])
	}
	return out.String()
}

// Decode accepts typed Crockford base32 in any case, with or without
// separators.
func Decode(value string) ([]byte, error) {
	var out []byte
	var buffer, bits uint
	for _, char := range Normalize(value) {
		index := strings.IndexRune(alphabet, char)
		if index < 0 {
			return nil, ErrInvalid
		}
		buffer = buffer<<5 | uint(index)
		bits += 5
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(buffer>>bits))
		}
	}
	return out, nil
}

// Group splits value into hyphen-separated groups of size.
func Group(value string, size int) string {
	var parts []string
	for len(value) > size {
		parts = append(parts, value[:size])
		value = value[size:]
	}
	return strings.Join(append(parts, value), "-")
}

// Normalize uppercases a typed code, drops separators and maps confusable
// characters onto the alphabet.
func Normalize(value string) string {
	value = strings.ToUpper(value)
	return strings.NewReplacer("-", "", " ", "", "O", "0", "I", "1", "L", "1").Replace(value)
}

// Same compares a typed code with the expected one in constant time.
func Same(expected, typed string) bool {
	return subtle.ConstantTimeCompare([]byte(Normalize(expected)), []byte(Normalize(typed))) == 1
}
