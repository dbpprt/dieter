package tree

import "golang.org/x/sys/unix"

// errNoAttr is the errno getxattr returns for a missing attribute.
const errNoAttr = unix.ENODATA

// racySlackNs widens the racy-entry window below a manifest's CreatedAt.
// Linux stamps files from the coarse (jiffy) clock, which lags time.Now by
// up to one tick (10 ms at HZ=100), so a write just after a walk started can
// carry a timestamp slightly before it.
const racySlackNs = int64(25_000_000)
