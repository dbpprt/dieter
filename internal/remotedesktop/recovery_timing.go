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
