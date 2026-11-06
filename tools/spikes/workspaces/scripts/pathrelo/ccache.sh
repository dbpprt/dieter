#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/cm
CC_BIN=/Volumes/External/dieter-spike/pathrelo/dl/ccache/ccache-4.14.2-darwin/ccache
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
export CCACHE_DIR=$R/ccache-store CCACHE_CONFIGPATH=/dev/null
for mode in nobase base; do
    rm -rf $CCACHE_DIR $R/cc-src-$mode $R/cc-view-$mode
    if [ $mode = base ]; then export CCACHE_BASEDIR=$R CCACHE_NOHASHDIR=1; else unset CCACHE_BASEDIR CCACHE_NOHASHDIR; fi
    /bin/cp -c -R $R/src $R/cc-src-$mode
    rm -rf $R/cc-src-$mode/build $R/cc-src-$mode/build2
    cd $R/cc-src-$mode
    t0=$(now)
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_COMPILER_LAUNCHER=$CC_BIN >/dev/null
    cmake --build build -j8 >/dev/null
    t1=$(now)
    $CC_BIN -z >/dev/null
    /bin/cp -c -R $R/cc-src-$mode $R/cc-view-$mode
    rm -rf $R/cc-view-$mode/build
    cd $R/cc-view-$mode
    t2=$(now)
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_COMPILER_LAUNCHER=$CC_BIN >/dev/null
    t3=$(now)
    cmake --build build -j8 >/dev/null
    t4=$(now)
    echo "ccache $mode: source cold configure+build $(el $t0 $t1)s; view fresh build dir: configure $(el $t2 $t3)s + build $(el $t3 $t4)s; $($CC_BIN -s | grep -E 'Hits|Misses' | tr -s ' ' | tr '\n' ';')"
    echo "  debug info path in view object: $(strings -a build/CMakeFiles/relolib.dir/lib/f1.c.o | grep -m1 -o '/Volumes[^ ]*cm/[a-z-]*' || echo none-absolute)"
done
