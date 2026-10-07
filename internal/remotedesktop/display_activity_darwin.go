package remotedesktop

import (
	"context"
	"fmt"
	"sync"

	"github.com/ebitengine/purego"
)

// Native scalar signatures from IOPMLib.h/CoreFoundation. Dynamic binding keeps
// the daemon's CGO_ENABLED=0 release build; no capture-helper/app update is needed.
type darwinDisplayPowerAPI struct {
	stringCreate func(uintptr, string, uint32) uintptr
	cfRelease    func(uintptr)
	create       func(uintptr, uint32, uintptr, *uint32) int32
	declare      func(uintptr, uint32, *uint32) int32
	release      func(uint32) int32
}

var loadDarwinDisplayPower = sync.OnceValues(func() (*darwinDisplayPowerAPI, error) {
	cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, fmt.Errorf("load macOS display activity: %w", err)
	}
	io, err := purego.Dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		_ = purego.Dlclose(cf)
		return nil, fmt.Errorf("load macOS display activity: %w", err)
	}
	api := &darwinDisplayPowerAPI{}
	for _, binding := range []struct {
		library uintptr
		name    string
		fn      any
	}{
		{cf, "CFStringCreateWithCString", &api.stringCreate},
		{cf, "CFRelease", &api.cfRelease},
		{io, "IOPMAssertionCreateWithName", &api.create},
		{io, "IOPMAssertionDeclareUserActivity", &api.declare},
		{io, "IOPMAssertionRelease", &api.release},
	} {
		symbol, err := purego.Dlsym(binding.library, binding.name)
		if err != nil {
			_ = purego.Dlclose(io)
			_ = purego.Dlclose(cf)
			return nil, fmt.Errorf("bind macOS display activity %s: %w", binding.name, err)
		}
		purego.RegisterFunc(binding.fn, symbol)
	}
	// Successful bindings live for the daemon's lifetime, not a capture's lifetime.
	return api, nil
})

func beginPlatformDisplayActivity(ctx context.Context) (func() error, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	api, err := loadDarwinDisplayPower()
	if err != nil {
		return nil, err
	}
	return holdDisplayActivity(ctx, api.driver())
}

func (api *darwinDisplayPowerAPI) driver() displayPowerDriver {
	return displayPowerDriver{
		create: func() (uint32, error) {
			kind := api.stringCreate(0, "PreventUserIdleDisplaySleep", 0x08000100) // kCFStringEncodingUTF8
			if kind == 0 {
				return 0, fmt.Errorf("allocate macOS display assertion type")
			}
			defer api.cfRelease(kind)
			name := api.stringCreate(0, "Dieter daemon remote desktop capture", 0x08000100)
			if name == 0 {
				return 0, fmt.Errorf("allocate macOS display assertion name")
			}
			defer api.cfRelease(name)
			var id uint32
			status := api.create(kind, 255, name, &id) // kIOPMAssertionLevelOn
			return id, displayPowerStatus("keep awake", status)
		},
		wake: func() error {
			name := api.stringCreate(0, "Dieter daemon remote desktop connection", 0x08000100)
			if name == 0 {
				return fmt.Errorf("allocate macOS display wake name")
			}
			defer api.cfRelease(name)
			// User-activity assertions expire automatically.
			var id uint32
			return displayPowerStatus("wake", api.declare(name, 1, &id)) // kIOPMUserActiveRemote
		},
		release: func(id uint32) error {
			return displayPowerStatus("release keep-awake", api.release(id))
		},
	}
}

func displayPowerStatus(operation string, status int32) error {
	if status == 0 { // kIOReturnSuccess
		return nil
	}
	return fmt.Errorf("macOS display %s failed (IOKit status %#x)", operation, uint32(status))
}
