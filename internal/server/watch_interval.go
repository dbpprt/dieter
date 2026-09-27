package server

import (
	"time"
)

func boundedInterval(milliseconds int32, fallback time.Duration) time.Duration {
	interval := time.Duration(milliseconds) * time.Millisecond
	if interval <= 0 {
		interval = fallback
	}
	if interval < 100*time.Millisecond {
		return 100 * time.Millisecond
	}
	if interval > 5*time.Second {
		return 5 * time.Second
	}
	return interval
}
