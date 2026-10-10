package server

import (
	"net/http"

	"github.com/dbpprt/dieter/internal/localauth"
	"google.golang.org/grpc"
)

// localTokenTransport presents the raw API token the way the CLI does. It
// reads the file per request so it also follows a daemon started later.
type localTokenTransport struct {
	base http.RoundTripper
	root string
}

func (t localTokenTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	token, err := localauth.Read(t.root)
	if err != nil {
		return nil, err
	}
	request = request.Clone(request.Context())
	request.Header.Set(localauth.Header, token)
	return t.base.RoundTrip(request)
}

func localHTTPClient(base *http.Client, root string) *http.Client {
	client := *base
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = localTokenTransport{base: transport, root: root}
	return &client
}

func localGRPCToken(root string) grpc.DialOption {
	return grpc.WithPerRPCCredentials(localauth.FileCredentials{Root: root})
}
