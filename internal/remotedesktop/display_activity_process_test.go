//go:build darwin || linux

package remotedesktop

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

func TestNativeDisplayActivityHoldsUntilChildExit(t *testing.T) {
	directory := t.TempDir()
	started, exited := filepath.Join(directory, "started"), filepath.Join(directory, "exited")
	helper := filepath.Join(directory, "capture")
	script := fmt.Sprintf("#!/bin/sh\ntrap 'exit 0' TERM\ntrap 'printf stopped > \"%s\"' EXIT\nprintf started > \"%s\"\nprintf DTH2\nwhile read -r line; do :; done\n", exited, started)
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	released := make(chan struct{})
	s := &nativeHelperSource{path: helper, displayActivity: func(ctx context.Context) (func() error, error) {
		return holdDisplayActivity(ctx, displayPowerDriver{
			create: func() (uint32, error) { return 1, nil }, wake: func() error { return nil },
			release: func(uint32) error {
				if _, err := os.Stat(exited); err != nil {
					t.Error("power assertion released before child teardown", err)
				}
				close(released)
				return nil
			},
		})
	}}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- s.Stream(ctx, func(media.Sample) error { return nil }) }()
	for {
		if _, err := os.Stat(started); err == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("fixture did not start")
		case <-time.After(10 * time.Millisecond):
		}
	}
	select {
	case <-released:
		t.Fatal("active child lost keep-awake")
	default:
	}
	cancel()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("fixture teardown did not finish")
	}
	select {
	case <-released:
	default:
		t.Fatal("child exit leaked keep-awake")
	}
}

func TestNativeDisplayActivityCleanupFailureOverridesProbeCompletion(t *testing.T) {
	directory := t.TempDir()
	framePath := filepath.Join(directory, "frame")
	raw := append([]byte(nativeCaptureMagic), make([]byte, nativeCaptureHeaderSize)...)
	binary.BigEndian.PutUint32(raw[4:8], 1)
	binary.BigEndian.PutUint32(raw[52:56], 2)
	binary.BigEndian.PutUint32(raw[56:60], 2)
	raw = append(raw, 1)
	if err := os.WriteFile(framePath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(directory, "capture")
	script := fmt.Sprintf("#!/bin/sh\ncat \"%s\"\nwhile read -r line; do :; done\n", framePath)
	if err := os.WriteFile(helper, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("release failed")
	releases := 0
	s := &nativeHelperSource{path: helper, displayActivity: func(context.Context) (func() error, error) {
		return func() error { releases++; return failure }, nil
	}}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	err := s.Stream(ctx, func(media.Sample) error { return errCaptureProbeComplete })
	if !errors.Is(err, failure) || errors.Is(err, errCaptureProbeComplete) || releases != 2 {
		t.Fatalf("probe hid failed cleanup: error=%v releases=%d", err, releases)
	}
}

func TestNativeDisplayActivityMultiplexerRetainsUntilLastSource(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "capture")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nprintf DTH3\nwhile read -r line; do :; done\n"), 0700); err != nil {
		t.Fatal(err)
	}
	released := make(chan struct{})
	acquired := 0
	template := &nativeHelperSource{path: helper, displayActivity: func(ctx context.Context) (func() error, error) {
		acquired++
		return holdDisplayActivity(ctx, displayPowerDriver{
			create: func() (uint32, error) { return 1, nil }, wake: func() error { return nil },
			release: func(uint32) error { close(released); return nil },
		})
	}}
	mux := newNativeMultiplexer()
	t.Cleanup(mux.Close)
	first, err := mux.Source(template)
	if err != nil {
		t.Fatal(err)
	}
	second, err := mux.Source(template)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	root, err := mux.process(ctx, template)
	if err != nil {
		t.Fatal(err)
	}
	if shared, err := mux.process(ctx, template); err != nil || shared != root || acquired != 1 {
		t.Fatalf("process ownership not shared: root=%p shared=%p error=%v acquisitions=%d", root, shared, err, acquired)
	}
	first.(*nativeRendition).Close()
	select {
	case <-released:
		t.Fatal("one rendition released another's power ownership")
	default:
	}
	second.(*nativeRendition).Close()
	mux.mu.Lock()
	finished := mux.finished
	mux.mu.Unlock()
	select {
	case <-finished:
	case <-ctx.Done():
		t.Fatal("last source teardown did not finish")
	}
	select {
	case <-released:
	default:
		t.Fatal("last source leaked power ownership")
	}
}
