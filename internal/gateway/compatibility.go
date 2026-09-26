package gateway

import (
	"github.com/dbpprt/dieter/internal/buildinfo"
	"github.com/dbpprt/dieter/internal/compatibility"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

func compatibilityPolicy(config Config) (compatibility.Policy, error) {
	minimumClient := config.MinimumClientVersion
	if minimumClient == "" {
		minimumClient = compatibility.DevelopmentMinimum
	}
	minimumDaemon := config.MinimumDaemonVersion
	if minimumDaemon == "" {
		minimumDaemon = compatibility.DevelopmentMinimum
	}
	issuer := "development"
	if config.IssuerURL != nil || config.PublicURL != nil {
		issuer = config.IdentityOrigin()
	}
	return compatibility.NewPolicy(issuer, buildinfo.ReleaseVersion, minimumClient, minimumDaemon)
}

func protoCompatibilityPolicy(policy compatibility.Policy) *gatewayv1.CompatibilityPolicy {
	return &gatewayv1.CompatibilityPolicy{
		GatewayReleaseVersion: policy.GatewayReleaseVersion,
		MinimumClientVersion:  policy.MinimumClientVersion,
		MinimumDaemonVersion:  policy.MinimumDaemonVersion,
		Revision:              policy.Revision,
	}
}

func protoCompatibilityStatus(value compatibility.Status) gatewayv1.CompatibilityStatus {
	switch value {
	case compatibility.StatusCompatible:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE
	case compatibility.StatusUpdateRequired:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_UPDATE_REQUIRED
	case compatibility.StatusInvalidVersion:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_INVALID_VERSION
	default:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_UNSPECIFIED
	}
}
