//go:build darwin

package machine

import (
	"strings"

	"golang.org/x/sys/unix"
)

func hardwareDetails(processor string) (string, string) {
	identifier, _ := unix.Sysctl("hw.model")
	if value, err := unix.Sysctl("machdep.cpu.brand_string"); err == nil && strings.TrimSpace(value) != "" {
		processor = strings.TrimSpace(value)
	}
	name := friendlyMacModel(identifier)
	if name == "" {
		name = identifier
	}
	return name, processor
}

func friendlyMacModel(identifier string) string {
	if strings.HasPrefix(identifier, "MacBookAir") {
		return "MacBook Air"
	}
	if strings.HasPrefix(identifier, "MacBookPro") || strings.HasPrefix(identifier, "MacBook") {
		return "MacBook Pro"
	}
	if strings.HasPrefix(identifier, "Macmini") {
		return "Mac mini"
	}
	if strings.HasPrefix(identifier, "iMac") {
		return "iMac"
	}
	if strings.HasPrefix(identifier, "MacPro") {
		return "Mac Pro"
	}
	switch identifier {
	case "Mac13,1", "Mac13,2", "Mac14,13", "Mac14,14", "Mac15,14", "Mac16,9":
		return "Mac Studio"
	case "Mac14,3", "Mac14,12", "Mac16,10", "Mac16,11":
		return "Mac mini"
	case "Mac14,8":
		return "Mac Pro"
	case "Mac15,4", "Mac15,5", "Mac16,2", "Mac16,3":
		return "iMac"
	}
	return ""
}
