#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID
R=/Volumes/External/dieter-spike/pathrelo/node
export npm_config_cache=$R/npmcache npm_config_devdir=$R/gyp npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
rm -rf $R/src $R/view
mkdir -p $R/src/addon $R/src/src && cd $R/src
cat >addon/package.json <<'J'
{"name":"reloaddon","version":"1.0.0","main":"index.js","scripts":{"install":"node-gyp rebuild"},"gypfile":true}
J
cat >addon/binding.gyp <<'J'
{"targets":[{"target_name":"relo","sources":["relo.c"]}]}
J
cat >addon/relo.c <<'C'
#include <node_api.h>
static napi_value Hello(napi_env env, napi_callback_info info){ napi_value s; napi_create_string_utf8(env,"addon-ok",NAPI_AUTO_LENGTH,&s); return s; }
NAPI_MODULE_INIT(){ napi_value fn; napi_create_function(env,NULL,0,Hello,NULL,&fn); napi_set_named_property(env,exports,"hello",fn); return exports; }
C
printf 'module.exports = require("./build/Release/relo.node");\n' >addon/index.js
cat >package.json <<'J'
{"name":"relo-web","private":true,"type":"module","scripts":{"dev":"vite"},
 "dependencies":{"reloaddon":"file:./addon","react":"^19.0.0","react-dom":"^19.0.0","lodash-es":"^4.17.21"},
 "devDependencies":{"vite":"^7.0.0","typescript":"^5.9.0"}}
J
printf '<!doctype html><script type="module" src="/src/main.ts"></script>\n' >index.html
printf 'import { createElement } from "react";\nimport { createRoot } from "react-dom/client";\nimport { chunk } from "lodash-es";\nexport const x: number = chunk([1,2,3],2).length;\nconsole.log(createElement, createRoot, x);\n' >src/main.ts
printf '{"compilerOptions":{"composite":true,"outDir":"dist","module":"esnext","target":"es2022","moduleResolution":"bundler","skipLibCheck":true},"include":["src"]}\n' >tsconfig.json
git init -q
printf 'node_modules/\ndist/\naddon/build/\n*.tsbuildinfo\n' >.gitignore
git add -A
git -c user.name=x -c user.email=x@x commit -qm b
t0=$(now)
npm install --silent >/dev/null 2>$R/npm-install.err
echo "npm install rc=$? $(el $t0 $(now))s; $(find node_modules -type f | wc -l) files"
npx tsc -b && echo "tsc -b ok"
(
    npx vite --port 47123 --strictPort >$R/vite-src.log 2>&1 &
    echo $! >$R/vite.pid
)
sleep 6
curl -s -o /dev/null http://localhost:47123/src/main.ts
sleep 3
kill $(cat $R/vite.pid) 2>/dev/null
pkill -f "vite --port 47123"
sleep 1
echo "vite src deps: $(ls node_modules/.vite/deps 2>/dev/null | tr '\n' ' ')"
sleep 1
t0=$(now)
/bin/cp -c -R $R/src $R/view
echo "clone (cp -c -R): $(el $t0 $(now))s"
cd $R/view
echo "addon from view: $(node -e 'console.log(require("reloaddon").hello())')"
echo "addon .node rpaths: $(otool -l node_modules/reloaddon/build/Release/relo.node | grep -A2 LC_RPATH | grep path | tr -s ' ' | tr '\n' ' ')none-else; deps: $(otool -L node_modules/reloaddon/build/Release/relo.node | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
echo "node_modules symlinks: $(find node_modules -type l | wc -l) total, absolute: $(find node_modules -type l -lname '/*' | wc -l)"
echo "files in node_modules naming source path: $(rg -l -F -uuu "$R/src" node_modules | wc -l): $(rg -l -F -uuu "$R/src" node_modules | head -5 | tr '\n' ' ')"
echo "tsc -b in view: $(npx tsc -b --verbose 2>&1 | grep -o 'is up to date\|is out of date[^*]*' | head -1)"
(
    npx vite --port 47124 --strictPort >$R/vite-view.log 2>&1 &
    echo $! >$R/vite.pid
)
sleep 6
curl -s -o /dev/null http://localhost:47124/src/main.ts
sleep 3
kill $(cat $R/vite.pid) 2>/dev/null
pkill -f "vite --port 47124"
sleep 1
echo "vite configHash src=$(grep -o '"configHash": *"[^"]*"' $R/src/node_modules/.vite/deps/_metadata.json) view=$(grep -o '"configHash": *"[^"]*"' node_modules/.vite/deps/_metadata.json)"
grep -i 'optimiz\|re-optim\|changed' $R/vite-view.log | head -3 | sed 's/^/  vite view log: /'
