package remotedesktop

import "testing"

func TestDarwinDisplayActivityBindings(t *testing.T) {
	// Resolve the real OS symbols and exercise only CoreFoundation allocation.
	// Never acquire a power assertion or wake the operator's display in a test.
	api, err := loadDarwinDisplayPower()
	if err != nil {
		t.Fatal(err)
	}
	name := api.stringCreate(0, "Dieter display activity ABI test", 0x08000100)
	if name == 0 {
		t.Fatal("CFString allocation failed")
	}
	api.cfRelease(name)
}

func TestDarwinDisplayActivityNativeArguments(t *testing.T) {
	strings := map[uintptr]string{}
	var next uintptr
	created, declared, released := false, false, false
	api := &darwinDisplayPowerAPI{
		stringCreate: func(allocator uintptr, value string, encoding uint32) uintptr {
			if allocator != 0 || encoding != 0x08000100 {
				t.Error("wrong CoreFoundation arguments")
			}
			next++
			strings[next] = value
			return next
		},
		cfRelease: func(ref uintptr) {
			if _, ok := strings[ref]; !ok {
				t.Error("CFString released twice")
			}
			delete(strings, ref)
		},
		create: func(kind uintptr, level uint32, name uintptr, id *uint32) int32 {
			if strings[kind] != "PreventUserIdleDisplaySleep" || level != 255 || strings[name] != "Dieter daemon remote desktop capture" {
				t.Error("wrong IOKit keep-awake arguments")
			}
			*id = 42
			created = true
			return 0
		},
		declare: func(name uintptr, userType uint32, id *uint32) int32 {
			if !created || strings[name] != "Dieter daemon remote desktop connection" || userType != 1 || *id != 0 {
				t.Error("wrong IOKit wake arguments/order")
			}
			*id = 100
			declared = true
			return 0
		},
		release: func(id uint32) int32 {
			if id != 42 {
				t.Error("released wrong assertion")
			}
			released = true
			return 0
		},
	}
	release, err := holdDisplayActivity(t.Context(), api.driver())
	if err != nil {
		t.Fatal(err)
	}
	if err := release(); err != nil {
		t.Fatal(err)
	}
	if !created || !declared || !released || len(strings) != 0 {
		t.Fatal("native ownership leaked")
	}
	if displayPowerStatus("wake", -1) == nil {
		t.Fatal("IOKit failure accepted")
	}
}
