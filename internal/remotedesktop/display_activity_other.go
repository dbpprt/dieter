//go:build !darwin

package remotedesktop

import "context"

func beginPlatformDisplayActivity(ctx context.Context) (func() error, error) {
	return nil, ctx.Err()
}
