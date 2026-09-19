package daemon

import (
	"context"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

// ProviderQuotaSource keeps provider credentials and raw responses local to
// the daemon. Values crossing the gateway link are normalized and contain only
// an owner-scoped account HMAC plus bounded quota metadata.
type ProviderQuotaSource interface {
	Discover(context.Context, []byte) (*gatewayv1.ProviderAccountsPresence, error)
	Refresh(context.Context, []byte, *gatewayv1.ProviderQuotaRefreshRequest) (*gatewayv1.ProviderQuotaRefreshResult, error)
}
