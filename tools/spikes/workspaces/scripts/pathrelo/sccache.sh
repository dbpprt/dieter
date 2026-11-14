#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/rs
SC=/Volumes/External/dieter-spike/pathrelo/dl/sccache/sccache-v0.18.0-aarch64-apple-darwin/sccache
export SCCACHE_LOG=debug SCCACHE_ERROR_LOG=$R/sc-$$.log CARGO_HOME=$R/cargohome CARGO_TERM_COLOR=never CARGO_INCREMENTAL=0 RUSTC_WRAPPER=$SC SCCACHE_SERVER_PORT=48226 SCCACHE_DIR=$R/sccache-store SCCACHE_IDLE_TIMEOUT=0
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
for mode in nobase base; do
    $SC --stop-server >/dev/null 2>&1
    rm -rf $SCCACHE_DIR $R/sc-src-$mode $R/sc-view-$mode
    if [ $mode = base ]; then export SCCACHE_BASEDIRS=$R; else unset SCCACHE_BASEDIRS; fi
    $SC --start-server >/dev/null 2>&1
    /bin/cp -c -R $R/src $R/sc-src-$mode
    rm -rf $R/sc-src-$mode/target
    cd $R/sc-src-$mode
    t0=$(now)
    cargo build -q 2>/dev/null
    t1=$(now)
    $SC -z >/dev/null
    echo ---- VIEW >>$R/sc-$$.log
    /bin/cp -c -R $R/sc-src-$mode $R/sc-view-$mode
    rm -rf $R/sc-view-$mode/target
    cd $R/sc-view-$mode
    t2=$(now)
    cargo build -q 2>/dev/null
    t3=$(now)
    echo "sccache $mode: source cold $(el $t0 $t1)s; view fresh target dir $(el $t2 $t3)s; $($SC -s | grep -E '^Cache (hits|misses) +[0-9]|Non-cacheable calls|^Cache hits \(Rust\)|^Cache misses \(Rust\)' | tr -s ' ' | tr '\n' ';')"
done
$SC --stop-server >/dev/null 2>&1
