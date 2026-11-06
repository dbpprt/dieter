// fixture.mjs DIR: the Atrium pair fixture (same content as atrium.mjs writeFixture).
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const project = process.argv[2];
if (!project) throw new Error("usage: fixture.mjs DIR");
mkdirSync(join(project, "src"), { recursive: true });
for (let f = 0; f < 8; f++) {
  const lines = [`// module ${f}: inventory pricing rules`, `export const MODULE_${f} = ${f};`];
  for (let i = 0; i < 40; i++)
    lines.push(
      `export function rule${f}_${i}(qty, price) { return qty > ${i} ? price * ${(1 - i / 1000).toFixed(3)} : price; }`,
    );
  writeFileSync(join(project, "src", `module${f}.js`), lines.join("\n") + "\n");
}
writeFileSync(join(project, "README.md"), "# pricing fixture\n");
const git = (...a) => execFileSync("git", a, { cwd: project });
git("init", "-q", "-b", "main");
git("config", "user.name", "live-test");
git("config", "user.email", "live-test@example.invalid");
git("add", ".");
git("commit", "-qm", "fixture");
