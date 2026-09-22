#!/usr/bin/env python3
"""Issue, validate, atomically publish and reload gateway/TURN certificates."""
import argparse
import hashlib
import os
from pathlib import Path
import ssl
import sys
import time
from common import atomic, digest, pointer, read_json, require, run
from host import Host


def validate(chain, key, hostname):
    # OpenSSL verifies trust and hostname independently of the live service.
    run(["openssl", "x509", "-in", chain, "-noout", "-checkend", "604800"])
    run(["openssl", "verify", "-purpose", "sslserver", "-verify_hostname", hostname,
         "-untrusted", chain, chain])
    certificate_key = run(["openssl", "x509", "-in", chain, "-pubkey", "-noout"])
    private_key = run(["openssl", "pkey", "-in", key, "-pubout"])
    require(certificate_key == private_key, "certificate key mismatch")


def served_certificate(address, hostname):
    import socket
    context = ssl.create_default_context()
    with socket.create_connection(address, timeout=8) as connection:
        with context.wrap_socket(connection, server_hostname=hostname) as secure:
            return hashlib.sha256(secure.getpeercert(binary_form=True)).hexdigest()


def reload(host, s, kind):
    release = host.install / "current"
    if kind == "gateway":
        host.compose(release, "exec", "-T", "caddy", "caddy", "reload", "--force",
                     "--address", "unix//run/dieter/caddy-admin.sock", "--config", "/etc/caddy/Caddyfile")
    else:
        host.compose(release, "kill", "--signal", "SIGUSR2", "coturn")


def activate(host, s, kind, chain, key, reload_service=True):
    hostname = s["gatewayHost"] if kind == "gateway" else s["turnHost"]
    validate(chain, key, hostname)
    if kind == "gateway":
        for alias in s.get("gatewayAliases", []):
            validate(chain, key, alias)
    identity = digest(chain)[:32]
    root = host.etc / "certificates" / kind
    root.mkdir(parents=True, mode=0o750, exist_ok=True)
    os.chown(root, 0, 65533)
    generation = root / identity
    if not generation.exists():
        generation.mkdir(mode=0o750)
        os.chown(generation, 0, 65533)
        for name, source in (("fullchain.pem", chain), ("privkey.pem", key)):
            atomic(generation / name, Path(source).read_bytes(), 0o640)
            os.chown(generation / name, 0, 65533)
    current = root / "current"
    previous = current.resolve() if current.is_symlink() else None
    if previous == generation:
        return {"kind": kind, "changed": False}
    pointer(current, generation.name)
    try:
        if reload_service:
            reload(host, s, kind)
            if kind == "gateway":
                address = ("127.0.0.1", 8443) if s["topology"] == "single-ip" else (s["publicIPv4"], 443)
            else:
                address = ("127.0.0.1", 5349) if s["topology"] == "single-ip" else (s["turnIPv4"], 443)
            expected = hashlib.sha256(run(["openssl", "x509", "-in", chain, "-outform", "DER"])).hexdigest()
            for attempt in range(10):
                if served_certificate(address, hostname) == expected:
                    break
                time.sleep(1)
            else:
                raise ValueError("service did not load new certificate")
        if previous:
            pointer(root / "previous", previous.name)
        return {"kind": kind, "changed": True, "generation": identity}
    except Exception:
        if previous:
            pointer(current, previous.name)
            if reload_service:
                reload(host, s, kind)
        else:
            current.unlink(missing_ok=True)
        raise


def renew(host, s, dry_run=False, prepare=False):
    deps = read_json(host.install / "current/dependencies.lock.json")
    results = []
    for kind, hostname in (("gateway", s["gatewayHost"]), ("turn", s["turnHost"])):
        config = host.etc / ("acme-staging" if dry_run else "acme")
        config.mkdir(mode=0o700, exist_ok=True)
        # Separate lineages and webroot support the unchanged live HTTP server.
        command = ["docker", "run", "--rm", "--network", "host", "--cap-drop", "ALL",
                   "--security-opt", "no-new-privileges:true", "--memory", "192m", "--pids-limit", "64",
                   "-v", str(config) + ":/etc/letsencrypt", "-v", str(host.etc / "acme-webroot") + ":/webroot",
                   "--tmpfs", "/var/log/letsencrypt:size=16m", "--tmpfs", "/var/lib/letsencrypt:size=32m",
                   deps["certbot"], "certonly", "--non-interactive", "--agree-tos", "--email", s["acmeEmail"],
                   "--webroot", "--webroot-path", "/webroot", "--cert-name", hostname, "-d", hostname, "--keep-until-expiring"]
        if kind == "gateway":
            for alias in s.get("gatewayAliases", []):
                command += ["-d", alias]
        if dry_run:
            command.append("--staging")
        run(command, timeout=300)
        if dry_run:
            results.append({"kind": kind, "stagingIssuance": True})
            continue
        live = config / "live" / hostname
        results.append(activate(host, s, kind, live / "fullchain.pem", live / "privkey.pem", not prepare))
    return results


def main():
    import json
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--policy", default="/etc/dieter-deploy/host-policy.json")
    p.add_argument("--dry-run", action="store_true", help="Issue into a separate staging CA store; never activate it.")
    p.add_argument("--prepare", action="store_true", help="Prepare certificates before the first managed TLS activation.")
    p.add_argument("--settings", help="Candidate settings, required when preparing the first managed release.")
    a = p.parse_args()
    require(os.geteuid() == 0, "certificate operations require root")
    host = Host(a.policy)
    with host.lock():
        s = read_json(a.settings or host.install / "current/public/settings.json")
        require(a.prepare or s["tls"] == "managed", "renewal requires a managed TLS release")
        print(json.dumps(renew(host, s, a.dry_run, a.prepare)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(type(error).__name__, file=sys.stderr)
        sys.exit(1)
