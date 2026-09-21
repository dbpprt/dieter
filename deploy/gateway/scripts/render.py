#!/usr/bin/env python3
"""Render validated settings and protected secrets into an immutable release."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
from common import ROOT, IMAGE, NAME, atomic, keys, read_json, require

FIELDS = "interfaceVersion project gatewayHost turnHost publicIPv4 turnIPv4 topology tls acmeEmail allowedUserIDs stateVolume installRoot configRoot runtimeRoot caddyData caddyConfig legacyHosts turn limits".split()
SECRET_FIELDS = "githubClientID githubClientSecret authSecret turnSharedSecret".split()


def hostname(value):
    require(isinstance(value, str) and len(value) <= 253 and re.fullmatch(
        r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+", value), "invalid hostname")


def settings(value):
    keys(value, FIELDS, "settings")
    require(type(value["interfaceVersion"]) is int and value["interfaceVersion"] == 1, "unsupported bundle interface")
    for field in ("project", "stateVolume"):
        require(isinstance(value[field], str) and NAME.fullmatch(value[field]), f"invalid {field}")
    for field in ("gatewayHost", "turnHost"):
        hostname(value[field])
    require(value["gatewayHost"] != value["turnHost"], "gateway and TURN hosts must differ")
    for field in ("publicIPv4", "turnIPv4"):
        ip = ipaddress.ip_address(value[field])
        require(ip.version == 4 and not ip.is_loopback and not ip.is_multicast and not ip.is_unspecified,
                "an explicit routable IPv4 address is required")
    require(value["topology"] in ("single-ip", "two-ip"), "invalid topology")
    require((value["publicIPv4"] == value["turnIPv4"]) == (value["topology"] == "single-ip"), "topology/IP mismatch")
    require(value["tls"] in ("existing", "managed"), "invalid TLS phase")
    require(re.fullmatch(r"[A-Za-z0-9._+%-]+@[a-zA-Z0-9.-]+", value["acmeEmail"]), "invalid ACME email")
    ids = value["allowedUserIDs"]
    require(isinstance(ids, list) and 0 < len(ids) <= 32 and all(type(i) is int and i > 0 for i in ids)
            and len(ids) == len(set(ids)), "invalid allowed user IDs")
    for field in ("installRoot", "configRoot", "runtimeRoot", "caddyData", "caddyConfig"):
        require(isinstance(value[field], str) and re.fullmatch(r"/[A-Za-z0-9/_-]+", value[field])
                and ".." not in value[field] and "//" not in value[field], f"invalid {field}")
    require(isinstance(value["legacyHosts"], list) and len(value["legacyHosts"]) <= 8, "invalid legacy hosts")
    require(len(value["legacyHosts"]) == len(set(value["legacyHosts"])), "duplicate legacy host")
    for host in value["legacyHosts"]:
        hostname(host)
        require(host not in (value["gatewayHost"], value["turnHost"]), "duplicate host")
    keys(value["turn"], "minPort maxPort userQuota totalQuota maxBps bpsCapacity".split(), "TURN")
    t = value["turn"]
    require(all(type(n) is int and n > 0 for n in t.values()), "TURN bounds must be positive integers")
    require(1024 <= t["minPort"] < t["maxPort"] <= 65535, "invalid relay port range")
    require(t["userQuota"] <= t["totalQuota"] <= 4096 and t["maxPort"] - t["minPort"] + 1 >= 2 * t["totalQuota"], "insufficient relay ports")
    require(t["maxBps"] <= t["bpsCapacity"] <= 1250000000, "invalid TURN bandwidth budget")
    keys(value["limits"], "gatewayMemoryMiB turnMemoryMiB caddyMemoryMiB haproxyMemoryMiB pids nofile".split(), "limits")
    require(all(type(n) is int and 16 <= n <= 1048576 for n in value["limits"].values()), "invalid resource bounds")
    return value


def secrets(path):
    require(stat.S_IMODE(Path(path).stat().st_mode) & 0o077 == 0, "secret input must have mode 0600")
    value = read_json(path)
    keys(value, SECRET_FIELDS, "secrets")
    for field, text in value.items():
        require(isinstance(text, str) and text and len(text.encode()) <= 8192
                and not any(ord(c) < 32 or ord(c) == 127 for c in text), f"invalid {field}")
    # Coturn's configuration parser strips surrounding whitespace and treats a
    # leading # as a comment; reject values it cannot preserve byte for byte.
    turn = value["turnSharedSecret"]
    require(len(turn.encode()) >= 32 and turn == turn.strip() and not turn.startswith("#"), "invalid TURN secret encoding")
    require(re.fullmatch(r"[a-fA-F0-9]{64,}", value["authSecret"]) and len(value["authSecret"]) % 2 == 0,
            "authSecret must encode at least 32 bytes as hexadecimal")
    return value


def render(config, private, image, release, output, legacy=None):
    s = settings(config)
    require(IMAGE.fullmatch(image), "gateway image must be pinned by digest")
    require(NAME.fullmatch(release), "invalid release ID")
    deps = read_json(ROOT / "dependencies.lock.json")
    require(all(IMAGE.fullmatch(v) for v in deps.values()), "dependencies must be pinned")
    out = Path(output)
    require(not out.exists(), "render output already exists")
    out.mkdir(mode=0o700, parents=True)
    pub, sec = out / "public", out / "private"
    pub.mkdir(mode=0o755)
    sec.mkdir(mode=0o700)
    install = s["installRoot"] + "/releases/" + release
    protected = s["configRoot"] + "/releases/" + release
    certs = s["configRoot"] + "/certificates"
    managed = s["tls"] == "managed"
    multiplex = managed and s["topology"] == "single-ip"
    hosts = [s["gatewayHost"], *s["legacyHosts"]]
    if s["legacyHosts"]:
        require(legacy is not None, "legacy hosts require a reviewed Caddy fragment")
    elif legacy:
        raise ValueError("legacy fragment requires declared hosts")
    env = {
        "DIETER_GATEWAY_ADDR": "127.0.0.1:4243", "DIETER_GATEWAY_PROXY_MODE": "1",
        "DIETER_PUBLIC_URL": "https://" + s["gatewayHost"],
        "DIETER_GITHUB_CLIENT_ID": private["githubClientID"], "DIETER_GITHUB_CLIENT_SECRET": private["githubClientSecret"],
        "DIETER_AUTH_SECRET": private["authSecret"],
        "DIETER_GITHUB_ALLOWED_USER_IDS": ",".join(map(str, s["allowedUserIDs"])),
        "DIETER_NATIVE_REDIRECT_URIS": "dieter-mac://oauth/callback,dieter-android://oauth/callback",
        "DIETER_NATIVE_SESSION_TTL": "720h", "DIETER_RTC_TTL": "5m",
        "DIETER_RTC_STUN_URLS": f"stun:{s['gatewayHost']}:3478",
        "DIETER_RTC_TURN_URLS": ",".join([f"turn:{s['gatewayHost']}:3478?transport=udp", f"turn:{s['gatewayHost']}:3478?transport=tcp"] +
                                      ([f"turns:{s['turnHost']}:443?transport=tcp"] if managed else [])),
        "DIETER_RTC_TURN_SECRET": private["turnSharedSecret"].encode().hex(),
    }
    atomic(sec / "gateway.env", "".join(f"{k}={v}\n" for k, v in env.items()))
    t = s["turn"]
    turn = ["listening-port=3478", f"listening-ip={s['turnIPv4']}", "listening-ip=127.0.0.1",
            f"relay-ip={s['turnIPv4']}", f"external-ip={s['turnIPv4']}", "relay-threads=1",
            f"min-port={t['minPort']}", f"max-port={t['maxPort']}", "fingerprint", "use-auth-secret",
            "static-auth-secret=" + private["turnSharedSecret"], f"realm={s['gatewayHost']}", f"server-name={s['turnHost']}",
            f"user-quota={t['userQuota']}", f"total-quota={t['totalQuota']}", f"max-bps={t['maxBps']}", f"bps-capacity={t['bpsCapacity']}",
            "no-cli", "no-dtls", "no-tcp-relay", "no-multicast-peers", "no-software-attribute", "log-file=stdout", "simple-log"]
    # Public relay-to-relay pairs remain allowed. No IPv6 listener is created.
    for start, end in [("0.0.0.0", "0.255.255.255"), ("10.0.0.0", "10.255.255.255"), ("100.64.0.0", "100.127.255.255"),
                       ("127.0.0.0", "127.255.255.255"), ("169.254.0.0", "169.254.255.255"), ("172.16.0.0", "172.31.255.255"),
                       ("192.168.0.0", "192.168.255.255"), ("224.0.0.0", "255.255.255.255")]:
        turn.append(f"denied-peer-ip={start}-{end}")
    if managed:
        turn += [f"tls-listening-port={5349 if multiplex else 443}", "no-tlsv1", "no-tlsv1_1",
                 "cert=/certificates/turn/current/fullchain.pem", "pkey=/certificates/turn/current/privkey.pem"]
    else:
        turn.append("no-tls")
    atomic(sec / "turnserver.conf", "\n".join(turn) + "\n")
    caddy = ["{", "  admin unix//run/dieter/caddy-admin.sock", f"  email {s['acmeEmail']}", "  servers {", "    protocols h1 h2", "  }"]
    if multiplex:
        caddy += ["  https_port 8443", "  default_bind 127.0.0.1"]
    elif s["topology"] == "two-ip":
        caddy += [f"  default_bind {s['publicIPv4']}"]
    caddy += ["}", f"http://{', http://'.join([*hosts, s['turnHost']])} {{", f"  bind {s['publicIPv4']}",
              "  handle /.well-known/acme-challenge/* {", "    root * /acme", "    file_server", "  }",
              "  handle {", "    redir https://{host}{uri} 308", "  }", "}", s["gatewayHost"] + " {"]
    if managed:
        caddy += ["  tls /certificates/gateway/current/fullchain.pem /certificates/gateway/current/privkey.pem {", "    protocols tls1.3", "  }"]
    else:
        caddy += ["  tls {", "    protocols tls1.3", "  }"]
    caddy += ["  reverse_proxy h2c://127.0.0.1:4243", "}"]
    if legacy:
        caddy.append(Path(legacy).read_text())
    atomic(pub / "Caddyfile", "\n".join(caddy) + "\n", 0o644)
    haproxy = f"""global
  maxconn 2048
  log stdout format raw local0
defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
frontend tls
  bind {s['publicIPv4']}:443
  tcp-request inspect-delay 5s
  acl hello req.ssl_hello_type 1
  acl web req.ssl_sni -i {' '.join(hosts)}
  acl turn req.ssl_sni -i {s['turnHost']}
  tcp-request content reject if hello !web !turn
  tcp-request content accept if hello
  tcp-request content reject if WAIT_END
  use_backend turn if turn
  use_backend web if web
backend web
  server caddy 127.0.0.1:8443 check
backend turn
  server coturn 127.0.0.1:5349 check
"""
    atomic(pub / "haproxy.cfg", haproxy, 0o644)
    limits = s["limits"]

    def service(img, memory, user):
        return {"image": img, "restart": "unless-stopped", "network_mode": "host", "user": user,
                "read_only": True, "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
                "mem_limit": f"{memory}m", "pids_limit": limits["pids"],
                "ulimits": {"nofile": {"soft": limits["nofile"], "hard": limits["nofile"]}},
                "logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}},
                "tmpfs": ["/tmp:rw,noexec,nosuid,size=16m,mode=1777"], "stop_grace_period": "30s"}
    gateway = service(image, limits["gatewayMemoryMiB"], "100:101")
    gateway.update({"env_file": [{"path": protected + "/gateway.env", "format": "raw"}],
                    "volumes": ["gateway-state:/var/lib/dieter-gateway"],
                    "healthcheck": {"test": ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:4243/healthz"], "interval": "15s", "timeout": "3s", "retries": 3}})
    caddy_service = service(deps["caddy"], limits["caddyMemoryMiB"], "0:0")
    caddy_service.update({"cap_add": ["NET_BIND_SERVICE"], "volumes": [install + "/public/Caddyfile:/etc/caddy/Caddyfile:ro",
        s["caddyData"] + ":/data", s["caddyConfig"] + ":/config", s["runtimeRoot"] + ":/run/dieter",
        s["configRoot"] + "/acme-webroot:/acme:ro", certs + ":/certificates:ro"]})
    coturn = service(deps["coturn"], limits["turnMemoryMiB"], "65534:65533")
    coturn.update({"entrypoint": ["turnserver"], "command": ["-c", "/etc/coturn/turnserver.conf"],
                   "volumes": [protected + "/turnserver.conf:/etc/coturn/turnserver.conf:ro", certs + ":/certificates:ro"]})
    if managed and not multiplex:
        coturn["cap_add"] = ["NET_BIND_SERVICE"]
    services = {"dieter-gateway": gateway, "caddy": caddy_service, "coturn": coturn}
    if multiplex:
        proxy = service(deps["haproxy"], limits["haproxyMemoryMiB"], "99:99")
        proxy.update({"cap_add": ["NET_BIND_SERVICE"], "command": ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"],
                      "volumes": [install + "/public/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro"]})
        services["haproxy"] = proxy
    compose = {"name": s["project"], "services": services, "volumes": {"gateway-state": {"external": True, "name": s["stateVolume"]}}}
    atomic(pub / "compose.json", json.dumps(compose, indent=2) + "\n", 0o644)
    atomic(pub / "settings.json", json.dumps(s, indent=2) + "\n", 0o644)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", required=True)
    parser.add_argument("--secrets", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--legacy-caddy")
    a = parser.parse_args()
    render(read_json(a.settings), secrets(a.secrets), a.image, a.release, a.output, a.legacy_caddy)
    print(json.dumps({"rendered": a.release}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as e:
        print(f"Render rejected: {e}", file=sys.stderr)
        sys.exit(1)
