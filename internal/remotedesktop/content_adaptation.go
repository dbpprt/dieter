package remotedesktop

import "time"

type contentController struct {
	class, candidate                   string
	candidateSince, interactionUntil   time.Time
	sequence, generation, inputOrdinal uint64
}

// Damage describes changed area, not semantic text or a quality score. Require
// repeated fresh observations before switching the automatic tradeoff. Input
// activity uses acknowledged ordinals, not a merely focused viewer window.
func (c *contentController) observe(now time.Time, sample adaptationSample) string {
	if c.generation != sample.generation {
		*c = contentController{generation: sample.generation}
	}
	if sample.inputOrdinal > c.inputOrdinal {
		c.inputOrdinal = sample.inputOrdinal
		c.interactionUntil = now.Add(2 * time.Second)
	}
	if now.Before(c.interactionUntil) {
		c.class = "interaction"
		c.candidate, c.candidateSince = "", time.Time{}
		return c.class
	}
	if sample.frames.interFrames < 2 {
		c.class = "idle"
		c.candidate, c.candidateSince = "", time.Time{}
		return c.class
	}
	if sample.changedFraction == nil || sample.contentAt.IsZero() || now.Before(sample.contentAt) || now.Sub(sample.contentAt) > 2*time.Second ||
		!finiteBound(*sample.changedFraction, 1) || *sample.changedFraction < 0 {
		c.class, c.candidate = "unknown", ""
		return c.class
	}
	if sample.contentSequence <= c.sequence {
		return c.class
	}
	c.sequence = sample.contentSequence
	candidate := "detail"
	if *sample.changedFraction >= .2 {
		candidate = "motion"
	}
	if candidate != c.candidate {
		c.candidate, c.candidateSince = candidate, now
	}
	if now.Sub(c.candidateSince) >= 2*time.Second {
		c.class = candidate
	}
	if c.class == "" {
		c.class = "unknown"
	}
	return c.class
}
