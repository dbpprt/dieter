//go:build linux

package machine

import (
	"os"
	"strings"
)

func hardwareDetails(processor string) (string, string) {
	vendor := readDMIValue("/sys/class/dmi/id/sys_vendor")
	product := readDMIValue("/sys/class/dmi/id/product_name")
	model := strings.TrimSpace(strings.Join([]string{vendor, product}, " "))
	if model == "" {
		model = readDMIValue("/sys/firmware/devicetree/base/model")
	}
	return model, processor
}

func readDMIValue(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.Trim(strings.TrimSpace(string(raw)), "\x00")
}
