//go:build !darwin && !linux

package machine

func hardwareDetails(processor string) (string, string) {
	return "", processor
}
