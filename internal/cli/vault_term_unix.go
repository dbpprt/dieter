//go:build darwin || linux || freebsd || openbsd || netbsd

package cli

import (
	"bufio"
	"os"

	"golang.org/x/sys/unix"
)

func isTerminal(file *os.File) bool {
	_, err := unix.IoctlGetTermios(int(file.Fd()), ioctlGetTermios)
	return err == nil
}

// readHidden reads one line with terminal echo disabled and restores the
// previous mode even when reading fails.
func readHidden(file *os.File) (string, error) {
	fd := int(file.Fd())
	previous, err := unix.IoctlGetTermios(fd, ioctlGetTermios)
	if err != nil {
		return "", err
	}
	hidden := *previous
	hidden.Lflag &^= unix.ECHO
	hidden.Lflag |= unix.ICANON | unix.ISIG
	if err = unix.IoctlSetTermios(fd, ioctlSetTermios, &hidden); err != nil {
		return "", err
	}
	defer unix.IoctlSetTermios(fd, ioctlSetTermios, previous)
	return bufio.NewReader(file).ReadString('\n')
}
