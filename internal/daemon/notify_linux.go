//go:build linux

package daemon

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// notifyServiceReady sends sd_notify READY=1 to a systemd user service
// manager through socket (NOTIFY_SOCKET).
func notifyServiceReady(manager, socket string) error {
	if manager != "systemd-user" {
		return nil
	}
	socket = strings.TrimSpace(socket)
	if socket == "" {
		return errors.New("systemd service did not provide NOTIFY_SOCKET")
	}
	if strings.HasPrefix(socket, "@") {
		socket = "\x00" + strings.TrimPrefix(socket, "@")
	}
	connection, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: socket, Net: "unixgram"})
	if err != nil {
		return fmt.Errorf("connect systemd notification socket: %w", err)
	}
	defer connection.Close()
	if err := connection.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return err
	}
	_, err = connection.Write([]byte("READY=1\nSTATUS=Dieter daemon is ready\nMAINPID=" + strconv.Itoa(os.Getpid())))
	return err
}
