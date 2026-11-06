package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestDaemonExposesOnlyCurrentRPCContract(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	application := New(data, nil)
	for _, path := range []string{"/", "/api/v1/state", "/auth/session", "/auth/github/login", "/auth/github/callback", "/auth/native/token"} {
		request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1"+path, nil)
		request.Header.Set(localauth.Header, application.localToken)
		response := httptest.NewRecorder()
		application.Handler().ServeHTTP(response, request)
		if response.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d", path, response.Code)
		}
	}
	health, err := (newService(application)).Health(context.Background(), nil)
	if err != nil || health.GetReleaseVersion() != buildinfo.ReleaseVersion {
		t.Fatalf("health=%v err=%v", health, err)
	}
}
