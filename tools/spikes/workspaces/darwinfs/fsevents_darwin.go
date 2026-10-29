//go:build darwin

package darwinfs

/*
#cgo LDFLAGS: -framework CoreServices -framework CoreFoundation
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	pthread_mutex_t mu;
	char **paths;
	uint32_t *flags;
	uint64_t *ids;
	size_t n, cap;
	int history_done;
	uint64_t max_id;
	FSEventStreamRef stream;
	dispatch_queue_t queue;
} dfs_sess;

static void dfs_cb(ConstFSEventStreamRef s, void *info, size_t num, void *eventPaths,
		const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
	dfs_sess *c = info;
	char **p = eventPaths;
	pthread_mutex_lock(&c->mu);
	for (size_t i = 0; i < num; i++) {
		if (c->n == c->cap) {
			size_t nc = c->cap ? c->cap * 2 : 1024;
			char **np = realloc(c->paths, nc * sizeof(char *));
			uint32_t *nf = realloc(c->flags, nc * sizeof(uint32_t));
			uint64_t *ni = realloc(c->ids, nc * sizeof(uint64_t));
			if (np) c->paths = np;
			if (nf) c->flags = nf;
			if (ni) c->ids = ni;
			if (!np || !nf || !ni) break;
			c->cap = nc;
		}
		c->paths[c->n] = strdup(p[i] ? p[i] : "");
		c->flags[c->n] = flags[i];
		c->ids[c->n] = ids[i];
		c->n++;
		if (flags[i] & kFSEventStreamEventFlagHistoryDone) c->history_done = 1;
		if (ids[i] > c->max_id) c->max_id = ids[i];
	}
	pthread_mutex_unlock(&c->mu);
}

static dfs_sess *dfs_start(char **paths, int npaths, uint64_t since, double latency, uint32_t cflags) {
	dfs_sess *c = calloc(1, sizeof(dfs_sess));
	if (!c) return NULL;
	pthread_mutex_init(&c->mu, NULL);
	CFMutableArrayRef arr = CFArrayCreateMutable(NULL, npaths, &kCFTypeArrayCallBacks);
	for (int i = 0; i < npaths; i++) {
		CFStringRef s = CFStringCreateWithFileSystemRepresentation(NULL, paths[i]);
		if (s) {
			CFArrayAppendValue(arr, s);
			CFRelease(s);
		}
	}
	FSEventStreamContext ctx = {0, c, NULL, NULL, NULL};
	c->stream = FSEventStreamCreate(NULL, dfs_cb, &ctx, arr, since, latency, cflags);
	CFRelease(arr);
	if (!c->stream) {
		pthread_mutex_destroy(&c->mu);
		free(c);
		return NULL;
	}
	c->queue = dispatch_queue_create("dieter.spike.darwinfs.fsevents", DISPATCH_QUEUE_SERIAL);
	FSEventStreamSetDispatchQueue(c->stream, c->queue);
	if (!FSEventStreamStart(c->stream)) {
		FSEventStreamInvalidate(c->stream);
		FSEventStreamRelease(c->stream);
		dispatch_release(c->queue);
		pthread_mutex_destroy(&c->mu);
		free(c);
		return NULL;
	}
	return c;
}

static void dfs_flush(dfs_sess *c) { FSEventStreamFlushSync(c->stream); }

static void dfs_status(dfs_sess *c, int *hd, uint64_t *max_id, size_t *n) {
	pthread_mutex_lock(&c->mu);
	*hd = c->history_done;
	*max_id = c->max_id;
	*n = c->n;
	pthread_mutex_unlock(&c->mu);
}

static void dfs_noop(void *ctx) { (void)ctx; }

// dfs_stop tears the stream down; after it returns no callback runs.
static void dfs_stop(dfs_sess *c) {
	FSEventStreamStop(c->stream);
	FSEventStreamInvalidate(c->stream);
	dispatch_sync_f(c->queue, NULL, dfs_noop);
	FSEventStreamRelease(c->stream);
	dispatch_release(c->queue);
	c->stream = NULL;
	c->queue = NULL;
}

static size_t dfs_count(dfs_sess *c) { return c->n; }
static const char *dfs_path(dfs_sess *c, size_t i) { return c->paths[i]; }
static uint32_t dfs_flag(dfs_sess *c, size_t i) { return c->flags[i]; }
static uint64_t dfs_id(dfs_sess *c, size_t i) { return c->ids[i]; }

static void dfs_free(dfs_sess *c) {
	for (size_t i = 0; i < c->n; i++) free(c->paths[i]);
	free(c->paths);
	free(c->flags);
	free(c->ids);
	pthread_mutex_destroy(&c->mu);
	free(c);
}

static uint64_t dfs_current(void) { return FSEventsGetCurrentEventId(); }
*/
import "C"

