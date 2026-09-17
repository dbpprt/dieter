package remotedesktop

import (
	"context"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const fastBitrateInterval = 100 * time.Millisecond

// This lane only reduces bitrate. Geometry, cadence and recovery still belong
// to the slow quality controller. Consume actual TWCC evidence once, rather
// than repeatedly acting on GCC's last estimate while the desktop is idle.
type fastBitrateController struct {
	observed, pressureSince, holdUntil time.Time
	ceiling                            int
}

func (c *fastBitrateController) next(now time.Time, current, limit, estimate int, h transportHealth) int {
	if h.at.IsZero() || !h.at.After(c.observed) || now.Before(h.at) || now.Sub(h.at) > 500*time.Millisecond ||
		h.sentAt.IsZero() || now.Before(h.sentAt) || now.Sub(h.sentAt) > 500*time.Millisecond {
		return current
	}
	previous := c.observed
	c.observed = h.at
	if h.packets < 3 || h.span < 20*time.Millisecond {
		c.pressureSince = time.Time{}
		return current
	}
	queued := h.growthMS > 15
	if !queued {
		c.pressureSince = time.Time{}
	} else if c.pressureSince.IsZero() || h.at.Sub(previous) > 500*time.Millisecond {
		c.pressureSince = h.at
	}
	// Two reports spanning at least 100 ms distinguish sustained queue growth
	// from one delayed ACK burst. Loss can act immediately, but low traffic on
	// a static desktop is never treated as a measurement of link capacity.
	if h.loss < .02 && (!queued || h.at.Sub(c.pressureSince) < fastBitrateInterval) {
		return current
	}
	target := min(limit, current*85/100)
	if queued && h.at.Sub(c.pressureSince) >= fastBitrateInterval && h.deliveredRate > 0 {
		target = min(target, h.deliveredRate*85/100/1000)
	}
	if estimate > 0 {
		target = min(target, estimate*85/100/1000)
	}
	target = max(100, target)
	if current-target < max(50, current/10) {
		return current
	}
	return target
}

func (c *fastBitrateController) applied(now time.Time, rate int) {
	c.ceiling, c.holdUntil = rate, now.Add(2*time.Second)
}

func (s *Session) reduceBitrate(now time.Time, fast *fastBitrateController, controller *qualityController,
	state *dieterv1.RemoteDesktopSessionState, current StreamConfiguration, revision uint64, transport transportHealth,
) {
	source, ok := s.source.(AdaptiveFrameSource)
	if !ok || state.Configuration == nil {
		return
	}
	// Ignore retained probe capacity when fresh feedback proves congestion.
	s.pacer.mu.Lock()
	estimate := s.pacer.bitrate
	if s.pacer.bitrateUpdated.IsZero() || now.Sub(s.pacer.bitrateUpdated) > 500*time.Millisecond || now.Before(s.pacer.bitrateUpdated) {
		estimate = 0
	}
	s.pacer.mu.Unlock()
	rate := fast.next(now, current.BitrateKbps, fecMediaBudget(int(state.Configuration.MaxBitrateKbps), int(s.pacer.fecPercent.Load())), estimate, transport)
	if rate == current.BitrateKbps {
		return
	}
	s.configurationMu.Lock()
	defer s.configurationMu.Unlock()
	s.mu.Lock()
	valid := !s.closed && s.configurationRevision == revision && s.applied == current
	s.mu.Unlock()
	if !valid {
		return
	}
	desired := current
	desired.BitrateKbps = rate
	// Shared sources split renditions where necessary; an exclusively owned
	// encoder updates VideoToolbox in place without a resize or forced IDR.
	ctx, cancel := context.WithTimeout(s.ctx, time.Second)
	defer cancel()
	started := time.Now()
	err := source.Configure(ctx, desired)
	if err != nil {
		if logger := s.manager.options.Logger; logger != nil {
			logger.Warn("remote desktop fast bitrate failed", "session", s.id, "error", err)
		}
		return
	}
	s.mu.Lock()
	s.applied = desired
	s.mu.Unlock()
	fast.applied(now, rate)
	controller.applied(now, current, desired)
	controller.budget = float64(rate)
	controller.upSince, controller.largerSince = time.Time{}, time.Time{}
	// Revoke probe headroom immediately, without waiting for the geometry
	// controller's more conservative 500 ms congestion classification.
	s.pacer.ObserveNetwork(now, false)
	if logger := s.manager.options.Logger; logger != nil {
		logger.Info("remote desktop fast bitrate", "session", s.id, "before_kbps", current.BitrateKbps,
			"bitrate_kbps", rate, "feedback_age_ms", now.Sub(transport.at).Milliseconds(),
			"configure_ms", time.Since(started).Milliseconds(), "transport_growth_ms", transport.growthMS,
			"loss", transport.loss, "delivered_kbps", transport.deliveredRate/1000)
	}
}
