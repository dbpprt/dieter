package testkit

import (
	"net/http"
	"net/http/httptest"
)

// Protocols serves HTTP/1.1 and HTTP/2 with prior knowledge on a plaintext
// listener, like the daemon's loopback API: gRPC clients speak HTTP/2 and
// Connect clients either.
func Protocols() *http.Protocols {
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	return protocols
}

// HTTPServer starts a plaintext test server for handler that accepts both
// HTTP/1.1 and prior-knowledge HTTP/2. Close it when done.
func HTTPServer(handler http.Handler) *httptest.Server {
	server := httptest.NewUnstartedServer(handler)
	server.Config.Protocols = Protocols()
	server.Start()
	return server
}