import (
	"errors"
	"fmt"
	"path/filepath"
	"time"
	"unsafe"
)

const (
	createFlagNoDefer    = 0x00000002
	createFlagFileEvents = 0x00000010
	eventsLatency        = 0.05
	sinceNow             = ^uint64(0)
)

// ErrTimeout is wrapped by EventsSince when the deadline passes before the
// history replay finished.
var ErrTimeout = errors.New("fsevents: timed out before history replay finished")

// CurrentEventID returns FSEventsGetCurrentEventId(): the most recent event
// id the system has assigned.
func CurrentEventID() uint64 { return uint64(C.dfs_current()) }

// EventsSince replays the FSEvents history for paths after the event id
// since and returns every event up to the moment of the call. It waits for
// the HistoryDone sentinel, then flushes the stream (FSEventStreamFlushSync)
// until an event at or after the id current at call time arrives or a flush
// one latency period later brings nothing new; events still in flight to
// fseventsd at call time arrive as live events after the sentinel. The
// HistoryDone sentinel itself is included. Event flags are cumulative per
// path within fseventsd's history (a pwrite to an old file can carry
// Created), so callers must stat to learn the current state. On timeout the
// events seen so far are returned with an error wrapping ErrTimeout.
func EventsSince(paths []string, since uint64, timeout time.Duration) ([]FSEvent, error) {
	if len(paths) == 0 {
		return nil, errors.New("fsevents: no paths")
	}
	if since == sinceNow {
		return nil, errors.New("fsevents: since must be a recorded event id, not kFSEventStreamEventIdSinceNow")
	}
	target := CurrentEventID()
	deadline := time.Now().Add(timeout)
	cpaths := make([]*C.char, len(paths))
	for i, p := range paths {
		rp, err := realpath(p)
		if err != nil {
			return nil, err
		}
		cpaths[i] = C.CString(rp)
	}
	defer func() {
		for _, p := range cpaths {
			C.free(unsafe.Pointer(p))
		}
	}()
	cArr := (**C.char)(C.malloc(C.size_t(len(cpaths)) * C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(cArr))
	copy(unsafe.Slice(cArr, len(cpaths)), cpaths)

	sess := C.dfs_start(cArr, C.int(len(cpaths)), C.uint64_t(since), C.double(eventsLatency),
		C.uint32_t(createFlagFileEvents|createFlagNoDefer))
	if sess == nil {
		return nil, errors.New("fsevents: FSEventStreamCreate/Start failed")
	}
	defer C.dfs_free(sess)

	status := func() (bool, uint64, int) {
		var hd C.int
		var maxID C.uint64_t
		var n C.size_t
		C.dfs_status(sess, &hd, &maxID, &n)
		return hd != 0, uint64(maxID), int(n)
	}
	var waitErr error
	for {
		if hd, _, _ := status(); hd {
			break
		}
		if time.Now().After(deadline) {
			waitErr = fmt.Errorf("%w (%s)", ErrTimeout, timeout)
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if waitErr == nil {
		prev := -1
		for {
			C.dfs_flush(sess)
			_, maxID, n := status()
			if maxID >= target || n == prev || time.Now().After(deadline) {
				break
			}
			prev = n
			time.Sleep(time.Duration(eventsLatency * float64(time.Second)))
		}
	}
	C.dfs_stop(sess) // no callback runs after this, so the buffers are stable

	n := int(C.dfs_count(sess))
	out := make([]FSEvent, n)
	for i := 0; i < n; i++ {
		out[i] = FSEvent{
			Path:  C.GoString(C.dfs_path(sess, C.size_t(i))),
			Flags: uint32(C.dfs_flag(sess, C.size_t(i))),
			ID:    uint64(C.dfs_id(sess, C.size_t(i))),
		}
	}
	return out, waitErr
}

func realpath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	rp, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("fsevents: resolve %s: %w", p, err)
	}
	return rp, nil
}
