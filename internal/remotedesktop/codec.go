package remotedesktop

import (
	"errors"
	"strconv"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/sdp/v3"
)

const hevcFMTP = "profile-id=1;tier-flag=0;level-id=153;tx-mode=SRST"

// The first HEVC operating envelope is deliberately limited until wider modes
// have passed hardware/quality benchmarks. Codec changes require a new peer.
func hevcModeSupported(c *dieterv1.RemoteDesktopStreamConfiguration) bool {
	return c.MaxWidth <= 1920 && c.MaxHeight <= 1080 && c.MaxFps <= 60 && c.MaxBitrateKbps <= 40000
}

func hevcOffered(raw string) bool {
	var description sdp.SessionDescription
	if description.Unmarshal([]byte(raw)) != nil {
		return false
	}
	for _, media := range description.MediaDescriptions {
		if media.MediaName.Media != "video" || media.MediaName.Port.Value == 0 {
			continue
		}
		formats := make(map[string]bool)
		for _, f := range media.MediaName.Formats {
			formats[f] = true
		}
		for _, a := range media.Attributes {
			fields := strings.Fields(a.Value)
			if a.Key != "rtpmap" || len(fields) != 2 || !formats[fields[0]] || !strings.EqualFold(fields[1], "H265/90000") {
				continue
			}
			params := make(map[string]string)
			invalid := false
			for _, f := range media.Attributes {
				if f.Key != "fmtp" {
					continue
				}
				payload, values, ok := strings.Cut(f.Value, " ")
				if !ok || payload != fields[0] {
					continue
				}
				for _, entry := range strings.Split(values, ";") {
					k, v, ok := strings.Cut(strings.TrimSpace(entry), "=")
					if ok {
						key := strings.ToLower(strings.TrimSpace(k))
						if _, duplicate := params[key]; duplicate {
							invalid = true
						}
						params[key] = strings.TrimSpace(v)
					} else if strings.TrimSpace(entry) != "" {
						invalid = true
					}
				}
			}
			level, err := strconv.Atoi(params["level-id"])
			if invalid || err != nil || !(level == 153 || level == 156 || level == 180 || level == 183 || level == 186) {
				continue
			}
			if p := params["profile-id"]; p != "" && p != "1" {
				continue
			}
			if p := params["tier-flag"]; p != "" && p != "0" {
				continue
			}
			if p := params["tx-mode"]; p != "" && p != "SRST" {
				continue
			}
			if p := params["sprop-max-don-diff"]; p != "" && p != "0" {
				continue
			}
			return true
		}
	}
	return false
}

func selectVideoCodec(preference dieterv1.RemoteDesktopCodecPreference, offer string, config *dieterv1.RemoteDesktopStreamConfiguration, caps *dieterv1.RemoteDesktopCapabilities, source SourceOptions) (VideoCodec, error) {
	if preference < 0 || preference > dieterv1.RemoteDesktopCodecPreference_REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC {
		return "", errors.New("invalid codec preference")
	}
	baseline := preferredVideoCodec(source)
	if preference == dieterv1.RemoteDesktopCodecPreference_REMOTE_DESKTOP_CODEC_PREFERENCE_H264 {
		if baseline != VideoCodecH264 {
			return "", errors.New("H.264 is unavailable for this source")
		}
		return baseline, nil
	}
	available := false
	for _, mode := range caps.GetCodecModes() {
		if mode != nil && mode.Codec == "H265" && mode.Profile == "main" && mode.MaxWidth >= config.MaxWidth && mode.MaxHeight >= config.MaxHeight && mode.MaxFps >= config.MaxFps {
			available = true
		}
	}
	if available && hevcModeSupported(config) && hevcOffered(offer) {
		return VideoCodecH265, nil
	}
	if preference == dieterv1.RemoteDesktopCodecPreference_REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC {
		return "", errors.New("HEVC requires hardware support, a compatible H265 Main offer, and at most 1920x1080/60 fps/40000 kbps")
	}
	return baseline, nil
}

// Only a native codec initialization error allows an automatic downgrade. EOF
// and process-exit wrappers alone must retain ordinary transport recovery.
func hevcEncoderUnavailable(err error) bool {
	if err == nil {
		return false
	}
	reason := err.Error()
	for _, prefix := range []string{"native capture helper stopped: ", "EOF: ", "unexpected EOF: "} {
		reason = strings.TrimPrefix(reason, prefix)
	}
	return strings.HasPrefix(reason, "HEVC encoder unavailable:")
}
