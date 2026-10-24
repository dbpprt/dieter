#!/bin/bash
# xc.sh MODE : plain (clone DD along) | cache-noprefix | cache-prefix (fresh DD in view, shared CAS)
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/swift
MODE=$1
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
S=$R/xcs-$MODE/Relo V=$R/xcv-$MODE/Relo CAS=$R/cas2-$MODE
mkdir -p $R/xcs-$MODE $R/xcv-$MODE
rm -rf $S $V $CAS
/Volumes/External/dieter-spike/pathrelo/scripts/mkswift.sh $S >/dev/null
SET=(ONLY_ACTIVE_ARCH=YES)
case $MODE in
    cache-noprefix) SET=(ONLY_ACTIVE_ARCH=YES COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$CAS COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES) ;;
    cache-prefix) SET=(ONLY_ACTIVE_ARCH=YES COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$CAS COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES SWIFT_ENABLE_PREFIX_MAPPING=YES SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES) ;;
    cache-prefix-root) SET=(ONLY_ACTIVE_ARCH=YES COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH=$CAS COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES SWIFT_ENABLE_PREFIX_MAPPING=YES SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES CLANG_ENABLE_PREFIX_MAPPING=YES CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES) ;;
esac
xb() {
    EXTRA=()
    [ $MODE = cache-prefix-root ] && EXTRA=("SWIFT_OTHER_PREFIX_MAPPINGS=$PWD=/^view" "CLANG_OTHER_PREFIX_MAPPINGS=$PWD=/^view")
    xcodebuild -scheme Relo -destination 'platform=macOS' -derivedDataPath DD "${SET[@]}" ${EXTRA[@]+"${EXTRA[@]}"} build 2>&1
}
cd $S
t0=$(now)
xb >$R/xc2-$MODE-src.log
rc=$?
t1=$(now)
echo "$MODE source cold: rc=$rc $(el $t0 $t1)s; SwiftCompile=$(grep -c '^SwiftCompile' $R/xc2-$MODE-src.log) hits=$(grep -c "replay cache hit" $R/xc2-$MODE-src.log) misses=$(grep -c "Replay cache miss" $R/xc2-$MODE-src.log)"
sleep 1
/bin/cp -c -R $S $V
cd $V
[ $MODE != plain ] && rm -rf DD
t0=$(now)
xb >$R/xc2-$MODE-view.log
rc=$?
t1=$(now)
echo "$MODE view build: rc=$rc $(el $t0 $t1)s; SwiftCompile=$(grep -c '^SwiftCompile' $R/xc2-$MODE-view.log) hits=$(grep -c "replay cache hit" $R/xc2-$MODE-view.log) misses=$(grep -c "Replay cache miss" $R/xc2-$MODE-view.log)"
sed -i '' 's/where=source/where=view/' Sources/ReloApp/main.swift
xb >$R/xc2-$MODE-view2.log
echo "  after edit: rc=$? SwiftCompile=$(grep -c '^SwiftCompile' $R/xc2-$MODE-view2.log); runs: $(DD/Build/Products/Debug/ReloApp)"
echo "  debug-info source path in view LibA F1.o: $(strings -a $(find DD -name F1.o -path '*LibA*' | head -1) | grep -m1 -o '/Volumes[^ ]*swift/xc-[a-z-]*\|/\^src')"
