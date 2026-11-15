//go:build !(darwin || linux || freebsd || openbsd || netbsd)

package cli

import (
	"context"
	"errors"
	"os"
)

func isTerminal(*os.File) bool { return false }

func readHidden(*os.File) (string, error) {
	return "", errors.New("hidden prompts are unavailable on this platform")
}

func readHiddenContext(context.Context, *os.File) (string, error) {
	return readHidden(nil)
}
