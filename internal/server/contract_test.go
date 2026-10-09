package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dbpprt/dieter/internal/buildinfo"
	"github.com/dbpprt/dieter/internal/store"
)

func TestDaemonExposesOnlyCurrentRPCContract(t *testing.T) {
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	application := New(data, nil)
	for _, path := range []string{"/", "/api/v1/state", "/auth/session", "/auth/github/login", "/auth/github/callback", "/auth/native/token"} {
		request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1"+path, nil)
		response := httptest.NewRecorder()
		application.Handler().ServeHTTP(response, request)
		if response.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d", path, response.Code)
		}
	}
	health, err := (&grpcAPI{server: application}).Health(context.Background(), nil)
	if err != nil || health.GetReleaseVersion() != buildinfo.ReleaseVersion {
		t.Fatalf("health=%v err=%v", health, err)
	}
}
