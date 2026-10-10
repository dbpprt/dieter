//go:build !(darwin || linux || freebsd || openbsd || netbsd)

package cli

import (
	"errors"
	"os"
)

func isTerminal(*os.File) bool { return false }

func readHidden(*os.File) (string, error) {
	return "", errors.New("hidden prompts are unavailable on this platform")
}
