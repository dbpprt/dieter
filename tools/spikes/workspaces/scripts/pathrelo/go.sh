#!/bin/bash
# go.sh MODE(plain|trim)  - cold GOCACHE, build in source, clone, rebuild in clone
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/go
MODE=$1
export GOCACHE=$R/cache-$MODE GOFLAGS=
rm -rf $GOCACHE $R/src-$MODE $R/view-$MODE
/bin/cp -c -R $R/src $R/src-$MODE
FL=""
[ $MODE = trim ] && FL=-trimpath
cd $R/src-$MODE
t0=$(python3 -c 'import time;print(time.time())')
go build $FL -v -o bin/dieter ./cmd/dieter 2>$R/$MODE-src.log
t1=$(python3 -c 'import time;print(time.time())')
go test $FL ./internal/platform/... ./internal/prompt/... >$R/$MODE-src-test.log 2>&1
echo "$MODE source cold build: $(wc -l <$R/$MODE-src.log) pkgs, $(python3 -c "print(round($t1-$t0,1))")s"
t0=$(python3 -c 'import time;print(time.time())')
/bin/cp -c -R $R/src-$MODE $R/view-$MODE
t1=$(python3 -c 'import time;print(time.time())')
echo "clone: $(python3 -c "print(round($t1-$t0,2))")s"
cd $R/view-$MODE
t0=$(python3 -c 'import time;print(time.time())')
go build $FL -v -o bin/dieter ./cmd/dieter 2>$R/$MODE-view.log
t1=$(python3 -c 'import time;print(time.time())')
echo "$MODE view build: $(wc -l <$R/$MODE-view.log) pkgs rebuilt ($(grep -c dbpprt $R/$MODE-view.log) module pkgs), $(python3 -c "print(round($t1-$t0,1))")s"
go test $FL ./internal/platform/... ./internal/prompt/... >$R/$MODE-view-test.log 2>&1
echo "$MODE view go test: $(grep -c '(cached)' $R/$MODE-view-test.log) cached / $(grep -c '^ok' $R/$MODE-view-test.log) ok"
go vet $FL ./internal/platform/... >/dev/null 2>&1
echo "vet rc=$?"
# correctness: edit a module file in the view, ensure the view's change is picked up
f=internal/cli/zz_relo.go
printf 'package cli\n\nvar ReloMarker = "view-edit"\n' >$f
go build $FL -v -o bin/dieter ./cmd/dieter 2>$R/$MODE-view2.log
echo "$MODE after edit: $(wc -l <$R/$MODE-view2.log) pkgs rebuilt: $(tr '\n' ' ' <$R/$MODE-view2.log)"
strings bin/dieter | grep -o "/Volumes/External/dieter-spike/pathrelo/go/[a-z-]*" | sort | uniq -c | head -3 | sed 's/^/  abs paths in binary: /'
du -sh $GOCACHE | sed 's/^/  cache: /'
