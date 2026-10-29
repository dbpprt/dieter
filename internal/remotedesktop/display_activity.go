package remotedesktop

import (
	"context"
	"sync"
)

// A release may be returned alongside an error: acquisition can succeed before
// wake or cancellation fails. The caller must install cleanup before checking err.
type displayActivityFactory func(context.Context) (release func() error, err error)

type displayPowerDriver struct {
	create  func() (uint32, error)
	wake    func() error
	release func(uint32) error
}

func holdDisplayActivity(ctx context.Context, driver displayPowerDriver) (func() error, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	id, err := driver.create()
	if err != nil {
		return nil, err
	}
	var mu sync.Mutex
	held := true
	release := func() error {
		mu.Lock()
		defer mu.Unlock()
		if !held {
			return nil
		}
		if err := driver.release(id); err != nil {
			return err // Retain ownership for a cleanup retry.
		}
		held = false
		return nil
	}
	if err := ctx.Err(); err != nil {
		return release, err
	}
	// Preventing idle sleep does not wake an already sleeping monitor. Acquire
	// first, then declare activity, before the native helper can discover displays.
	if err := driver.wake(); err != nil {
		return release, err
	}
	return release, ctx.Err()
}

func (s *nativeHelperSource) beginDisplayActivity(ctx context.Context) (func() error, error) {
	if s.synthetic {
		return nil, ctx.Err()
	}
	factory := s.displayActivity
	if factory == nil {
		factory = beginPlatformDisplayActivity
	}
	return factory(ctx)
}
