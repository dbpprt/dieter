package remotedesktop

import (
	"math"
	"time"

	"github.com/pion/webrtc/v4"
)

// ICE consent timestamps prevent a repeatedly read statistic from making an
// old RTT sample fresh. This fills the initial receiver-statistics gap without
// assuming that a zero/unknown RTT means LAN. All clocks here are host clocks.
func recoveryRTTFromStats(now time.Time, report webrtc.StatsReport) (time.Duration, time.Time) {
	var newest time.Time
	var rtt time.Duration
	for _, stat := range report {
		pair, ok := stat.(webrtc.ICECandidatePairStats)
		if !ok || !pair.Nominated || pair.State != webrtc.StatsICECandidatePairStateSucceeded ||
			pair.CurrentRoundTripTime <= 0 || pair.CurrentRoundTripTime > 10 || math.IsNaN(pair.CurrentRoundTripTime) {
			continue
		}
		measured := pair.LastResponseTimestamp.Time()
		if measured.After(now) || now.Sub(measured) > 2*time.Second || !measured.After(newest) {
			continue
		}
		newest, rtt = measured, time.Duration(pair.CurrentRoundTripTime*float64(time.Second))
	}
	return rtt, newest
}

func (p *packetPacer) observeRecoveryRTT(now time.Time, rtt time.Duration, measured time.Time, fps int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.recoveryFPS = max(1, fps)
	if rtt > 0 && rtt <= 10*time.Second && !measured.After(now) && now.Sub(measured) <= 2*time.Second && measured.After(p.recoveryMeasured) {
		p.recoveryRTT, p.recoveryMeasured = rtt, measured
	}
}

// Packet retransmission must remain short-lived. A reference ACK instead waits
// for actual decoder output, including the receiver's measured playout delay.
// Keep this separate from packet history and retain the native 250 ms cap.
func (p *packetPacer) observeRecoveryDecoder(measured time.Time, decodeMS, jitterMS float64) {
	if !finiteBound(decodeMS, 10000) || !finiteBound(jitterMS, 10000) || decodeMS < 0 || jitterMS < 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if measured.After(p.recoveryDecodedAt) {
		p.recoveryDecode = time.Duration(decodeMS * float64(time.Millisecond))
		p.recoveryJitter = time.Duration(jitterMS * float64(time.Millisecond))
		p.recoveryDecodedAt = measured
	}
}

func (p *packetPacer) referenceRecoveryDeadline(now time.Time) time.Duration {
	window, _ := p.RecoveryDeadline()
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.recoveryDecodedAt.IsZero() && !now.Before(p.recoveryDecodedAt) && now.Sub(p.recoveryDecodedAt) < 2*time.Second {
		window += p.recoveryDecode + p.recoveryJitter
	}
	return min(250*time.Millisecond, window)
}
