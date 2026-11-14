package filetransfer

import "syscall"

func changeTime(st *syscall.Stat_t) int64 { return st.Ctim.Sec*1e9 + st.Ctim.Nsec }
