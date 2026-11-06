#!/bin/bash
set -u
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID RUSTC_WRAPPER
R=/Volumes/External/dieter-spike/pathrelo/rs
export CARGO_HOME=$R/cargohome CARGO_TERM_COLOR=never
now() { python3 -c 'import time;print(time.time())'; }
el() { python3 -c "print(round($2-$1,2))"; }
rm -rf $R/src $R/view*
mkdir -p $R/src && cd $R/src
cat >Cargo.toml <<T
[workspace]
members = ["app", "core", "util"]
resolver = "2"
T
cargo new -q --lib core
cargo new -q --lib util
cargo new -q app
cat >>core/Cargo.toml <<T
serde = { version = "1", features = ["derive"] }
serde_json = "1"
regex = "1"
util = { path = "../util" }
[build-dependencies]
cc = "1"
T
printf 'pub fn u() -> u32 { 7 }\n' >util/src/lib.rs
mkdir -p core/csrc
printf 'int c_add(int a, int b){ return a+b; }\n' >core/csrc/add.c
cat >core/build.rs <<'B'
fn main() {
    cc::Build::new().file("csrc/add.c").compile("cadd");
    println!("cargo:rustc-env=GEN_DIR={}", std::env::var("OUT_DIR").unwrap());
    println!("cargo:rerun-if-changed=csrc/add.c");
}
B
cat >core/src/lib.rs <<'L'
use serde::{Deserialize, Serialize};
unsafe extern "C" { fn c_add(a: i32, b: i32) -> i32; }
#[derive(Serialize, Deserialize, Debug)]
pub struct S { pub n: u32 }
pub fn run() -> String {
    let re = regex::Regex::new(r"\d+").unwrap();
    let s = S { n: util::u() + unsafe { c_add(1, 2) } as u32 };
    format!("{} {} where=source gen={}", serde_json::to_string(&s).unwrap(), re.is_match("42"), env!("GEN_DIR"))
}
L
cat >>app/Cargo.toml <<T
core = { path = "../core" }
T
printf 'fn main() { println!("{}", core::run()); }\n' >app/src/main.rs
git init -q 2>/dev/null
git add -A
git -c user.name=x -c user.email=x@x commit -qm b
t0=$(now)
cargo build -q 2>&1 | tail -3
t1=$(now)
echo "source cold build: $(el $t0 $t1)s ($(ls target/debug/deps/*.rlib | wc -l) rlibs)"
sleep 1
t0=$(now)
/bin/cp -c -R $R/src $R/view
t1=$(now)
echo "clone: $(el $t0 $t1)s ($(find $R/src -type f | wc -l) files)"
cd $R/view
t0=$(now)
cargo build -v >../view1.log 2>&1
t1=$(now)
echo "view cargo build: $(el $t0 $t1)s; Fresh=$(grep -c '^ *Fresh' ../view1.log) Compiling=$(grep -c '^ *Compiling' ../view1.log) Dirty=$(grep -c '^ *Dirty' ../view1.log)"
echo "  view binary prints: $(./target/debug/app)"
sed -i '' 's/where=source/where=view/' core/src/lib.rs
t0=$(now)
cargo build -v >../view2.log 2>&1
t1=$(now)
echo "view after editing core: $(el $t0 $t1)s; Compiling=$(grep '^ *Compiling' ../view2.log | awk '{print $2}' | tr '\n' ' ')"
echo "  view binary prints: $(./target/debug/app)"
echo "  link-search in rustc cmd: $(grep -o 'native=[^ ]*' ../view2.log | sort -u | sed "s#$R/##" | tr '\n' ' ')"
# does it still build if the source target dir is gone (cross-dependency)?
mv $R/src/target $R/src/target.moved
touch app/src/main.rs
cargo build >../view3.log 2>&1
echo "  view build with source target/ moved away: rc=$?"
grep -m2 'error\|cannot find' ../view3.log | sed 's/^/   /'
mv $R/src/target.moved $R/src/target
