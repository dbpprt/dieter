package remotedesktop

import (
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"math"
	"testing"
	"time"
)

func TestCaptureDamageNeverRefreshesFromOldGenerationOrRepeatedSequence(t *testing.T) {
	s := &Session{status: &dieterv1.RemoteDesktopSessionState{DisplayGeneration: 2}}
	s.nativeEvent(SourceEvent{Content: &nativeContent{Generation: 2, Sequence: 1, Samples: 30, ChangedFraction: .5}})
	at := s.contentMeasuredAt
	if at.IsZero() || s.status.GetContentChangedFraction() != .5 {
		t.Fatal("valid capture damage missing")
	}
	for _, v := range []nativeContent{
		{Generation: 1, Sequence: 2, Samples: 30, ChangedFraction: 1},
		{Generation: 2, Sequence: 1, Samples: 30, ChangedFraction: 1},
		{Generation: 2, Sequence: 2, Samples: 30, ChangedFraction: math.NaN()},
		{Generation: 2, Sequence: 2, Samples: 30, ChangedFraction: -1},
	} {
		s.nativeEvent(SourceEvent{Content: &v})
		if s.contentMeasuredAt != at || s.status.GetContentChangedFraction() != .5 {
			t.Fatal("invalid damage became fresh evidence")
		}
	}
}

func TestContentClassificationRequiresFreshSustainedDamage(t *testing.T) {
	now := time.Now()
	motion, detail := .9, .01
	c := contentController{}
	s := adaptationSample{frames: frameMeasurements{interFrames: 30}, generation: 1, contentAt: now, changedFraction: &motion}
	for i := 0; i < 3; i++ {
		s.contentAt = now.Add(time.Duration(i) * time.Second)
		s.contentSequence++
		c.observe(s.contentAt, s)
	}
	if c.class != "motion" {
		t.Fatal(c.class)
	}
	s.changedFraction = &detail
	s.contentSequence++
	c.observe(s.contentAt, s)
	if c.class != "motion" {
		t.Fatal("one detail sample switched policy")
	}
	s.inputOrdinal = 1
	if c.observe(s.contentAt, s) != "interaction" {
		t.Fatal("input did not get priority")
	}
	if c.observe(s.contentAt.Add(3*time.Second), s) != "unknown" {
		t.Fatal("stale damage became current evidence")
	}
	s.frames.interFrames = 0
	if c.observe(s.contentAt.Add(4*time.Second), s) != "idle" {
		t.Fatal("idle misclassified")
	}
	s.generation = 2
	s.frames.interFrames = 30
	s.contentSequence = 1
	s.contentAt = now.Add(5 * time.Second)
	s.inputOrdinal = 0
	if c.observe(s.contentAt, s) == "motion" {
		t.Fatal("old display classification survived reset")
	}
}

func TestIdleRefinementStopsWithoutNewCapacityEvidence(t *testing.T) {
	now := time.Now()
	c := idleRefreshController{}
	count := 0
	for i := 0; i < 60; i++ {
		if c.due(now.Add(time.Duration(i)*time.Second), true, true, true) {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("unbounded idle redraws: %d", count)
	}
	c.configured(StreamConfiguration{BitrateKbps: 1000}, StreamConfiguration{BitrateKbps: 2000}, true)
	if !c.due(now.Add(time.Minute), true, true, false) {
		t.Fatal("new quality did not receive a refinement frame")
	}
}
