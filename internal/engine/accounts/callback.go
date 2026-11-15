package accounts

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// parseCallback checks that raw is a loopback callback address of this
// sign-in: http, localhost or 127.0.0.1, the challenge's port and one of the
// provider's callback paths.
func parseCallback(raw string, port int, paths ...string) (*url.URL, error) {
	address, err := url.Parse(raw)
	if err != nil || address.Scheme != "http" || address.User != nil || !loopbackHost(address.Hostname()) {
		return nil, fault.New(fault.Invalid, "paste the full http://localhost address your browser could not open")
	}
	if address.Port() != strconv.Itoa(port) {
		return nil, fault.Errorf(fault.Invalid, "that address is for port %s, not this sign-in's port %d", address.Port(), port)
	}
	for _, path := range paths {
		if address.Path == path {
			return address, nil
		}
	}
	return nil, fault.New(fault.Invalid, "that address is not this sign-in's callback")
}

func loopbackHost(host string) bool { return host == "localhost" || host == "127.0.0.1" }

// replayCallback delivers a browser's loopback redirect, captured on another
// device, to the provider tool's listener on this machine. It follows
// redirects only while they stay on loopback and the same port (Codex reports
// completion only after its /success page is fetched) and never uses a proxy.
func replayCallback(ctx context.Context, address *url.URL, port int) error {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, _, err := net.SplitHostPort(addr)
			if err != nil || !loopbackHost(host) {
				return nil, fmt.Errorf("refusing to connect to %s", addr)
			}
			return dialer.DialContext(ctx, network, addr)
		},
		DisableKeepAlives: true,
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   15 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 5 || request.URL.Scheme != "http" || !loopbackHost(request.URL.Hostname()) || request.URL.Port() != strconv.Itoa(port) {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address.String(), nil)
	if err != nil {
		return fault.Wrap(fault.Invalid, err)
	}
	response, err := client.Do(request)
	if err != nil {
		return fault.Errorf(fault.Unavailable, "the sign-in on this machine did not answer: %v", err)
	}
	drain(response.Body)
	if response.StatusCode >= 400 {
		return fault.Errorf(fault.Invalid, "the sign-in rejected that address (HTTP %d); start a new sign-in if it expired", response.StatusCode)
	}
	return nil
}

// redirectPort is the port of a URL's redirect_uri query parameter.
func redirectPort(raw string, fallback int) int {
	address, err := url.Parse(raw)
	if err != nil {
		return fallback
	}
	redirect, err := url.Parse(address.Query().Get("redirect_uri"))
	if err != nil || !loopbackHost(redirect.Hostname()) {
		return fallback
	}
	if port, err := strconv.Atoi(redirect.Port()); err == nil && port > 0 {
		return port
	}
	return fallback
}
