#!/usr/bin/env python3
"""Root-owned, durable gateway operations. SSH observes; systemd owns execution."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.error
from common import NAME, atomic, canonical, digest, pointer, read_json, require, run, sync_dir, set_operation_log, protected_log
from bundle import ARCHIVE, MANIFEST, SIGNATURE, extract, verify
from render import render, secrets, settings

TERMINAL = {"committed", "rolled_back", "failed"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class Host:
    def __init__(self, policy):
        self.policy = Path(policy)
        self.config = read_json(policy)
        for name in ("installRoot", "configRoot", "stateRoot", "runtimeRoot"):
            require(Path(self.config[name]).is_absolute(), "policy paths must be absolute")
        self.install = Path(self.config["installRoot"])
        self.etc = Path(self.config["configRoot"])
        self.state = Path(self.config["stateRoot"])
        self.runtime = Path(self.config["runtimeRoot"])
        self.ops = self.state / "operations"

    def initialize(self):
        for path in (self.install, self.etc, self.state, self.runtime, self.ops, self.install / "releases", self.etc / "releases"):
            path.mkdir(mode=0o700, parents=True, exist_ok=True)

    @contextlib.contextmanager
    def lock(self, name="operation.lock"):
        self.runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (self.runtime / name).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def operation(self, operation):
        require(NAME.fullmatch(operation), "invalid operation ID")
        return self.ops / operation

    def status(self, operation):
        return read_json(self.operation(operation) / "status.json")

    def transition(self, operation, state, **extra):
        path = self.operation(operation) / "status.json"
        current = read_json(path) if path.exists() else {"id": operation, "createdAt": now()}
        current.update(extra, state=state, updatedAt=now())
        atomic(path, canonical(current))
        # An append-only event history retains previous transitions for recovery.
        with (path.parent / "events.jsonl").open("ab") as log:
            os.chmod(log.name, 0o600)
            log.write(canonical(current) + b"\n")
            log.flush()
            os.fsync(log.fileno())
        return current

    def admit(self, operation, incoming):
        """Incoming contains only a signed archive and non-secret settings."""
        self.initialize()
        incoming = Path(incoming).resolve()
        filenames = [ARCHIVE, MANIFEST, SIGNATURE, "settings.json"]
        if (incoming / "legacy.caddy").exists():
            filenames.append("legacy.caddy")
        for name in filenames:
            require((incoming / name).is_file() and not (incoming / name).is_symlink(), "missing incoming file")
            require((incoming / name).stat().st_size <= 32 * 1024 * 1024, "incoming file too large")
        request = {name: digest(incoming / name) for name in filenames}
        request_hash = hashlib.sha256(canonical(request)).hexdigest()
        with self.lock("admission.lock"):
            dest = self.operation(operation)
            if dest.exists():
                require(self.status(operation)["requestSHA256"] == request_hash, "operation ID already has different inputs")
                return self.status(operation)
            pending = sum(1 for op in self.ops.iterdir() if (op / "status.json").is_file()
                          and read_json(op / "status.json")["state"] not in TERMINAL)
            require(pending < 8, "deployment admission queue is full")
            require(shutil.disk_usage(self.state).free > 3*1024*1024*1024, "insufficient deployment staging space")
            staging = self.ops / (".admitting-" + operation)
            if staging.exists():
                shutil.rmtree(staging)
            staging.mkdir(mode=0o700)
            (staging / "input").mkdir(mode=0o700)
            for name in filenames:
                atomic(staging / "input" / name, (incoming / name).read_bytes())
            atomic(staging / "status.json", canonical({"id": operation, "state": "admitted", "createdAt": now(),
                                                       "requestSHA256": request_hash}))
            os.rename(staging, dest)
            sync_dir(self.ops)
        run(["systemctl", "start", "--no-block", "dieter-deploy@" + operation + ".service"])
        return self.status(operation)

    def volume(self, s):
        result = json.loads(run(["docker", "volume", "inspect", s["stateVolume"]]))
        path = Path(result[0]["Mountpoint"])
        require((path / "gateway.db").is_file(), "existing gateway database missing; refusing fresh identity")
        require(path.stat().st_uid == 100 and path.stat().st_gid == 101, "unexpected gateway storage owner")
        for name in ("gateway-ed25519.pem", "daemon-ca-ed25519.pem", "daemon-ca.pem"):
            require((path / "signing" / name).is_file(), "gateway identity material is incomplete")
        return path

    def backup(self, s, operation):
        """Online SQLite backup plus the corresponding stable identity/config."""
        source = self.volume(s)
        root = self.state / "backup-staging"
        root.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="snapshot-", dir=root) as temporary:
            stage = Path(temporary)
            gateway = stage / "gateway"
            gateway.mkdir(mode=0o700)
            with sqlite3.connect("file:" + str(source / "gateway.db") + "?mode=ro", uri=True, timeout=30) as src:
                with sqlite3.connect(gateway / "gateway.db") as dst:
                    src.backup(dst, pages=256, sleep=0.05)
                    require(dst.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "backup database is corrupt")
                    require(dst.execute("PRAGMA user_version").fetchone()[0] == 1, "unsupported backup schema")
            os.chmod(gateway / "gateway.db", 0o600)
            shutil.copytree(source / "signing", gateway / "signing")
            shutil.copytree(self.etc, stage / "configuration", symlinks=True)
            shutil.copyfile(self.policy, stage / "host-policy.json")
            current = self.install / "current"
            if current.is_symlink():
                shutil.copytree(current.resolve(), stage / "release", symlinks=True)
            # Save runnable image bytes as well as manifests: a digest alone is
            # not a recovery archive when registry tags are later removed.
            if current.is_symlink():
                compose = read_json(current / "public/compose.json")
                images = sorted({service["image"] for service in compose["services"].values()})
                sizes = json.loads(run(["docker", "image", "inspect", *images]))
                required = sum(image["Size"] for image in sizes)
                require(required <= 2*1024*1024*1024 and shutil.disk_usage(root).free > required + 1024*1024*1024,
                        "insufficient bounded backup staging capacity")
                run(["docker", "image", "save", "--output", stage / "images.tar", *images], timeout=300)
            atomic(stage / "metadata.json", canonical({"createdAt": now(), "operation": operation, "schema": 1,
                "gatewayCAFingerprint": digest(source / "signing" / "daemon-ca.pem")}))
            # A root-owned transport performs encrypted off-host storage. No
            # local-only backup can satisfy pre-activation safety.
            backup_command = self.config["backupCommand"]
            require(isinstance(backup_command, list) and backup_command and Path(backup_command[0]).is_absolute(), "encrypted off-host backup is not configured")
            run([*backup_command, str(stage)], timeout=900)
        return {"completedAt": now(), "gatewayCAFingerprint": digest(source / "signing" / "daemon-ca.pem")}

    def compose(self, release, *args):
        return run(["docker", "compose", "--project-name", self.config["project"],
                    "--file", Path(release) / "public" / "compose.json", *args], timeout=240)

    def activate(self, release):
        """The named services share the existing volume; never remove orphans."""
        services = read_json(Path(release) / "public" / "compose.json")["services"]
        # Introduce HAProxy only after Caddy has released public 443. Removing a
        # previous HAProxy is similarly explicit on rollback to the old topology.
        if "haproxy" not in services:
            result = run(["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project=" + self.config["project"],
                          "--filter", "label=com.docker.compose.service=haproxy"]).decode().split()
            if result:
                run(["docker", "stop", "--time", "30", *result], timeout=60)
        for service in ("dieter-gateway", "coturn", "caddy", "haproxy"):
            if service in services:
                self.compose(release, "up", "-d", "--no-deps", "--pull", "never", service)

    def health(self, s, revision=None):
        # No redirects, proxy variables, or disabling TLS verification.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("https://" + s["gatewayHost"] + "/healthz", timeout=8) as response:
            health = json.load(response)
        require(str(health.get("apiVersion")) == "1", "gateway contract mismatch")
        if revision:
            require(health.get("revision") == revision, "unexpected live source revision")
        try:
            opener.open("https://" + s["gatewayHost"] + "/", timeout=8)
            raise ValueError("gateway root must return 404")
        except urllib.error.HTTPError as e:
            require(e.code == 404, "unexpected gateway root response")

    def accept(self, operation, report):
        # No global lock here: the activation worker holds it while awaiting
        # external authenticated probes. Only root may write this evidence.
        status = self.status(operation)
        require(status["state"] == "checking", "operation is not awaiting readiness")
        value = read_json(report)
        require(value.get("requestSHA256") == status["requestSHA256"] and value.get("sourceRevision") == status["sourceRevision"], "readiness evidence belongs to different inputs")
        require(value.get("gatewayAuthenticated") is True and value.get("daemonAuthenticated") is True,
                "authenticated gateway and daemon checks are required")
        s = read_json(self.operation(operation) / "input" / "settings.json")
        required = {"udp", "tcp", "tls"} if s["tls"] == "managed" else {"udp", "tcp"}
        require(required <= set(value.get("turnPayloadTransports", [])), "TURN payload evidence is incomplete")
        require(value.get("unauthenticatedRejected") is True, "unauthenticated rejection evidence is required")
        atomic(self.operation(operation) / "readiness.json", canonical(value))
        return {"id": operation, "readinessReceived": True}

    def execute(self, operation):
        self.initialize()
        with self.lock():
            state = self.status(operation)
            if state["state"] in TERMINAL:
                return state
            op = self.operation(operation)
            set_operation_log(op / "tool.log")
            previous = Path(state["previousRelease"]) if state.get("previousRelease") else None
            activation_started = state["state"] in {"activating", "checking", "rolling_back"}
            try:
                # Never replay a possibly interrupted activation after reboot.
                # Restore the known previous deployment instead.
                require(not activation_started, "interrupted activation requires rollback")
                attempts = state.get("attempts", 0) + 1
                require(attempts <= 3, "deployment retry budget exhausted")
                self.transition(operation, state["state"], attempts=attempts)
                incoming = op / "input"
                m = verify(incoming)
                s = settings(read_json(incoming / "settings.json"))
                for name in ("installRoot", "configRoot", "runtimeRoot", "project", "gatewayHost", "allowedUserIDs"):
                    require(s[name] == self.config[name], "settings do not match installed host policy")
                current = self.install / "current"
                require(current.is_symlink(), "import and verify the existing deployment before activation")
                previous = current.resolve()
                require(previous.is_dir(), "previous release is missing")
                source = self.volume(s)
                secret_path = self.etc / "secrets.json"
                private = secrets(secret_path)
                self.transition(operation, "verified", sourceRevision=m["sourceRevision"], previousRelease=str(previous),
                                secretSHA256=digest(secret_path), gatewayCAFingerprint=digest(source / "signing" / "daemon-ca.pem"),
                                previousController=str(Path(self.config["controllerLink"]).resolve()) if self.config.get("controllerLink") else None)
                release = self.install / "releases" / operation
                if release.exists():
                    shutil.rmtree(release)  # only this never-activated, uncommitted operation
                extract(incoming / ARCHIVE, release)
                require(read_json(release / "dependencies.lock.json") == m["dependencies"], "bundle dependency manifest mismatch")
                for name in (ARCHIVE, MANIFEST, SIGNATURE):
                    shutil.copyfile(incoming / name, release / name)
                rendered = op / "rendered"
                if rendered.exists():
                    shutil.rmtree(rendered)
                render(s, private, m["image"], operation, rendered, incoming / "legacy.caddy" if s["legacyHosts"] else None)
                shutil.copytree(rendered / "public", release / "public")
                target_private = self.etc / "releases" / operation
                if target_private.exists():
                    shutil.rmtree(target_private)
                shutil.copytree(rendered / "private", target_private)
                os.chown(target_private / "turnserver.conf", 0, 65533)
                os.chmod(target_private / "turnserver.conf", 0o640)
                for directory in ("acme-webroot", "certificates"):
                    (self.etc / directory).mkdir(mode=0o755, exist_ok=True)
                self.compose(release, "config", "--quiet")
                self.compose(release, "pull")
                # Validate with the exact deployed binaries before touching any listener.
                deps = m["dependencies"]
                run(["docker", "run", "--rm", "--network", "none", "-v", str(release / "public/Caddyfile") + ":/etc/caddy/Caddyfile:ro",
                     "-v", str(self.etc / "certificates") + ":/certificates:ro", deps["caddy"], "caddy", "validate", "--config", "/etc/caddy/Caddyfile"])
                if s["tls"] == "managed" and s["topology"] == "single-ip":
                    run(["docker", "run", "--rm", "--network", "none", "-v", str(release / "public/haproxy.cfg") + ":/config:ro",
                         deps["haproxy"], "haproxy", "-c", "-f", "/config"])
                self.transition(operation, "staged")
                backup = self.backup(s, operation)
                self.transition(operation, "backed_up", backup=backup)
                require(digest(secret_path) == self.status(operation)["secretSHA256"], "secrets changed during staging")
                self.transition(operation, "activating")
                activation_started = True
                self.activate(release)
                self.transition(operation, "checking", turnTransports=["udp", "tcp", "tls"] if s["tls"] == "managed" else ["udp", "tcp"])
                deadline = time.monotonic() + self.config["readinessTimeoutSeconds"]
                while time.monotonic() < deadline:
                    if (op / "readiness.json").is_file():
                        self.health(s, m["sourceRevision"])
                        require(digest(source / "signing" / "daemon-ca.pem") == backup["gatewayCAFingerprint"], "gateway CA changed")
                        pointer(self.install / "previous", previous)
                        pointer(current, release)
                        if self.config.get("controllerLink"):
                            pointer(self.config["controllerLink"], release)
                        result = self.transition(operation, "committed", release=str(release), acceptedAt=now())
                        try:
                            run(["systemctl", "start", "--no-block", "dieter-backup.service"])
                        except Exception:
                            result = self.transition(operation, "committed", postActivationBackupQueueFailed=True)
                        return result
                    time.sleep(2)
                raise ValueError("external readiness deadline expired")
            except Exception as error:
                import traceback
                protected_log(traceback.format_exc().encode())
                # No raw external-tool output or secret-bearing exception details
                # are written to public status.
                code = type(error).__name__
                failed_stage = self.status(operation)["state"]
                if activation_started and previous:
                    self.transition(operation, "rolling_back", failureClass=code, failureStage=failed_stage)
                    try:
                        self.activate(previous)
                        old_settings = read_json(previous / "public" / "settings.json")
                        self.health(old_settings)
                        pointer(self.install / "current", previous)
                        if self.config.get("controllerLink") and self.status(operation).get("previousController"):
                            pointer(self.config["controllerLink"], self.status(operation)["previousController"])
                        return self.transition(operation, "rolled_back")
                    except Exception:
                        return self.transition(operation, "failed", rollbackFailed=True)
                return self.transition(operation, "failed", failureClass=code, failureStage=failed_stage)

    def resume(self):
        self.initialize()
        for op in sorted(self.ops.iterdir()):
            if op.name.startswith(".") or not (op / "status.json").is_file():
                continue
            if self.status(op.name)["state"] not in TERMINAL:
                run(["systemctl", "start", "--no-block", "dieter-deploy@" + op.name + ".service"])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--policy", default="/etc/dieter-deploy/host-policy.json")
    sub = p.add_subparsers(dest="command", required=True)
    for cmd in ("admit", "accept"):
        command = sub.add_parser(cmd)
        command.add_argument("operation")
        command.add_argument("path")
    for cmd in ("status", "execute"):
        sub.add_parser(cmd).add_argument("operation")
    sub.add_parser("resume")
    sub.add_parser("backup")
    a = p.parse_args()
    require(os.geteuid() == 0, "gateway host operations require root")
    host = Host(a.policy)
    if a.command in ("admit", "accept"):
        result = getattr(host, a.command)(a.operation, a.path)
    elif a.command in ("status", "execute"):
        result = getattr(host, a.command)(a.operation)
    elif a.command == "backup":
        with host.lock():
            result = host.backup(read_json(host.install / "current/public/settings.json"), "scheduled-" + str(int(time.time())))
    else:
        result = host.resume()
    print(json.dumps(result or {"ok": True}))
    if isinstance(result, dict) and result.get("state") in {"failed", "rolled_back"} and a.command == "execute":
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"error": type(e).__name__}), file=sys.stderr)
        sys.exit(1)
