package gateway

import (
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/version"
)

func compatibilityPolicy(config Config) (version.Policy, error) {
	minimumClient := config.MinimumClientVersion
	if minimumClient == "" {
		minimumClient = version.DevelopmentMinimum
	}
	minimumDaemon := config.MinimumDaemonVersion
	if minimumDaemon == "" {
		minimumDaemon = version.DevelopmentMinimum
	}
	issuer := "development"
	if config.IssuerURL != nil || config.PublicURL != nil {
		issuer = config.IdentityOrigin()
	}
	return version.NewPolicy(issuer, buildinfo.ReleaseVersion, minimumClient, minimumDaemon)
}

func protoCompatibilityPolicy(policy version.Policy) *gatewayv1.CompatibilityPolicy {
	return &gatewayv1.CompatibilityPolicy{
		GatewayReleaseVersion: policy.GatewayReleaseVersion,
		MinimumClientVersion:  policy.MinimumClientVersion,
		MinimumDaemonVersion:  policy.MinimumDaemonVersion,
		Revision:              policy.Revision,
	}
}

func protoCompatibilityStatus(value version.Status) gatewayv1.CompatibilityStatus {
	switch value {
	case version.StatusCompatible:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE
	case version.StatusUpdateRequired:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_UPDATE_REQUIRED
	case version.StatusInvalidVersion:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_INVALID_VERSION
	default:
		return gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_UNSPECIFIED
	}
}
