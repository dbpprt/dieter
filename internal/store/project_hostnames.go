package store

import (
	"fmt"
	"net"
	"sort"
	"strings"
)

// Mappings are exact hosts, shared by every URL port and scheme. Ambiguous
// ownership is allowed (e.g. localhost), but clients must not route it blindly.
func normalizeProjectHostnames(values []string) ([]string, error) {
	if len(values) > 64 {
		return nil, fmt.Errorf("at most 64 project hostnames are allowed")
	}
	result := []string{}
	seen := map[string]bool{}
	for _, value := range values {
		host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
		if ip := net.ParseIP(host); ip != nil {
			host = ip.String()
		} else {
			if host == "" || len(host) > 253 {
				return nil, fmt.Errorf("invalid project hostname %q", value)
			}
			for _, label := range strings.Split(host, ".") {
				if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
					return nil, fmt.Errorf("invalid project hostname %q", value)
				}
				for _, c := range label {
					if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
						return nil, fmt.Errorf("invalid project hostname %q: use a bare hostname without URL, port, or wildcard", value)
					}
				}
			}
		}
		if !seen[host] {
			result = append(result, host)
			seen[host] = true
		}
	}
	sort.Strings(result)
	return result, nil
}
