#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID VIRTUAL_ENV
R=/Volumes/External/dieter-spike/pathrelo/py
export UV_CACHE_DIR=$R/uvcache UV_PYTHON=3.12 UV_NO_CONFIG=1 PIP_DISABLE_PIP_VERSION_CHECK=1
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
rm -rf $R/src-* $R/view-*
mkdir -p $R
mk() { # mk DIR : project with editable self-install
    mkdir -p $1/src/relo && cd $1
    cat >pyproject.toml <<P
[project]
name = "relo"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["requests", "pytest", "rich"]
[project.scripts]
relo = "relo:main"
[build-system]
requires = ["uv_build>=0.8,<0.20"]
build-backend = "uv_build"
P
    printf 'WHERE = "source"\ndef main():\n    print(WHERE, __file__)\n' >src/relo/__init__.py
    git init -q && printf '.venv/\n' >.gitignore && git add -A && git -c user.name=x -c user.email=x@x commit -qm b
}
report() { # report VIEWDIR LABEL
    V=$1
    L=$2
    S=${V/view-/src-}
    echo "--- $L (view $V)"
    echo "  pytest shebang: $(head -c 120 $V/.venv/bin/pytest | head -2 | tr '\n' '|')"
    echo "  activate VIRTUAL_ENV: $(grep -m1 -o 'VIRTUAL_ENV=.*' $V/.venv/bin/activate)"
    ls $V/.venv/lib/python3.12/site-packages/*.pth 2>/dev/null | while read p; do echo "  pth $(basename $p): $(head -c 100 $p)"; done
    printf 'WHERE = "view"\ndef main():\n    print(WHERE, __file__)\n' >$V/src/relo/__init__.py
    echo "  view .venv/bin/relo prints: $($V/.venv/bin/relo 2>&1)"
    echo "  view .venv/bin/python -c import relo: $(
        cd /
        $V/.venv/bin/python -c 'import relo,sys;print(relo.WHERE, sys.prefix)'
    )"
    echo "  view .venv/bin/pytest sys.prefix: $(
        $V/.venv/bin/python -c 'import sys;print(1)' >/dev/null
        printf 'import sys\ndef test_x():\n    print(sys.prefix)\n' >$V/t_x.py
        cd $V && .venv/bin/pytest -q -s t_x.py 2>&1 | grep -m1 '/Volumes'
    )"
    echo "  activated python: $(cd $V && . .venv/bin/activate && python -c 'import sys;print(sys.prefix)')"
    before=$(ls $S/.venv/lib/python3.12/site-packages | wc -l)
    if [ -x $V/.venv/bin/pip ]; then
        $V/.venv/bin/pip install -q six >/dev/null 2>&1
        how="view/.venv/bin/pip install six"
    else
        (cd $V && . .venv/bin/activate && uv pip install -q six >/dev/null 2>&1)
        how="activate + uv pip install six"
    fi
    after=$(ls $S/.venv/lib/python3.12/site-packages | wc -l)
    echo "  $how: source site-packages entries $before -> $after; six in view: $(ls $V/.venv/lib/python3.12/site-packages | grep -c '^six')"
}
# P1: python -m venv + pip
S=$R/src-pip
(
    mk $S
    cd $S
    t0=$(now)
    python3.12 -m venv .venv 2>/dev/null || $(uv python find 3.12) -m venv .venv
    .venv/bin/pip install -q -e . >/dev/null 2>&1
    t1=$(now)
    echo "P1 pip venv+install: $(el $t0 $t1)s"
)
/bin/cp -c -R $S $R/view-pip
report $R/view-pip "P1 python -m venv + pip -e"
# P2: uv venv + uv sync (default)
S=$R/src-uv
(
    mk $S
    cd $S
    t0=$(now)
    uv sync -q 2>&1 | tail -2
    t1=$(now)
    echo "P2 uv sync cold cache: $(el $t0 $t1)s"
)
/bin/cp -c -R $S $R/view-uv
report $R/view-uv "P2 uv sync (default venv)"
# P3: uv venv --relocatable + uv sync
S=$R/src-uvrel
(
    mk $S
    cd $S
    uv venv -q --relocatable
    t0=$(now)
    uv sync -q 2>&1 | tail -2
    t1=$(now)
    echo "P3 uv sync into relocatable venv (warm cache): $(el $t0 $t1)s"
    grep -i reloc .venv/pyvenv.cfg
)
/bin/cp -c -R $S $R/view-uvrel
report $R/view-uvrel "P3 uv venv --relocatable + uv sync"
# P4: fresh uv sync into a new view (no venv cloned), warm cache
/bin/cp -c -R $R/src-uv $R/view-fresh
rm -rf $R/view-fresh/.venv
cd $R/view-fresh
t0=$(now)
uv sync -q --offline 2>&1 | tail -2
t1=$(now)
echo "P4 fresh uv sync --offline into new view (warm cache, clone link-mode): $(el $t0 $t1)s, $(find .venv -type f | wc -l) files"
cd $R
rm -rf view-fresh2
/bin/cp -c -R src-uv view-fresh2
rm -rf view-fresh2/.venv
cd view-fresh2
t0=$(now)
UV_LINK_MODE=copy uv sync -q --offline 2>&1 | tail -2
t1=$(now)
echo "P4b same with link-mode=copy: $(el $t0 $t1)s"
cd $R
t0=$(now)
/bin/cp -c -R src-uv/.venv view-fresh2/.venv-clone
t1=$(now)
echo "P4c clonefile of the whole .venv: $(el $t0 $t1)s"
