#!/bin/sh
# start-run.sh LIVE_ROOT RUN: start card A, then card B 3 s later.
set -eu
ROOT=${1:?LIVE_ROOT}
RUN=${2:?RUN}
HERE=$(cd "$(dirname "$0")" && pwd)
export LIVE_ROOT=$ROOT
. "$ROOT/$RUN/ids.env"
date -u +"start A %Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u
"$HERE/dl.sh" card start "$A" >/dev/null
sleep 3
date -u
"$HERE/dl.sh" card start "$B" >/dev/null
echo started
