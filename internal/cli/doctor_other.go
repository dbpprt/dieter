//go:build !linux

package cli

func platformDoctorChecks() []doctorCheck { return nil }
