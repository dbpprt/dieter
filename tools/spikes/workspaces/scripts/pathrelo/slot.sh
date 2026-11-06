#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID GIT_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=x GIT_AUTHOR_EMAIL=x@x GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL=x@x
P=/Volumes/External/dieter-spike/pathrelo/slot
SPIKE=/Users/dbpprt/Development/dieter/tools/spikes/workspaces/spike
JS=/Volumes/External/dieter-spike/tree-dev/js
now() { python3 -c 'import time;print(time.time())'; }
T() {
    local s=$(now)
    "$@" >/dev/null 2>&1
    local rc=$?
    python3 -c "print(round($(now)-$s,3))"
    return $rc
}
rm -rf $P
mkdir -p $P
echo "clone js -> upstream: $(T $SPIKE clone $JS $P/upstream)s"
cd $P/upstream
echo "upstream first git status after clone: $(T git status --porcelain)s"
git tag base0
mapfile_files() { git ls-files pkg | awk 'NR%37==0'; }
FILES=($(git ls-files pkg | awk 'NR%23==0'))
nf=${#FILES[@]}
c=0
for i in $(seq 1 100); do
    for k in $(seq 0 19); do
        f=${FILES[$(((i * 20 + k) % nf))]}
        echo "// change $i.$k" >>"$f"
        git add "$f"
    done
    if [ $((i % 10)) = 0 ]; then
        mkdir -p src/new
        echo "export const n$i = $i;" >src/new/f$i.js
        git add src/new/f$i.js
    fi
    git commit -q -m "c$i"
    case $i in 1) git tag b1 ;; 10) git tag b10 ;; 100) git tag b100 ;; esac
done
echo "commits created; files changed base0..b1=$(git diff --name-only base0 b1 | wc -l) ..b10=$(git diff --name-only base0 b10 | wc -l) ..b100=$(git diff --name-only base0 b100 | wc -l)"
# Fresh-view path: clone the (updated) base at b100
echo "FRESH: spike clone base(b100) -> view: $(T $SPIKE clone $P/upstream $P/fresh)s; first git status: $(cd $P/fresh && T git status --porcelain)s; second: $(cd $P/fresh && T git status --porcelain)s"
for N in 1 10 100; do
    S=$P/slot-$N
    $SPIKE clone $JS $S >/dev/null
    cd $S
    git status --porcelain >/dev/null
    git remote add base $P/upstream
    echo "slot-$N warm git status: $(T git status --porcelain)s"
    # agent dirt
    for f in $(git ls-files src | head -50); do echo "// agent" >>$f; done
    mkdir -p src/agent build/agent-tmp
    for j in $(seq 1 200); do echo x >src/agent/u$j.js; done
    for j in $(seq 1 100); do echo y >build/agent-tmp/o$j; done
    echo SECRET=1 >.env.local
    t_fetch=$(T git fetch -q base --tags)
    t_reset=$(T git reset -q --hard b$N)
    t_clean=$(T git clean -ffdxq -e node_modules/)
    t_status=$(T git status --porcelain)
    left=$(git status --porcelain --ignored | grep -v node_modules | wc -l)
    echo "REFRESH slot to b$N: fetch ${t_fetch}s reset --hard ${t_reset}s clean ${t_clean}s status ${t_status}s; leftover non-node_modules entries=$left; node_modules kept: $(ls node_modules | wc -l) entries; HEAD=$(git describe --tags)"
done
# clean slot refresh (no dirt) b100 -> base0 -> b100 for reverse direction
cd $P/slot-100
echo "clean slot b100->base0: reset $(T git reset -q --hard base0)s clean $(T git clean -ffdxq -e node_modules/)s; ->b100: reset $(T git reset -q --hard b100)s"
