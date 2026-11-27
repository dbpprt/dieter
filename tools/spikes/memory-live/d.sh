#!/bin/sh
# d.sh NAME ARGS...: the working-tree CLI against the isolated daemon NAME only.
for v in $(env | grep -o '^DIETER_[A-Z_]*'); do unset "$v"; done
NAME=$1
shift
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
export DIETER_HOME=/tmp/dieter-mem-live/$NAME
exec "$REPO/bin/dieter" "$@"
