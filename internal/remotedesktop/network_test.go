package remotedesktop

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/logging"
	"github.com/pion/transport/v4/vnet"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

// This exercises actual TWCC packets, GCC and the production pacer over an
// isolated network. It does not change the operator's interfaces or routes.
func TestCongestionFeedbackOnLossyMediaKeepsControlResponsive(t *testing.T) {
	router, err := vnet.NewRouter(&vnet.RouterConfig{CIDR: "10.10.0.0/24", QueueSize: 256, MinDelay: 15 * time.Millisecond, MaxJitter: 3 * time.Millisecond, LoggerFactory: logging.NewDefaultLoggerFactory()})
	if err != nil {
		t.Fatal(err)
	}
	var bandwidth atomic.Int64
	bandwidth.Store(20_000_000)
	var dropped atomic.Int64
	tokens := 250000.0
	updated := time.Now()
	router.AddChunkFilter(func(chunk vnet.Chunk) bool {
		raw := chunk.UserData()
		if !strings.HasPrefix(chunk.SourceAddr().String(), "10.10.0.1:") || len(raw) < 100 || raw[0]&0xc0 != 0x80 {
			return true
		}
		now := time.Now()
		rate := float64(bandwidth.Load()) / 8
		tokens = min(rate*.1, tokens+now.Sub(updated).Seconds()*rate)
		updated = now
		if tokens < float64(len(raw)) {
			dropped.Add(1)
			return false
		}
		tokens -= float64(len(raw))
		return true
	})
	settings := func(ip string) webrtc.SettingEngine {
		network, e := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{ip}})
		if e != nil {
			t.Fatal(e)
		}
		if e = router.AddNet(network); e != nil {
			t.Fatal(e)
		}
		value := webrtc.SettingEngine{}
		value.SetNet(network)
		value.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
		value.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
		return value
	}
	senderSettings, receiverSettings := settings("10.10.0.1"), settings("10.10.0.2")
	if err = router.Start(); err != nil {
		t.Fatal(err)
	}
	defer router.Stop()
	source, _ := NewFrameSource(SourceOptions{Kind: "synthetic"})
	api, pacer, estimator, err := newMediaAPI(senderSettings, source)
	if err != nil {
		t.Fatal(err)
	}
	defer pacer.Close()
	sender, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	receiver, err := webrtc.NewAPI(webrtc.WithSettingEngine(receiverSettings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.Close()
	receiver.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		for {
			if _, _, err := track.ReadRTP(); err != nil {
				return
			}
		}
	})
	receiver.OnDataChannel(func(channel *webrtc.DataChannel) {
		channel.OnMessage(func(message webrtc.DataChannelMessage) { _ = channel.Send(message.Data) })
	})
	channel, err := sender.CreateDataChannel("control-test", nil)
	if err != nil {
		t.Fatal(err)
	}
	echoed := make(chan struct{}, 1)
	channel.OnMessage(func(webrtc.DataChannelMessage) {
		select {
		case echoed <- struct{}{}:
		default:
		}
	})
	track, err := webrtc.NewTrackLocalStaticSample(codecCapability(VideoCodecVP8), "video", "test")
	if err != nil {
		t.Fatal(err)
	}
	rtpSender, err := sender.AddTrack(track)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			if _, _, err := rtpSender.ReadRTCP(); err != nil {
				return
			}
		}
	}()
	offer, err := sender.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered := webrtc.GatheringCompletePromise(sender)
	if err = sender.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	if err = receiver.SetRemoteDescription(*sender.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	answer, err := receiver.CreateAnswer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gathered = webrtc.GatheringCompletePromise(receiver)
	if err = receiver.SetLocalDescription(answer); err != nil {
		t.Fatal(err)
	}
	<-gathered
	if err = sender.SetRemoteDescription(*receiver.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(8 * time.Second)
	for channel.ReadyState() != webrtc.DataChannelStateOpen && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if channel.ReadyState() != webrtc.DataChannelStateOpen {
		t.Fatal("virtual peer connection did not open")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		payload := make([]byte, 20000)
		payload[0] = 0x10
		for ctx.Err() == nil {
			pacer.BeginFrame(time.Now())
			if track.WriteSample(media.Sample{Data: payload, Duration: time.Second / 60}) != nil {
				return
			}
			pacer.EndFrame(time.Now())
		}
	}()
	go func() {
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				pacer.mu.Lock()
				health := pacer.transport
				pacer.mu.Unlock()
				pacer.ObserveNetwork(now, health.fresh(now) && !health.congested())
			}
		}
	}()
	time.Sleep(500 * time.Millisecond)
	initial := (*estimator).GetTargetBitrate()
	bandwidth.Store(800000)
	deadline = time.Now().Add(10 * time.Second)
	for ((*estimator).GetTargetBitrate() > 1_200_000 || pacer.TargetBitrate() > 1_200_000) && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	constrained := (*estimator).GetTargetBitrate()
	if dropped.Load() == 0 || constrained > 1_200_000 || pacer.TargetBitrate() > 1_200_000 {
		t.Fatalf("TWCC/GCC did not respond: initial=%d constrained=%d drops=%d", initial, constrained, dropped.Load())
	}
	start := time.Now()
	if err = channel.Send([]byte("key-up")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-echoed:
		t.Logf("GCC %d -> %d bps; drops=%d; control RTT=%s", initial, constrained, dropped.Load(), time.Since(start))
	case <-time.After(time.Second):
		t.Fatal("congested media blocked reliable control")
	}
	bandwidth.Store(20_000_000)
	deadline = time.Now().Add(25 * time.Second)
	for pacer.TargetBitrate() < 3_000_000 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if rate := pacer.TargetBitrate(); rate < 3_000_000 {
		t.Fatalf("media did not recover without reconnect: %d", rate)
	}
	t.Logf("same peer recovered to %d bps after capacity returned", pacer.TargetBitrate())
	cancel()
	pacer.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("paced producer did not cancel")
	}
}
