#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/cm
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
rm -rf $R
mkdir -p $R/src/lib
cd $R/src
N=60
for i in $(seq 1 $N); do printf '#include "common.h"\nint f%d(int x){ int s=0; for(int i=0;i<x;i++) s+=i*%d; return s; }\n' $i $i >lib/f$i.c; done
{
    echo '#pragma once'
    for i in $(seq 1 $N); do echo "int f$i(int);"; done
} >lib/common.h
{
    echo '#include <stdio.h>'
    echo '#include "common.h"'
    echo 'int main(void){ printf("source\\n"); return 0; }'
} >main.c
cat >CMakeLists.txt <<C
cmake_minimum_required(VERSION 3.20)
project(relo C)
file(GLOB LIBSRC lib/*.c)
add_library(relolib STATIC \${LIBSRC})
target_include_directories(relolib PUBLIC lib)
add_executable(relo main.c)
target_link_libraries(relo relolib)
C
git init -q
printf 'build/\n' >.gitignore
git add -A
git -c user.name=x -c user.email=x@x commit -qm b
t0=$(now)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug >/dev/null
t1=$(now)
cmake --build build -j8 >/dev/null
t2=$(now)
echo "source: configure $(el $t0 $t1)s, build $(el $t1 $t2)s"
sleep 1
# A: clone, edit, cmake --build in the view
/bin/cp -c -R $R/src $R/viewA
cd $R/viewA
srcbin_before=$(stat -f %m $R/src/build/relo)
sed -i '' 's/"source/"viewA/' main.c
cmake --build build >../A.log 2>&1
rc=$?
echo "A in-tree build dir in clone: rc=$rc; view binary prints: $(./build/relo); source binary prints: $($R/src/build/relo); source build/relo mtime changed: $([ $(stat -f %m $R/src/build/relo) != $srcbin_before ] && echo YES || echo no)"
grep -m2 -i 'differ\|Error' ../A.log | sed 's/^/   /'
grep -c '/src/' build/CMakeCache.txt | sed 's/^/   CMakeCache lines naming source path: /'
# B: fresh build dir in the view
cd $R/viewA
t0=$(now)
cmake -S . -B build2 -DCMAKE_BUILD_TYPE=Debug >/dev/null
t1=$(now)
cmake --build build2 -j8 >/dev/null
t2=$(now)
echo "B fresh build dir in view: configure $(el $t0 $t1)s, build $(el $t1 $t2)s, prints $(./build2/relo)"
# C: prefix rewrite of the cloned build dir (same idea as conda's prefix replacement)
/bin/cp -c -R $R/src $R/viewC
cd $R/viewC
t0=$(now)
n=0
for f in $(rg -l -F --no-ignore --hidden "$R/src" build); do
    perl -pi -e "s#\Q$R/src\E#$R/viewC#g" "$f"
    touch -r "$R/src/$f" "$f"
    n=$((n + 1))
done
t1=$(now)
echo "C rewrite: $n files in $(el $t0 $t1)s"
cmake --build build >../C0.log 2>&1
echo "C build after rewrite, no edit: rc=$? compiled=$(grep -c 'Building C object' ../C0.log) relinked=$(grep -c 'Linking' ../C0.log) reconfigured=$(grep -c 'Configuring done\|Re-run' ../C0.log)"
sed -i '' 's/"source/"viewC/' main.c
sed -i '' 's/i\*7;/i*77;/' lib/f7.c
cmake --build build >../C1.log 2>&1
echo "C after editing 2 files: rc=$? compiled=$(grep -c 'Building C object' ../C1.log); view prints: $(./build/relo); source prints: $($R/src/build/relo)"
