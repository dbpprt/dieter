package filetransfer

import "syscall"

func changeTime(st *syscall.Stat_t) int64 { return st.Ctim.Sec*1e9 + st.Ctim.Nsec }

// Linux file systems store names byte for byte: an NFC path does not reach
// a file whose name is NFD.
const normalizationInsensitive = false

// quarantine is a macOS concept.
func quarantine(int) error { return nil }
