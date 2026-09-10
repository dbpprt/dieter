package store

import (
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
)

// Bare hosts match every port. A host:port mapping is more specific; IPv6
// requires brackets when a port is present. Ambiguous ownership is permitted,
// but clients must not choose between equally specific destinations blindly.
func normalizeProjectHostnames(values []string) ([]string, error) {
	if len(values) > 64 {
		return nil, fmt.Errorf("at most 64 project hostnames are allowed")
	}
	result := []string{}
	seen := map[string]bool{}
	for _, value := range values {
		host, err := normalizeProjectHostname(value)
		if err != nil {
			return nil, err
		}
		if !seen[host] {
			result = append(result, host)
			seen[host] = true
		}
	}
	sort.Strings(result)
	return result, nil
}

func normalizeProjectHostname(value string) (string, error) {
	invalid := func() (string, error) {
		return "", fmt.Errorf("invalid project hostname %q: use host or host:port (1-65535), with IPv6 ports written as [::1]:4018; no URL, path, or wildcard", value)
	}
	host := strings.ToLower(strings.TrimSpace(value))
	port := ""
	if strings.HasPrefix(host, "[") {
		if strings.HasSuffix(host, "]") {
			host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
		} else {
			var err error
			host, port, err = net.SplitHostPort(host)
			if err != nil || port == "" {
				return invalid()
			}
		}
		if !strings.Contains(host, ":") || net.ParseIP(host) == nil {
			return invalid()
		}
	} else if net.ParseIP(host) == nil && strings.Contains(host, ":") {
		var found bool
		host, port, found = strings.Cut(host, ":")
		if !found || port == "" {
			return invalid()
		}
	}
	host = strings.TrimSuffix(host, ".")
	if ip := net.ParseIP(host); ip != nil {
		host = ip.String()
	} else {
		if host == "" || len(host) > 253 {
			return invalid()
		}
		for _, label := range strings.Split(host, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return invalid()
			}
			for _, c := range label {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
					return invalid()
				}
			}
		}
	}
	if port == "" {
		return host, nil
	}
	for _, c := range port {
		if c < '0' || c > '9' {
			return invalid()
		}
	}
	number, err := strconv.ParseUint(port, 10, 16)
	if err != nil || number == 0 {
		return invalid()
	}
	return net.JoinHostPort(host, strconv.FormatUint(number, 10)), nil
}
