// L2 helper: marks a THROWAWAY Claude Code login as expired by moving its
// stored expiresAt into the past, so the next Claude Code process must refresh
// it. Refuses any config dir outside the spike's scratch area, so it can never
// touch a real login. Prints only metadata (minutes left, token fingerprint).
//
//   node expire-claude-login.mjs <claude-config-dir> [--show]
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { userInfo } from "node:os";
import { join, resolve } from "node:path";

const [dir, flag] = process.argv.slice(2);
if (!dir || !resolve(dir).includes("/tmp/omp-managed-auth/")) {
  throw new Error("refusing: only throwaway logins under tmp/omp-managed-auth/ may be changed");
}
const service = `Claude Code-credentials-${createHash("sha256").update(dir).digest("hex").slice(0, 8)}`;
const keychain = join(userInfo().homedir, "Library", "Keychains", "login.keychain-db");
const attributes = execFileSync("security", ["find-generic-password", "-s", service, keychain], {
  encoding: "utf8",
});
const account = /"acct"<blob>="([^"]*)"/.exec(attributes)?.[1];
const raw = execFileSync("security", ["find-generic-password", "-s", service, "-w", keychain], {
  encoding: "utf8",
});
const stored = JSON.parse(raw);
const oauth = stored.claudeAiOauth;
const describe = (o) =>
  `minutesLeft=${Math.round((o.expiresAt - Date.now()) / 60_000)} access=${createHash("sha256").update(o.accessToken).digest("hex").slice(0, 12)} refresh=${createHash(
    "sha256",
  )
    .update(o.refreshToken ?? "")
    .digest("hex")
    .slice(0, 12)}`;
if (flag === "--show") {
  console.log(`${service}: ${describe(oauth)}`);
} else {
  oauth.expiresAt = Date.now() - 60_000;
  execFileSync("security", [
    "add-generic-password",
    "-U",
    "-a",
    account,
    "-s",
    service,
    "-w",
    JSON.stringify(stored),
    keychain,
  ]);
  console.log(`${service}: expired -> ${describe(oauth)}`);
}
