package filetransfer

import (
	"fmt"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func changeTime(st *syscall.Stat_t) int64 { return st.Ctimespec.Sec*1e9 + st.Ctimespec.Nsec }

// APFS looks names up independent of Unicode normalization, so an NFC path
// reaches a file whose stored name is NFD.
const normalizationInsensitive = true

// quarantine marks a file received from another device the way browsers and
// AirDrop do, so Gatekeeper checks it before it runs.
func quarantine(fd int) error {
	value := fmt.Sprintf("0081;%x;Dieter;", time.Now().Unix())
	return unix.Fsetxattr(fd, "com.apple.quarantine", []byte(value), 0)
}
