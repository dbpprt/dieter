package trust

import (
	"errors"
	"net"
	"net/url"
	"strings"
)

// GatewayOrigin validates an origin before any enrollment secret, bearer token,
// or machine traffic is sent. Cleartext is only available on literal loopback
// addresses for isolated local gateways; DNS names cannot grant that exception.
func GatewayOrigin(value string) (string, error) {
	value = strings.TrimSpace(value)
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return "", errors.New("gateway URL must be an HTTPS origin without credentials, a path, query, or fragment")
	}
	if parsed.Scheme == "http" {
		ip := net.ParseIP(parsed.Hostname())
		if ip == nil || !ip.IsLoopback() {
			return "", errors.New("gateway URL must use HTTPS; HTTP is allowed only for a literal loopback address")
		}
	}
	return parsed.Scheme + "://" + parsed.Host, nil
}
