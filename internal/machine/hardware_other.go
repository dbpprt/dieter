//go:build !darwin

package machine

func hardwareDetails(processor string) (string, string) {
	return "", processor
}
