#!/bin/bash
# mkswift.sh DIR : SwiftPM package, 2 libs + exe, 8 files each
set -eu
D=$1
rm -rf $D
mkdir -p $D && cd $D
cat >Package.swift <<'P'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "Relo",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "LibA"),
    .target(name: "LibB", dependencies: ["LibA"]),
    .executableTarget(name: "ReloApp", dependencies: ["LibB"]),
  ]
)
P
for t in LibA LibB ReloApp; do
    mkdir -p Sources/$t
    for i in $(seq 1 8); do
        imp=""
        [ $t = LibB ] && imp="import LibA"
        [ $t = ReloApp ] && imp="import LibB"
        {
            echo "import Foundation"
            echo "$imp"
            echo "public struct ${t}T$i: Codable, Hashable { public var a: Int; public var b: String; public var c: [Double]"
            echo "  public init(a: Int) { self.a = a; self.b = String(a); self.c = (0..<a).map(Double.init) }"
            echo "  public func f() -> Int { c.reduce(0, +).hashValue &+ a &* $i } }"
            echo "public func ${t}f$i(_ x: Int) -> Int { (0..<x).map { ${t}T$i(a: \$0).f() }.reduce(0, &+) }"
        } >Sources/$t/F$i.swift
    done
done
cat >Sources/ReloApp/main.swift <<'M'
import LibB
print("where=source")
M
printf '.build/\nDD/\n' >.gitignore
git init -q && git add -A && git -c user.name=x -c user.email=x@x commit -qm b
