//go:build !linux

package cli

import "github.com/dbpprt/dieter/internal/platform/config"

func platformDoctorChecks(config.Client) []doctorCheck { return nil }
