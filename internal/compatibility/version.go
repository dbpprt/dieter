package compatibility

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const DevelopmentMinimum = "0.0.0-dev.0"

type Status int

const (
	StatusUnknown Status = iota
	StatusCompatible
	StatusUpdateRequired
	StatusInvalidVersion
)

type Policy struct {
	GatewayReleaseVersion string
	MinimumClientVersion  string
	MinimumDaemonVersion  string
	Revision              string
}

type version struct {
	major, minor, patch uint64
	prerelease          []string
}

func Normalize(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(raw, "v") {
		raw = strings.TrimPrefix(raw, "v")
	}
	if _, err := parse(raw); err != nil {
		return "", err
	}
	return raw, nil
}

func Compare(left, right string) (int, error) {
	l, err := parseNormalized(left)
	if err != nil {
		return 0, fmt.Errorf("left version: %w", err)
	}
	r, err := parseNormalized(right)
	if err != nil {
		return 0, fmt.Errorf("right version: %w", err)
	}
	for _, pair := range [][2]uint64{{l.major, r.major}, {l.minor, r.minor}, {l.patch, r.patch}} {
		if pair[0] < pair[1] {
			return -1, nil
		}
		if pair[0] > pair[1] {
			return 1, nil
		}
	}
	return comparePrerelease(l.prerelease, r.prerelease), nil
}

func Evaluate(current, minimum string) (Status, string) {
	current, err := Normalize(current)
	if err != nil {
		return StatusInvalidVersion, ""
	}
	minimum, err = Normalize(minimum)
	if err != nil {
		return StatusInvalidVersion, current
	}
	comparison, _ := Compare(current, minimum)
	if comparison < 0 {
		return StatusUpdateRequired, current
	}
	return StatusCompatible, current
}

func NewPolicy(issuer, gateway, minimumClient, minimumDaemon string) (Policy, error) {
	values := []*string{&gateway, &minimumClient, &minimumDaemon}
	for _, value := range values {
		normalized, err := Normalize(*value)
		if err != nil {
			return Policy{}, err
		}
		*value = normalized
	}
	// Gateway binaries can advance without changing compatibility. Keep update
	// attempt deduplication stable until an operator actually raises a floor.
	digest := sha256.Sum256([]byte(strings.Join([]string{issuer, minimumClient, minimumDaemon}, "\n")))
	return Policy{
		GatewayReleaseVersion: gateway,
		MinimumClientVersion:  minimumClient,
		MinimumDaemonVersion:  minimumDaemon,
		Revision:              hex.EncodeToString(digest[:]),
	}, nil
}

func UpdateAttemptKey(issuer, policyRevision, installed, minimum string) string {
	digest := sha256.Sum256([]byte(strings.Join([]string{issuer, policyRevision, installed, minimum}, "\n")))
	return hex.EncodeToString(digest[:])
}

func parseNormalized(raw string) (version, error) {
	normalized, err := Normalize(raw)
	if err != nil {
		return version{}, err
	}
	return parse(normalized)
}

func parse(raw string) (version, error) {
	if raw == "" || strings.ContainsAny(raw, " \t\r\n") {
		return version{}, errors.New("release version must be Semantic Versioning")
	}
	withoutBuild, build, hasBuild := strings.Cut(raw, "+")
	if hasBuild && !validIdentifiers(build, false) {
		return version{}, errors.New("release version has invalid build metadata")
	}
	core, prerelease, hasPrerelease := strings.Cut(withoutBuild, "-")
	if hasPrerelease && !validIdentifiers(prerelease, true) {
		return version{}, errors.New("release version has invalid prerelease metadata")
	}
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return version{}, errors.New("release version must contain major.minor.patch")
	}
	values := make([]uint64, 3)
	for index, part := range parts {
		if part == "" || len(part) > 1 && part[0] == '0' {
			return version{}, errors.New("release version numeric identifiers are invalid")
		}
		value, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return version{}, errors.New("release version numeric identifiers are invalid")
		}
		values[index] = value
	}
	result := version{major: values[0], minor: values[1], patch: values[2]}
	if hasPrerelease {
		result.prerelease = strings.Split(prerelease, ".")
	}
	return result, nil
}

func validIdentifiers(raw string, rejectNumericLeadingZero bool) bool {
	if raw == "" {
		return false
	}
	for _, identifier := range strings.Split(raw, ".") {
		if identifier == "" || rejectNumericLeadingZero && isNumeric(identifier) && len(identifier) > 1 && identifier[0] == '0' {
			return false
		}
		for _, char := range identifier {
			if char < '0' || char > '9' {
				if char < 'A' || char > 'Z' {
					if char < 'a' || char > 'z' {
						if char != '-' {
							return false
						}
					}
				}
			}
		}
	}
	return true
}

func comparePrerelease(left, right []string) int {
	if len(left) == 0 && len(right) == 0 {
		return 0
	}
	if len(left) == 0 {
		return 1
	}
	if len(right) == 0 {
		return -1
	}
	for index := 0; index < len(left) && index < len(right); index++ {
		l, r := left[index], right[index]
		if l == r {
			continue
		}
		lNumeric, rNumeric := isNumeric(l), isNumeric(r)
		switch {
		case lNumeric && rNumeric:
			if len(l) < len(r) {
				return -1
			}
			if len(l) > len(r) {
				return 1
			}
		case lNumeric:
			return -1
		case rNumeric:
			return 1
		}
		if l < r {
			return -1
		}
		return 1
	}
	if len(left) < len(right) {
		return -1
	}
	if len(left) > len(right) {
		return 1
	}
	return 0
}

func isNumeric(value string) bool {
	if value == "" {
		return false
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}
