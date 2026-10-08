// Package policy defines quota polling intervals shared by the daemon and gateway.
package policy

import (
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

func RefreshInterval(provider gatewayv1.ProviderQuotaProvider) time.Duration {
	if provider == gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE {
		return 5 * time.Minute
	}
	return time.Minute
}

func FailureBackoff(provider gatewayv1.ProviderQuotaProvider, failures int) time.Duration {
	if provider == gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE {
		return 10 * time.Minute
	}
	steps := [...]time.Duration{time.Minute, 2 * time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour}
	if failures <= 1 {
		return steps[0]
	}
	if failures >= len(steps) {
		return steps[len(steps)-1]
	}
	return steps[failures-1]
}
