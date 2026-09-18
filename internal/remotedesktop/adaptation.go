package remotedesktop

import (
	"math"
	"os"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

// Measurements are consumed once per interval. In particular an idle desktop
// must not turn one slow keyframe into an unlimited sequence of bad samples.
type frameMeasurements struct {
	frames, interFrames, bytes, interBytes uint64
	encodeMS, writeMS, sendMS              float64
}

type adaptationSample struct {
	frames                                    frameMeasurements
	feedback                                  *dieterv1.RemoteDesktopReceiverFeedback
	feedbackAt                                time.Time
	budget, width, height                     int
	drops                                     uint64
	elapsed                                   time.Duration
	networkPressure                           bool
	confirmedBudget                           int
	changedFraction                           *float64
	contentAt                                 time.Time
	contentSequence, generation, inputOrdinal uint64
}

// Keep the redraw pending across the probe cooldown, even after the encoder
// reaches its bitrate ceiling and no longer qualifies as degraded.
type idleRefreshController struct {
	last     time.Time
	pending  bool
	attempts int
}

func (c *idleRefreshController) configured(before, after StreamConfiguration, idle bool) {
	if idle && after.BitrateKbps > before.BitrateKbps {
		c.pending = true
		c.attempts = 0
	}
}

func (c *idleRefreshController) due(now time.Time, idle, healthy, belowBudget bool) bool {
	if !idle {
		c.attempts = 0
		c.pending = false
		return false
	}
	if !c.pending && c.attempts >= 2 {
		return false
	}
	if !idle || !healthy || (!c.pending && !belowBudget) || now.Sub(c.last) < 3*time.Second {
		return false
	}
	c.last, c.pending = now, false
	c.attempts++
	return true
}

type qualityController struct {
	content                                             contentController
	contentEnabled                                      bool
	bitsPerPixel                                        float64
	started, lastActive, lastFPS, lastSize, lastBitrate time.Time
	downSince, upSince, smallerSince, largerSince       time.Time
	feedbackSequence                                    uint64
	budget, encodeMS, decodeMS, writeMS                 float64
	aspect                                              float64
	maxWidth, maxHeight                                 int
}

func newQualityController(now time.Time) *qualityController {
	return &qualityController{started: now, lastFPS: now, lastSize: now, lastBitrate: now, contentEnabled: os.Getenv("DIETER_SCREEN_CONTENT_ADAPTATION") == "1"}
}

func smooth(previous, value, weight float64) float64 {
	if previous == 0 {
		return value
	}
	return previous + weight*(value-previous)
}

func sustained(now time.Time, since *time.Time, condition bool, duration time.Duration) bool {
	if !condition {
		*since = time.Time{}
		return false
	}
	if since.IsZero() {
		*since = now
	}
	return now.Sub(*since) >= duration
}

func fpsStep(limit int) int {
	for _, fps := range []int{120, 90, 60, 45, 30, 24, 15, 10, 5, 1} {
		if fps <= limit {
			return fps
		}
	}
	return 1
}

func nextFPS(current, ceiling int) int {
	for _, fps := range []int{5, 10, 15, 24, 30, 45, 60, 90, 120} {
		if fps > current {
			return min(fps, ceiling)
		}
	}
	return ceiling
}

func fitVideo(width, height int, aspect float64) (int, int) {
	if aspect <= 0 {
		aspect = float64(width) / float64(height)
	}
	w := min(float64(width), float64(height)*aspect)
	return max(2, int(w)&^1), max(2, int(w/aspect)&^1)
}

// next makes one decision from fresh observations. Decode capacity is an
// absolute ceiling, shared by reduction and recovery; two competing relative
// rules cannot alternately raise and lower the frame rate.
func (c *qualityController) next(now time.Time, current StreamConfiguration, limits *dieterv1.RemoteDesktopStreamConfiguration, sample adaptationSample) (StreamConfiguration, string) {
	desired := current
	contentClass := c.content.observe(now, sample)
	sequence := sample.feedback.GetMeasurementSequence()
	if sequence == 0 {
		sequence = sample.feedback.GetSequence()
	}
	freshFeedback := sample.feedback != nil && sequence > c.feedbackSequence && now.Sub(sample.feedbackAt) <= 2*time.Second
	if freshFeedback {
		c.feedbackSequence = sequence
	}
	// A quiet desktop is neither congestion nor proof of spare capacity. Pause
	// recovery evidence instead of erasing it (or counting idle as healthy video).
	pauseRecovery := func() {
		if !c.upSince.IsZero() {
			c.upSince = c.upSince.Add(sample.elapsed)
		}
		if !c.largerSince.IsZero() {
			c.largerSince = c.largerSince.Add(sample.elapsed)
		}
	}
	active := sample.frames.interFrames >= 2
	if !active {
		c.downSince, c.smallerSince = time.Time{}, time.Time{}
		if sample.networkPressure || (freshFeedback && sample.feedback.LossFraction >= .02) {
			c.upSince, c.largerSince = time.Time{}, time.Time{}
		} else {
			pauseRecovery()
		}
		// Silence alone proves nothing, but acknowledged probe traffic does.
		// Restore bitrate without inventing decode capacity or resizing an idle
		// display. The next bounded recovery refresh replaces the blurry image.
		if freshFeedback && !sample.networkPressure && sample.feedback.LossFraction < .02 &&
			sample.confirmedBudget > current.BitrateKbps && now.Sub(c.lastBitrate) >= time.Second {
			target := min(sample.confirmedBudget, int(limits.MaxBitrateKbps))
			if target-current.BitrateKbps >= max(150, current.BitrateKbps/5) {
				desired.BitrateKbps = target
				c.budget = float64(target)
				return desired, "acknowledged idle bitrate recovery"
			}
		}
		return desired, "idle or keyframe-only interval"
	}
	if !c.lastActive.IsZero() && now.Sub(c.lastActive) > 3*time.Second {
		c.encodeMS, c.decodeMS, c.writeMS = 0, 0, 0
		// Resume at the established quality. Wait for a new run of congestion
		// evidence before changing geometry after a sparse/idle interval.
		c.started = now
	}
	c.lastActive = now
	if sample.width > 0 && sample.height > 0 {
		c.aspect = float64(sample.width) / float64(sample.height)
		c.maxWidth, c.maxHeight = max(c.maxWidth, sample.width), max(c.maxHeight, sample.height)
	}
	if c.aspect <= 0 {
		c.aspect = float64(limits.MaxWidth) / float64(limits.MaxHeight)
	}
	budget := float64(max(100, min(sample.budget, int(limits.MaxBitrateKbps))))
	weight := .25
	if budget < c.budget {
		weight = .5
	}
	c.budget = smooth(c.budget, budget, weight)
	c.encodeMS = smooth(c.encodeMS, sample.frames.encodeMS/float64(sample.frames.interFrames), .25)
	// Sending includes pacing because the one-credit pipeline serializes it
	// behind encode. Never confuse a fast socket write with a fast frame drain.
	c.writeMS = smooth(c.writeMS, max(sample.frames.writeMS, sample.frames.sendMS)/float64(sample.frames.interFrames), .25)
	if freshFeedback && sample.feedback.DecodeMs > 0 && sample.feedback.FramesPerSecond > 0 {
		c.decodeMS = smooth(c.decodeMS, sample.feedback.DecodeMs, .25)
	}
	loss := 0.0
	if freshFeedback {
		loss = max(0, sample.feedback.LossFraction)
	}
	// This is pipeline capacity, not congestion evidence. TWCC/loss still owns
	// network-pressure decisions. Conservative when overlap is enabled.
	costMS := c.encodeMS + c.writeMS
	if freshFeedback && sample.feedback.DecodeMs > 0 && sample.feedback.FramesPerSecond > 0 {
		costMS = max(costMS, c.decodeMS)
	}
	ceiling := int(limits.MaxFps)
	minFPS := min(15, ceiling)
	motion := limits.Quality == dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_MOTION
	if c.contentEnabled && limits.Quality == dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_AUTO && contentClass == "motion" {
		motion = true
	}
	if limits.Quality == dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_DETAIL {
		ceiling, minFPS = min(30, ceiling), min(10, ceiling)
	} else if limits.Quality == dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_MOTION {
		minFPS = min(30, ceiling)
	}
	computeFPS := ceiling
	if costMS > 0 {
		computeFPS = min(ceiling, max(1, int(800/costMS)))
	}
	w, h := fitVideo(current.MaxWidth, current.MaxHeight, c.aspect)
	if sample.width > 0 && sample.height > 0 {
		w, h = sample.width, sample.height
	}
	bitsPerPixel := .055
	if c.contentEnabled && sample.frames.interBytes > 0 && sample.frames.interFrames >= 3 && !sample.networkPressure && loss < .02 {
		observed := float64(sample.frames.interBytes*8) / float64(w*h) / float64(sample.frames.interFrames)
		c.bitsPerPixel = smooth(c.bitsPerPixel, min(.2, max(.012, observed)), .2)
	}
	if c.contentEnabled && c.bitsPerPixel > 0 {
		bitsPerPixel = c.bitsPerPixel
	}
	perFPS := float64(w*h) * bitsPerPixel / 1000
	mediaKbps := float64(sample.frames.bytes*8) / max(.1, sample.elapsed.Seconds()) / 1000
	// A low estimate alone is not evidence that a mostly static screen needs
	// fewer pixels. Require actual traffic pressure or fresh receiver loss.
	// Saturating our own low bitrate cap is not evidence that the link is full.
	// Require sustained transport queue growth or loss before removing pixels.
	pressure := (sample.networkPressure && mediaKbps >= c.budget*.65) || loss >= .03
	networkFPS := ceiling
	// Motion trades pixels before cadence while there is room to shrink.
	if pressure && (!motion || w <= min(640, int(limits.MaxWidth))) {
		networkFPS = max(minFPS, int(c.budget/max(.001, perFPS)))
	}
	targetFPS := min(computeFPS, networkFPS)
	reason := "stable"
	if now.Sub(c.lastBitrate) >= time.Second {
		targetRate := max(100, min(int(c.budget), int(limits.MaxBitrateKbps)))
		// Limit changes to useful steps; small estimator noise must not create a
		// configuration command on every receiver report.
		if abs64(int64(targetRate-current.BitrateKbps)) >= int64(max(150, current.BitrateKbps/5)) {
			desired.BitrateKbps = targetRate
			reason = "bandwidth budget"
		}
	}
	warm := now.Sub(c.started) >= 5*time.Second
	if sustained(now, &c.downSince, warm && targetFPS < current.FPS, 2*time.Second) && now.Sub(c.lastFPS) >= 4*time.Second {
		desired.FPS = min(ceiling, fpsStep(targetFPS))
		reason = "sustained frame-rate pressure"
	}
	next := nextFPS(current.FPS, ceiling)
	receiverHealthy := freshFeedback && sample.feedback.FramesPerSecond > 0
	canRaiseFPS := receiverHealthy && next > current.FPS && loss < .02 && (costMS == 0 || costMS*float64(next) <= 700) && (!pressure || c.budget >= perFPS*float64(next)*1.25)
	if !freshFeedback {
		pauseRecovery()
	}
	if freshFeedback && sustained(now, &c.upSince, canRaiseFPS && !sample.networkPressure, 10*time.Second) && now.Sub(c.lastFPS) >= 10*time.Second {
		desired.FPS = next
		reason = "sustained frame-rate recovery"
	}
	// Automatic/detail lower cadence first, requiring sustained pressure and
	// time for the new FPS to settle. Motion permits earlier spatial reductions.
	needSmaller := warm && current.FPS <= minFPS && pressure && c.budget < perFPS*float64(minFPS)*.75
	sizePressureTime, resizeInterval := 8*time.Second, 12*time.Second
	if motion {
		needSmaller = warm && pressure && c.budget < perFPS*float64(current.FPS)*.85
		sizePressureTime, resizeInterval = time.Second, 4*time.Second
	}
	if sustained(now, &c.smallerSince, needSmaller, sizePressureTime) && desired.FPS == current.FPS && now.Sub(c.lastSize) >= resizeInterval && now.Sub(c.lastFPS) >= 4*time.Second {
		floorWidth := min(640, w)
		width := max(floorWidth, (w*4/5)/160*160)
		if width < w {
			desired.MaxWidth, desired.MaxHeight = fitVideo(width, current.MaxHeight, c.aspect)
			reason = "sustained resolution pressure"
			if motion {
				reason = "preserve motion cadence"
			}
		}
	}
	fullW, fullH := fitVideo(int(limits.MaxWidth), int(limits.MaxHeight), c.aspect)
	if c.maxWidth > 0 && c.maxHeight > 0 {
		fullW, fullH = min(fullW, c.maxWidth), min(fullH, c.maxHeight)
	}
	nextW := min(fullW, int(math.Ceil(float64(w)*1.25/160))*160)
	nextH := min(fullH, int(float64(nextW)/c.aspect)&^1)
	pixelGrowth := float64(nextW*nextH) / float64(w*h)
	canRaiseSize := receiverHealthy && nextW > w && loss < .02 && costMS*pixelGrowth*float64(current.FPS) <= 700 && c.budget >= float64(nextW*nextH)*float64(current.FPS)*bitsPerPixel/1000*1.35
	if freshFeedback && sustained(now, &c.largerSince, canRaiseSize && !sample.networkPressure, 15*time.Second) && desired.FPS == current.FPS && now.Sub(c.lastSize) >= 15*time.Second && now.Sub(c.lastFPS) >= 4*time.Second {
		desired.MaxWidth, desired.MaxHeight = nextW, nextH
		reason = "sustained resolution recovery"
	}
	return desired, reason
}

func (c *qualityController) applied(now time.Time, before, after StreamConfiguration) {
	if before.FPS != after.FPS {
		c.lastFPS = now
		c.downSince, c.upSince = time.Time{}, time.Time{}
	}
	if before.MaxWidth != after.MaxWidth || before.MaxHeight != after.MaxHeight {
		c.lastSize = now
		c.smallerSince, c.largerSince = time.Time{}, time.Time{}
	}
	if before.BitrateKbps != after.BitrateKbps {
		c.lastBitrate = now
	}
}
