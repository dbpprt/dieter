#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/swift
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
rm -rf $R/spm-src $R/spm-view
mkdir -p $R
/Volumes/External/dieter-spike/pathrelo/scripts/mkswift.sh $R/spm-src >/dev/null
cd $R/spm-src
t0=$(now)
swift build >../spm-src.log 2>&1
t1=$(now)
echo "SwiftPM source cold build: $(el $t0 $t1)s, $(grep -c 'Compiling' ../spm-src.log) compile lines"
sleep 1
/bin/cp -c -R $R/spm-src $R/spm-view
cd $R/spm-view
t0=$(now)
swift build >../spm-view.log 2>&1
t1=$(now)
echo "SwiftPM view build: $(el $t0 $t1)s, $(grep -c 'Compiling' ../spm-view.log) compile lines; $(tail -1 ../spm-view.log)"
sed -i '' 's/where=source/where=view/' Sources/ReloApp/main.swift
sed -i '' 's/a \&\* 3/a \&* 33/' Sources/LibA/F3.swift
t0=$(now)
swift build >../spm-view2.log 2>&1
t1=$(now)
echo "SwiftPM view after editing LibA/F3 + main: $(el $t0 $t1)s, $(grep -c 'Compiling' ../spm-view2.log) compile lines; runs: $(.build/debug/ReloApp)"
echo "  source still prints: $($R/spm-src/.build/debug/ReloApp)"
echo "  files in view .build naming the source path: $(rg -l -F --no-ignore --hidden -uuu "$R/spm-src" .build | wc -l) of $(find .build -type f | wc -l)"
