#!/usr/bin/env python3
"""Real TLS/HTTP2 and UDP/TCP/TLS TURN payload tests in one isolated namespace."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets as random
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "deploy/gateway/scripts"))
from common import atomic, read_json
from render import render


def run(*args, input=None, timeout=180):
    result = subprocess.run(list(map(str, args)), input=input, capture_output=True, timeout=timeout)
    if result.returncode:
        # The fixture only contains disposable credentials, but keep output bounded.
        raise RuntimeError(f"{args[0]} failed: {result.stderr.decode()[-2000:]}")
    return result.stdout


def main():
    prefix = "dieter-deploy-test-" + random.token_hex(5)
    containers = []
    network = prefix
    volume = prefix + "-state"
    fixture_volume = prefix + "-fixture"
    image = prefix + ":gateway"
    alpine = "alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0"
    deps = read_json(ROOT / "deploy/gateway/dependencies.lock.json")
    scratch = Path.home() / ".cache" / "dieter-deployment-tests"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=prefix, dir=scratch) as temporary:
        temp = Path(temporary)
        temp.chmod(0o755)
        def start(name, img, *arguments, user=None):
            cname = prefix + "-" + name
            command = ["docker", "run", "-d", "--name", cname, "--network", "container:" + prefix + "-anchor",
                       "--memory", "256m", "--pids-limit", "128", "--log-opt", "max-size=1m", "--log-opt", "max-file=1",
                       "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                       "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777",
                       "-v", fixture_volume + ":/fixture:ro"]
            if name in ("turn", "caddy", "haproxy"):
                command += ["--cap-add", "NET_BIND_SERVICE"]
            if name == "turn":
                command += ["--entrypoint", "turnserver"]
            user = user or {"turn": "65534:65533", "caddy": "0:0", "haproxy": "99:99"}.get(name)
            if user:
                command += ["--user", user]
            command += [img, *arguments]
            run(*command)
            containers.append(cname)
            return cname
        def certificate(serial):
            run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", temp / "server-key.pending",
                "-out", temp / "server.csr", "-subj", "/CN=gateway.example.com")
            (temp / "extensions").write_text("subjectAltName=DNS:gateway.example.com,DNS:turn.example.com\nextendedKeyUsage=serverAuth\n")
            run("openssl", "x509", "-req", "-in", temp / "server.csr", "-CA", temp / "ca.pem", "-CAkey", temp / "ca.key",
                "-set_serial", str(serial), "-days", "2", "-extfile", temp / "extensions", "-out", temp / "server.pending")
            os.replace(temp / "server-key.pending", temp / "privkey.pem")
            os.replace(temp / "server.pending", temp / "fullchain.pem")
            (temp / "privkey.pem").chmod(0o644)  # disposable fixture, mounted read-only
            return hashlib.sha256(run("openssl", "x509", "-in", temp / "fullchain.pem", "-outform", "DER")).hexdigest()
        try:
            print("Building disposable gateway and TURN probe", flush=True)
            arch = run("docker", "info", "--format", "{{.Architecture}}").decode().strip()
            goarch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "amd64", "amd64": "amd64"}[arch]
            env = dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=goarch)
            for target, binary in (("./scripts/gateway-turn-probe", "probe"),):
                subprocess.run(["go", "build", "-trimpath", "-o", str(temp / binary), target], cwd=ROOT, env=env, check=True, timeout=300)
            run("docker", "build", "-q", "-f", ROOT / "Dockerfile.gateway", "-t", image, ROOT, timeout=600)
            run("docker", "network", "create", "--subnet", "198.18.0.0/24", network)
            run("docker", "volume", "create", volume)
            run("docker", "volume", "create", fixture_volume)
            run("docker", "run", "--rm", "--network", "none", "-v", volume + ":/state", alpine, "chown", "100:101", "/state")
            anchor = prefix + "-anchor"
            run("docker", "run", "-d", "--name", anchor, "--network", network, "--ip", "198.18.0.2", "-v", fixture_volume + ":/fixture", alpine, "sleep", "3600")
            containers.append(anchor)
            run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-keyout", temp / "ca.key", "-out", temp / "ca.pem", "-subj", "/CN=Dieter disposable test CA")
            fingerprint = certificate(1)
            config = read_json(ROOT / "deploy/gateway/profiles/example.settings.json")
            config.update(publicIPv4="198.18.0.2", turnIPv4="198.18.0.2")
            private = {"githubClientID": "fixture", "githubClientSecret": "fixture", "authSecret": random.token_hex(32),
                       "turnSharedSecret": 'fixture-$"\\= café/' + random.token_hex(32)}
            output = render(config, private, "ghcr.io/dbpprt/dieter-gateway@sha256:" + "a"*64, "fixture", temp / "rendered")
            output.chmod(0o755)
            turn = (output / "private/turnserver.conf").read_text().replace("/certificates/turn/current/", "/fixture/")
            # The namespace's relay address is reserved for benchmarking, never a real host.
            atomic(temp / "turnserver.conf", turn, 0o644)
            caddy = (output / "public/Caddyfile").read_text().replace("/certificates/gateway/current/", "/fixture/")
            caddy = caddy.replace("unix//run/dieter/caddy-admin.sock", "localhost:2019")
            atomic(temp / "Caddyfile", caddy, 0o644)
            run("docker", "cp", str(temp) + "/.", anchor + ":/fixture")
            gateway = prefix + "-gateway"
            run("docker", "run", "-d", "--name", gateway, "--network", "container:" + anchor,
                "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                "--env-file", output / "private/gateway.env", "-v", volume + ":/var/lib/dieter-gateway", image)
            containers.append(gateway)
            turn_name = start("turn", deps["coturn"], "-c", "/fixture/turnserver.conf")
            caddy_name = start("caddy", deps["caddy"], "caddy", "run", "--config", "/fixture/Caddyfile")
            start("haproxy", deps["haproxy"], "haproxy", "-W", "-db", "-f", "/fixture/rendered/public/haproxy.cfg")
            username = f"{int(time.time())+600}:dieter:7000188:fixture"
            password = base64.b64encode(hmac.new(private["turnSharedSecret"].encode(), username.encode(), hashlib.sha1).digest()).decode()
            def request(transport, fingerprint="", hold=0):
                return {"address": "198.18.0.2:" + ("443" if transport in ("https", "tls") else "3478"),
                        "serverName": "gateway.example.com" if transport == "https" else "turn.example.com",
                        "transport": transport, "username": username, "password": password, "expectedRelayIP": "198.18.0.2",
                        "caFile": "/fixture/ca.pem", "expectedCertificateSHA256": fingerprint, "holdSeconds": hold}
            def probe(req):
                return json.loads(run("docker", "run", "--rm", "-i", "--network", network, "-v", fixture_volume + ":/fixture:ro",
                    alpine, "/fixture/probe", input=json.dumps(req).encode(), timeout=75))
            for attempt in range(20):
                try:
                    probe(request("https", fingerprint))
                    break
                except RuntimeError:
                    time.sleep(1)
            else:
                raise RuntimeError("gateway TLS/HTTP2 readiness failed")
            for hostname in ("unknown.example.com", ""):
                probe({"address":"198.18.0.2:443", "serverName":hostname, "transport":"reject-sni"})
            probe({"address":"198.18.0.2:443", "serverName":"gateway.example.com", "transport":"reject-tls12"})
            for transport in ("udp", "tcp", "tls"):
                print(json.dumps(probe(request(transport, fingerprint if transport == "tls" else ""))), flush=True)
            for transport in ("udp", "tcp", "tls"):
                bad = request(transport)
                bad["password"] = "invalid"
                try:
                    probe(bad)
                    raise AssertionError("invalid TURN credentials accepted")
                except RuntimeError:
                    pass
            print("Testing certificate reload with active TURN allocation", flush=True)
            hold_name = prefix + "-hold"
            process = subprocess.Popen(["docker", "run", "--rm", "-i", "--name", hold_name, "--network", network,
                "-v", fixture_volume + ":/fixture:ro", alpine, "/fixture/probe"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            containers.append(hold_name)
            process.stdin.write(json.dumps(request("tls", fingerprint, 8)).encode())
            process.stdin.close()
            time.sleep(3)
            fingerprint = certificate(2)
            for name in ("privkey.pem", "fullchain.pem"):
                run("docker", "cp", temp / name, anchor + ":/fixture/" + name + ".pending")
                run("docker", "exec", anchor, "mv", "/fixture/" + name + ".pending", "/fixture/" + name)
            run("docker", "kill", "--signal", "SIGUSR2", turn_name)
            run("docker", "exec", caddy_name, "caddy", "reload", "--force", "--config", "/fixture/Caddyfile")
            time.sleep(1)
            probe(request("tls", fingerprint))
            probe(request("https", fingerprint))
            process.wait(timeout=30)
            if process.returncode:
                raise RuntimeError("TURN allocation did not survive certificate reload")
            print("Gateway TLS 1.3/h2, unauthorized gRPC, UDP/TCP/TLS TURN payloads and certificate reload passed", flush=True)
        except Exception:
            for name in containers:
                result = subprocess.run(["docker", "logs", "--tail", "12", name], capture_output=True)
                print(name + ": " + result.stderr.decode()[-1500:], file=sys.stderr)
            raise
        finally:
            for name in reversed(containers):
                subprocess.run(["docker", "rm", "-fv", name], capture_output=True)
            subprocess.run(["docker", "volume", "rm", volume, fixture_volume], capture_output=True)
            subprocess.run(["docker", "network", "rm", network], capture_output=True)
            subprocess.run(["docker", "image", "rm", image], capture_output=True)


if __name__ == "__main__":
    main()
