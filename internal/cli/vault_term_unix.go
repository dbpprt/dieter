//go:build darwin || linux || freebsd || openbsd || netbsd

package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
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
	return readHiddenContext(context.Background(), file)
}

// readHiddenContext is readHidden that gives up when ctx ends. It polls
// instead of blocking in read, so a prompt abandoned because the work
// finished elsewhere still restores echo before the process exits.
func readHiddenContext(ctx context.Context, file *os.File) (string, error) {
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
	defer func() { _ = unix.IoctlSetTermios(fd, ioctlSetTermios, previous) }()
	var line []byte
	buffer := make([]byte, 4096)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		ready, err := unix.Poll([]unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}, 200)
		if errors.Is(err, unix.EINTR) || err == nil && ready == 0 {
			continue
		}
		if err != nil {
			return "", err
		}
		count, err := unix.Read(fd, buffer)
		if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
			continue
		}
		if err != nil {
			return "", err
		}
		if count == 0 {
			return string(line), io.EOF
		}
		line = append(line, buffer[:count]...)
		if index := bytes.IndexByte(line, '\n'); index >= 0 {
			return string(line[:index+1]), nil
		}
		if len(line) > 64<<10 {
			return "", errors.New("input line is too long")
		}
	}
}
