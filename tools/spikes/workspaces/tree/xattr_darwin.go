package tree

import "golang.org/x/sys/unix"

// errNoAttr is the errno getxattr returns for a missing attribute.
const errNoAttr = unix.ENOATTR

// racySlackNs widens the racy-entry window below a manifest's CreatedAt.
// APFS stamps files with the same nanosecond realtime clock as time.Now, so
// a small margin only absorbs clock reads that straddle a write.
const racySlackNs = int64(2_000_000)
