"""netwatch: the desktop's own measurements of every path to the fleet.

  netwatch probe     one active sweep (the netwatch-probe timer): tailnet
                     paths, DNS per resolver, every *.svc host through Caddy
  netwatch passive   the sniffer (netwatch-passive): every real DNS query and
                     every new tailnet TCP connection, timed
  netwatch notify    the user unit: raised flags -> desktop notifications
  netwatch report    summarise the journal: `netwatch report --since -6h`

Every record is one JSON line in the journal, tagged netwatch-probe or
netwatch-passive. A problem is a `flag` record, logged `raised` once at
priority warning and `cleared` once at notice; `notify` turns raised flags
into notifications.
"""

import argparse
import json
import os
import queue
import random
import re
import select
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict, deque

CONFIG_PATH = "@configFile@"

# journald reads a leading <N> on a stdout line as that line's priority.
WARNING, NOTICE, INFO = 4, 5, 6

MAGICDNS = {"100.100.100.100", "fd7a:115c:a1e0::53"}
QTYPES = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX",
          16: "TXT", 28: "AAAA", 33: "SRV", 64: "SVCB", 65: "HTTPS"}
RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN",
          4: "NOTIMP", 5: "REFUSED"}
TCP_SYN, TCP_RST, TCP_ACK = 0x02, 0x04, 0x10


def emit(rec, prio=INFO):
    print(f"<{prio}>" + json.dumps(rec, separators=(",", ":")), flush=True)


def ms(seconds):
    return round(seconds * 1000, 1)


def pct(values, q):
    if not values:
        return None
    v = sorted(values)
    return round(v[min(len(v) - 1, int(q * len(v)))], 1)


def short(host):
    return host.split(".")[0]


def run(cmd, timeout=30):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


# --- DNS wire format -------------------------------------------------------

def dns_query(qid, name, qtype=1):
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    for label in name.rstrip(".").split("."):
        q += bytes([len(label)]) + label.encode()
    return q + b"\x00" + struct.pack(">HH", qtype, 1)


def dns_name(b, off):
    """Read a possibly compressed name; return (name, offset past it)."""
    labels, end, hops = [], None, 0
    while True:
        n = b[off]
        if n & 0xC0 == 0xC0:
            if end is None:
                end = off + 2
            off = ((n & 0x3F) << 8) | b[off + 1]
            hops += 1
            if hops > 30:
                raise ValueError("compression loop")
            continue
        off += 1
        if n == 0:
            break
        labels.append(b[off:off + n].decode("ascii", "replace"))
        off += n
    return ".".join(labels).lower(), (off if end is None else end)


def dns_parse(b):
    """(id, is_response, rcode, qname, qtype, [A/AAAA addresses])."""
    qid, flags, qdcount, ancount, _, _ = struct.unpack(">HHHHHH", b[:12])
    if qdcount < 1:
        raise ValueError("no question")
    qname, off = dns_name(b, 12)
    qtype = struct.unpack(">H", b[off:off + 2])[0]
    off += 4
    addrs = []
    if flags & 0x8000:
        try:
            for _ in range(ancount):
                _, off = dns_name(b, off)
                rtype, _, _, rdlen = struct.unpack(">HHIH", b[off:off + 10])
                off += 10
                rdata = b[off:off + rdlen]
                off += rdlen
                if rtype == 1 and rdlen == 4:
                    addrs.append(socket.inet_ntop(socket.AF_INET, rdata))
                elif rtype == 28 and rdlen == 16:
                    addrs.append(socket.inet_ntop(socket.AF_INET6, rdata))
        except (IndexError, struct.error, ValueError):
            pass  # cut by the snap length; keep what parsed
    return (qid, bool(flags & 0x8000), RCODES.get(flags & 0xF, str(flags & 0xF)),
            qname, QTYPES.get(qtype, str(qtype)), addrs)


def dns_exchange(server, names, rate, timeout=2.0):
    """One query per name, paced at `rate` per second, straight to `server`.

    Returns [(name, ms or None if lost, rcode, addrs)] in send order.
    """
    fam = socket.AF_INET6 if ":" in server else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_DGRAM)
    s.setblocking(False)
    sent, got = {}, {}
    start = time.monotonic()
    deadline = start + (len(names) - 1) / rate + timeout
    i = 0
    while True:
        now = time.monotonic()
        if i < len(names) and now >= start + i / rate:
            qid = random.randrange(65536)
            while qid in sent:
                qid = random.randrange(65536)
            sent[qid] = (names[i], now)
            try:
                s.sendto(dns_query(qid, names[i]), (server, 53))
            except OSError:
                pass  # counted as lost
            i += 1
        if i == len(names) and (len(got) == len(sent) or now > deadline):
            break
        r, _, _ = select.select([s], [], [], 0.005)
        if not r:
            continue
        try:
            qid, resp, rcode, _, _, addrs = dns_parse(s.recv(4096))
        except (OSError, IndexError, struct.error, ValueError):
            continue
        if resp and qid in sent and qid not in got:
            got[qid] = (ms(time.monotonic() - sent[qid][1]), rcode, addrs)
    s.close()
    return [(name, *got.get(qid, (None, None, [])))
            for qid, (name, _) in sent.items()]


# --- tailnet ---------------------------------------------------------------

def peer_name(p):
    return p.get("HostName") or (p.get("DNSName") or "?").split(".")[0]


def ts_status(cfg):
    st = json.loads(run([cfg["tools"]["tailscale"], "status", "--json"]).stdout)
    return st.get("Self") or {}, {peer_name(p): p for p in (st.get("Peer") or {}).values()}


PONG = re.compile(r"pong from \S+ \(([^)]+)\) via (\S+) in ([\d.]+)ms")


def ts_ping(cfg, peer, count=3):
    """[(via, ms)] — via is `ip:port` when direct, `DERP(region)` when relayed."""
    try:
        out = run([cfg["tools"]["tailscale"], "ping", "-c", str(count),
                   "--until-direct=false", "--timeout", "3s", peer], timeout=30).stdout
    except subprocess.TimeoutExpired:
        return []
    return [(via, float(t)) for _, via, t in PONG.findall(out)]


def ipv4(p):
    return next((ip for ip in p.get("TailscaleIPs") or [] if ":" not in ip), None)


# --- Caddyfile -------------------------------------------------------------

def caddy_hosts(path, domain):
    """{host: "host" | "path" | None}: where `import protected` (forward auth
    to the Authentik outpost on the VPS) applies to each *.domain host."""
    with open(path) as f:
        text = f.read()
    matchers = dict(re.findall(r"^\s*@(\S+)\s+host\s+(\S+)\s*$", text, re.M))
    hosts = {h: None for h in matchers.values() if h.endswith("." + domain)}
    stack = []
    for raw in text.splitlines():
        line = re.sub(r"(^|\s)#.*$", "", raw)
        if re.match(r"\s*import\s+protected\s*$", line):
            for depth, frame in enumerate(reversed(stack)):
                host = matchers.get(frame or "")
                if host in hosts:
                    if depth == 0:
                        hosts[host] = "host"
                    elif hosts[host] is None:
                        hosts[host] = "path"
                    break
        handle = re.match(r"\s*handle\s+@(\S+)\s*\{\s*$", line)
        for ch in line:
            if ch == "{":
                stack.append(handle.group(1) if handle else None)
            elif ch == "}" and stack:
                stack.pop()
    return hosts


# --- probe -----------------------------------------------------------------

def curl_probe(cfg, url, jar, resolve=None):
    cmd = [cfg["tools"]["curl"], "-s", "-o", "/dev/null", "-A", "netwatch-probe",
           "--max-time", "10", "--connect-timeout", "5",
           "-b", jar, "-c", jar, "-w", "%{json}"]
    if resolve:
        cmd += ["--resolve", resolve]
    try:
        j = json.loads(run(cmd + [url], timeout=20).stdout or "{}")
    except (subprocess.TimeoutExpired, ValueError):
        j = {"exitcode": -1, "errormsg": "curl hung"}
    nl, co = j.get("time_namelookup", 0), j.get("time_connect", 0)
    tls, ttfb = j.get("time_appconnect", 0), j.get("time_starttransfer", 0)
    return {
        "code": j.get("http_code", 0),
        "error": (j.get("errormsg") or "curl failed") if j.get("exitcode") else None,
        "fwd_auth": "outpost.goauthentik.io" in (j.get("redirect_url") or ""),
        "remote_ip": j.get("remote_ip"),
        "dns_ms": ms(nl),
        "connect_ms": ms(max(co - nl, 0)),
        "tls_ms": ms(max(tls - co, 0)),
        "server_ms": ms(max(ttfb - tls, 0)),
        "total_ms": ms(j.get("time_total", 0)),
    }


def probe(cfg):
    th = cfg["thresholds"]
    state_dir = os.environ.get("STATE_DIRECTORY") or cfg["state_dir"]
    state_path = os.path.join(state_dir, "state.json")
    state = load_json(state_path, {})
    for k, v in (("run", 0), ("flags", {}), ("pending", {}), ("bytes", {}), ("host_ip", {})):
        state.setdefault(k, v)
    state["run"] += 1
    run_no = state["run"]
    t0 = time.monotonic()
    found, immediate, checked = {}, set(), set()

    # 1. Tailnet paths. A *.svc request is one hop to services-vm; anything
    #    relayed through DERP crosses the VPS on the way.
    checked |= {"tailnet", "relayed"}
    try:
        _, peers = ts_status(cfg)
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        peers = {}
        found["tailnet:status"] = f"tailscale status failed: {e}"
    rtt = {}
    for name in (cfg["services_peer"], cfg["vps_peer"]):
        p = peers.get(name)
        if p is None:
            found[f"tailnet:{name}"] = f"{name} is missing from the tailnet map"
            continue
        pongs = ts_ping(cfg, name)
        via = pongs[-1][0] if pongs else None
        path = None if via is None else ("derp" if via.startswith("DERP") else "direct")
        if pongs:
            rtt[name] = min(t for _, t in pongs)
        prev = state["bytes"].get(name, {})
        rx, tx = p.get("RxBytes", 0), p.get("TxBytes", 0)
        state["bytes"][name] = {"rx": rx, "tx": tx}
        emit({"kind": "tailnet", "peer": name, "ip": ipv4(p), "online": p.get("Online"),
              "path": path, "via": via, "cur_addr": p.get("CurAddr") or None,
              "relay": p.get("Relay"), "ping_ms": [t for _, t in pongs],
              "rx_delta": rx - prev["rx"] if prev and rx >= prev["rx"] else None,
              "tx_delta": tx - prev["tx"] if prev and tx >= prev["tx"] else None})
        if not pongs:
            found[f"tailnet:{name}"] = f"{name} does not answer tailscale ping (online={p.get('Online')})"
        elif name in cfg["expect_direct"] and path != "direct":
            found[f"relayed:{name}"] = (
                f"desktop -> {name} is relayed via {via} ({rtt[name]:.0f} ms), not direct: "
                f"every *.{cfg['domain']} request crosses the VPS")
    svc_ip = ipv4(peers.get(cfg["services_peer"], {}))
    vps_ip = ipv4(peers.get(cfg["vps_peer"], {}))
    vps_rtt = rtt.get(cfg["vps_peer"])

    # 2. DNS, per resolver. The names live under probe_name so the sniffer
    #    and AdGuard's query log can tell them apart from real lookups.
    checked |= {"dns-loss", "dns-slow", "svc-dns"}
    pname = cfg["probe_name"]
    for label, server in cfg["resolvers"].items():
        names = [pname] * 5 + [f"nw-{random.getrandbits(32):08x}.{pname}" for _ in range(2)]
        res = dns_exchange(server, names, rate=20)
        lost = sum(1 for r in res if r[1] is None)
        cached = [r[1] for r in res if r[0] == pname and r[1] is not None]
        uncached = [r[1] for r in res if r[0] != pname and r[1] is not None]
        answers = sorted({a for r in res for a in r[3] if ":" not in a})
        emit({"kind": "dns", "resolver": label, "server": server, "sent": len(res), "lost": lost,
              "cached_p50_ms": pct(cached, 0.5), "cached_max_ms": max(cached, default=None),
              "uncached_max_ms": max(uncached, default=None),
              "rcodes": dict(Counter(r[2] for r in res if r[2])), "answers": answers})
        if lost:
            found[f"dns-loss:{label}"] = f"{label} ({server}) dropped {lost}/{len(res)} paced queries"
        if cached and pct(cached, 0.5) > th["dns_slow_ms"]:
            found[f"dns-slow:{label}"] = f"{label} ({server}) answers cached names in {pct(cached, 0.5):.0f} ms"
        if svc_ip and answers and answers != [svc_ip]:
            found[f"svc-dns:{label}"] = f"{label} resolves *.{cfg['domain']} to {answers}, not services-vm {svc_ip}"
            immediate.add(f"svc-dns:{label}")

    if run_no % cfg["burst_every"] == 1 or cfg["burst_every"] == 1:
        checked.add("dns-ratelimit")
        label = cfg["burst_resolver"]
        res = dns_exchange(cfg["resolvers"][label], [pname] * 50, rate=100)
        lost = sum(1 for r in res if r[1] is None)
        emit({"kind": "dns-burst", "resolver": label, "sent": len(res), "lost": lost, "qps": 100,
              "max_ms": max((r[1] for r in res if r[1] is not None), default=None)})
        if lost >= 3:
            found[f"dns-ratelimit:{label}"] = (
                f"{label} dropped {lost}/50 queries in a 100 qps burst: a per-client rate limit "
                "is back (AdGuard: Settings > DNS settings > Rate limit = 0)")

    # 3. Every *.svc host through Caddy, as named in the Caddyfile.
    hosts = {h: w for h, w in caddy_hosts(cfg["caddyfile"], cfg["domain"]).items()
             if short(h) not in cfg["ignore_hosts"]}
    if run_no % cfg["hosts_dns_every"] == 1 or not state["host_ip"]:
        checked.add("svc-dns-host")
        res = dns_exchange(cfg["resolvers"]["magicdns"], sorted(hosts), rate=20)
        wrong = {}
        for name, _, _, addrs in res:
            v4 = [a for a in addrs if ":" not in a]
            if v4:
                state["host_ip"][name] = v4[0]
            if svc_ip and v4 and v4 != [svc_ip]:
                wrong[short(name)] = v4
        emit({"kind": "dns-hosts", "checked": len(res),
              "lost": sum(1 for r in res if r[1] is None), "wrong": wrong})
        for name, v4 in wrong.items():
            found[f"svc-dns-host:{name}"] = f"{name}.{cfg['domain']} resolves to {v4}, not services-vm {svc_ip}"
            immediate.add(f"svc-dns-host:{name}")

    checked |= {"http-fail", "http-5xx", "fwdauth-drift", "fwdauth-slow", "slow-or-hop", "auth"}
    # A server time this close to the VPS round trip, on a host with no forward
    # auth, is the signature of a request that waited on the VPS.
    hop_ms = max(th["hop_floor_ms"], th["hop_fraction"] * vps_rtt) if vps_rtt else 2 * th["hop_floor_ms"]
    jars = os.path.join(state_dir, "jars")
    os.makedirs(jars, exist_ok=True)
    issues = defaultdict(dict)
    server_fa, server_direct = [], []
    for host, where in sorted(hosts.items()):
        name = short(host)
        ip = state["host_ip"].get(host) or svc_ip
        # One cookie jar per host: Authentik's outpost then reuses one session
        # instead of minting one per unauthenticated hit.
        url, jar = f"https://{host}/", os.path.join(jars, name)
        resolve = f"{host}:443:{ip}" if ip else None
        samples = [curl_probe(cfg, url, jar, resolve)]
        r = samples[0]
        expect = where == "host"
        rec = {"kind": "http", "host": name, "code": r["code"], "fwd_auth": r["fwd_auth"],
               "expect_fwd_auth": expect, "ip": r["remote_ip"]}
        if r["error"]:
            emit(rec | {"error": r["error"]}, NOTICE)
            issues["http-fail"][name] = f"{name}: {r['error']}"
            continue
        limit = (vps_rtt or hop_ms) + th["fwd_auth_extra_ms"] if r["fwd_auth"] else hop_ms
        for _ in range(2 if r["server_ms"] >= limit else 0):
            time.sleep(0.5)  # step out of a momentary burst on the VM
            samples.append(curl_probe(cfg, url, jar, resolve))
        ok = [s for s in samples if not s["error"]]
        server = min(s["server_ms"] for s in ok)
        (server_fa if r["fwd_auth"] else server_direct).append(server)
        best = min(ok, key=lambda s: s["server_ms"])
        rec |= {k: best[k] for k in ("connect_ms", "tls_ms", "server_ms", "total_ms")}
        rec["samples"] = len(samples)
        if vps_rtt:
            rec["server_in_vps_rtts"] = round(server / vps_rtt, 2)
        emit(rec)
        if r["code"] >= 500:
            issues["http-5xx"][name] = f"{name}: HTTP {r['code']}"
        if r["fwd_auth"] != expect:
            issues["fwdauth-drift"][name] = (
                f"{name}: forward auth is {'ON' if r['fwd_auth'] else 'OFF'} at /, "
                f"but the Caddyfile has it {'on the host' if expect else 'off'}")
        if server >= limit:
            if r["fwd_auth"]:
                issues["fwdauth-slow"][name] = (
                    f"{name}: the forward-auth answer took {server:.0f} ms "
                    f"(VPS RTT {vps_rtt or 0:.0f} ms): Authentik's outpost is slow")
            else:
                times = f" = {server / vps_rtt:.1f}x the VPS RTT" if vps_rtt else ""
                issues["slow-or-hop"][name] = (
                    f"{name}: {server:.0f} ms server time with no forward auth{times}: "
                    "the app is slow, or it waits on the VPS before answering")
    for kind, by_host in issues.items():
        if len(by_host) > th["aggregate_over"]:
            found[f"{kind}:many"] = f"{len(by_host)} hosts: " + ", ".join(sorted(by_host))
        else:
            for name, msg in by_host.items():
                found[f"{kind}:{name}"] = msg

    # 4. Authentik itself, the far end of every forward-auth hop and login.
    a = curl_probe(cfg, cfg["auth_url"], os.path.join(jars, "_auth"))
    emit({"kind": "auth", "url": cfg["auth_url"], "code": a["code"], "error": a["error"],
          "ip": a["remote_ip"], "connect_ms": a["connect_ms"], "tls_ms": a["tls_ms"],
          "server_ms": a["server_ms"], "total_ms": a["total_ms"]})
    if a["error"] or not 200 <= a["code"] < 300:
        found["auth:down"] = f"{cfg['auth_url']}: {a['error'] or 'HTTP %s' % a['code']}"
    elif vps_ip and a["remote_ip"] != vps_ip:
        found["auth:path"] = (f"auth reached at {a['remote_ip']}, not the VPS tailnet IP {vps_ip}: "
                              "logins leave the tailnet")
    elif a["server_ms"] > th["auth_slow_ms"]:
        found["auth:slow"] = f"Authentik took {a['server_ms']:.0f} ms to answer its health check"

    emit({"kind": "run", "run": run_no, "duration_s": round(time.monotonic() - t0, 1),
          "vps_rtt_ms": vps_rtt, "svc_ip": svc_ip, "hosts": len(hosts),
          "fwd_auth_server_p50_ms": pct(server_fa, 0.5),
          "no_fwd_auth_server_p50_ms": pct(server_direct, 0.5),
          "found": sorted(found)})
    settle_flags(state, found, immediate, checked, th["raise_after_runs"])
    tmp = state_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, state_path)


def settle_flags(state, found, immediate, checked, raise_after):
    """Raise a flag after `raise_after` consecutive runs (one transient run
    after a resume is not a problem); clear it the first run it is not seen."""
    now = time.time()
    for key, msg in found.items():
        if key in state["flags"]:
            continue
        n = state["pending"].get(key, 0) + 1
        if n >= raise_after or key in immediate:
            state["pending"].pop(key, None)
            state["flags"][key] = {"since": now, "msg": msg}
            emit({"kind": "flag", "event": "raised", "key": key, "msg": msg}, WARNING)
        else:
            state["pending"][key] = n
    for key in list(state["pending"]):
        if key not in found:
            del state["pending"][key]
    for key, f in list(state["flags"].items()):
        if key not in found and key.split(":")[0] in checked:
            emit({"kind": "flag", "event": "cleared", "key": key, "msg": f["msg"],
                  "lasted_s": round(now - f["since"])}, NOTICE)
            del state["flags"][key]


# --- passive ---------------------------------------------------------------

def strip_link(linktype, data):
    """The IP packet inside one captured frame, or None."""
    if linktype == 1:  # Ethernet
        off, etype = 14, struct.unpack(">H", data[12:14])[0]
        if etype == 0x8100:
            off, etype = 18, struct.unpack(">H", data[16:18])[0]
        return data[off:] if etype in (0x0800, 0x86DD) else None
    if linktype in (12, 14, 101, 228, 229):  # raw IP (tailscale0)
        return data
    if linktype == 113:  # Linux cooked v1
        return data[16:]
    if linktype == 276:  # Linux cooked v2
        return data[20:]
    return None


def pcap_records(stream):
    """(timestamp, ip packet) from a pcap byte stream."""
    hdr = stream.read(24)
    if len(hdr) < 24:
        return
    magic = hdr[:4]
    endian = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    scale = 1e9 if magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d") else 1e6
    linktype = struct.unpack(endian + "I", hdr[20:24])[0] & 0xFFFF
    while True:
        rh = stream.read(16)
        if len(rh) < 16:
            return
        sec, frac, incl, _ = struct.unpack(endian + "IIII", rh)
        data = stream.read(incl)
        if len(data) < incl:
            return
        l3 = strip_link(linktype, data)
        if l3:
            yield sec + frac / scale, l3


def parse_ip(b):
    v = b[0] >> 4
    if v == 4:
        ihl = (b[0] & 0x0F) * 4
        return (b[9], socket.inet_ntop(socket.AF_INET, b[12:16]),
                socket.inet_ntop(socket.AF_INET, b[16:20]), b[ihl:])
    if v == 6:
        return (b[6], socket.inet_ntop(socket.AF_INET6, b[8:24]),
                socket.inet_ntop(socket.AF_INET6, b[24:40]), b[40:])
    raise ValueError("not IP")


class Passive:
    def __init__(self, cfg):
        self.cfg, self.th = cfg, cfg["thresholds"]
        self.resolver_names = {v: k for k, v in cfg["resolvers"].items()}
        self.dns_pending = {}   # (client, port, server, id) -> (t, qname, qtype, layer)
        self.syn_pending = {}   # (src, sport, dst, dport) -> [t, retransmits]
        self.dns_lat = defaultdict(list)
        self.dns_lost = Counter()
        self.dns_rcode = defaultdict(Counter)
        self.conn_rtt = defaultdict(list)
        self.conn_fail = Counter()
        self.events = defaultdict(deque)  # flag key -> event times in the window
        self.detail = {}
        self.flags = {}
        self.peers, self.local, self.svc_ip = {}, set(), None
        self.minute = None
        self.next_eval = 0
        self.peers_at = 0

    def refresh_peers(self):
        try:
            me, peers = ts_status(self.cfg)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return
        self.peers = {ip: name for name, p in peers.items() for ip in p.get("TailscaleIPs") or []}
        self.local = set(me.get("TailscaleIPs") or [])
        self.svc_ip = ipv4(peers.get(self.cfg["services_peer"], {}))
        self.peers_at = time.monotonic()

    def layer(self, server):
        if server in MAGICDNS:
            return "magicdns"
        return self.resolver_names.get(server, f"dns:{server}")

    def packet(self, t, l3):
        try:
            proto, src, dst, p = parse_ip(l3)
            if proto == 17 and len(p) >= 8:
                sport, dport = struct.unpack(">HH", p[:4])
                if 53 in (sport, dport):
                    self.dns(t, src, sport, dst, dport, p[8:])
            elif proto == 6 and len(p) >= 14:
                sport, dport = struct.unpack(">HH", p[:4])
                self.tcp(t, src, sport, dst, dport, p[13])
        except (IndexError, struct.error, ValueError, OSError):
            return

    def dns(self, t, src, sport, dst, dport, payload):
        qid, resp, rcode, qname, qtype, addrs = dns_parse(payload)
        pname = self.cfg["probe_name"]
        if qname == pname or qname.endswith("." + pname):
            return  # the probe's own synthetic lookups
        if not resp and dport == 53:
            # A client's retransmit reuses the id and port: keep the first
            # send time, so the latency is the whole wait.
            self.dns_pending.setdefault((src, sport, dst, qid), (t, qname, qtype, self.layer(dst)))
            return
        if not (resp and sport == 53):
            return
        q = self.dns_pending.pop((dst, dport, src, qid), None)
        if q is None:
            return
        t0, qname, qtype, layer = q
        lat = ms(t - t0)
        self.dns_lat[layer].append(lat)
        self.dns_rcode[layer][rcode] += 1
        if lat >= self.th["dns_slow_ms"]:
            emit({"kind": "dns-slow", "layer": layer, "server": src, "qname": qname,
                  "qtype": qtype, "ms": lat, "rcode": rcode})
            if lat >= self.th["dns_stall_ms"]:
                self.event(t, f"dns-stall:{layer}", f"{qname} {qtype} took {lat:.0f} ms")
        v4 = [a for a in addrs if ":" not in a]
        if (qtype == "A" and v4 and self.svc_ip and qname.endswith("." + self.cfg["domain"])
                and v4 != [self.svc_ip]):
            emit({"kind": "dns-wrong", "layer": layer, "qname": qname, "answers": v4,
                  "expected": self.svc_ip}, NOTICE)
            self.event(t, "svc-dns:passive", f"{qname} -> {v4}, not services-vm {self.svc_ip}")

    def tcp(self, t, src, sport, dst, dport, flags):
        if flags & TCP_SYN and not flags & TCP_ACK and src in self.local:
            key = (src, sport, dst, dport)
            if key in self.syn_pending:
                self.syn_pending[key][1] += 1
            else:
                self.syn_pending[key] = [t, 0]
        elif dst in self.local and flags & (TCP_SYN | TCP_RST):
            s = self.syn_pending.pop((dst, dport, src, sport), None)
            if s is None:
                return
            peer = self.peers.get(src, src)
            if flags & TCP_RST:
                self.conn_failed(t, peer, sport, "reset")
                return
            rtt = ms(t - s[0])
            self.conn_rtt[peer].append(rtt)
            if peer in self.cfg["log_each_conn"]:
                emit({"kind": "conn", "peer": peer, "port": sport, "handshake_ms": rtt,
                      "syn_retransmits": s[1]})
            if peer in self.cfg["expect_direct"] and rtt > self.th["direct_handshake_ms"]:
                emit({"kind": "conn-slow", "peer": peer, "port": sport, "handshake_ms": rtt,
                      "syn_retransmits": s[1]}, NOTICE)
                self.event(t, f"relayed-handshake:{peer}", f"handshake to {peer}:{sport} took {rtt:.0f} ms")

    def conn_failed(self, t, peer, port, why):
        self.conn_fail[peer] += 1
        emit({"kind": "conn-fail", "peer": peer, "port": port, "why": why}, NOTICE)
        self.event(t, f"tcp-fail:{peer}", f"{peer}:{port} {why}")

    def event(self, t, key, detail):
        self.events[key].append(t)
        self.detail[key] = detail

    def tick(self, now):
        if time.monotonic() - self.peers_at > 300:
            self.refresh_peers()
        for key, (t0, qname, qtype, layer) in list(self.dns_pending.items()):
            if now - t0 > 5:
                del self.dns_pending[key]
                self.dns_lost[layer] += 1
                emit({"kind": "dns-lost", "layer": layer, "server": key[2], "qname": qname,
                      "qtype": qtype}, NOTICE)
                flag = "dns-stall:magicdns" if layer == "magicdns" else f"dns-loss:{layer}"
                self.event(now, flag, f"{qname} {qtype} to {key[2]} never answered")
        for key, (t0, _) in list(self.syn_pending.items()):
            if now - t0 > 10:
                del self.syn_pending[key]
                self.conn_failed(now, self.peers.get(key[2], key[2]), key[3], "timeout")
        minute = int(now // 60)
        if self.minute is None:
            self.minute = minute
        elif minute != self.minute:
            self.flush()
            self.minute = minute
        if now >= self.next_eval:
            self.evaluate(now)
            self.next_eval = now + 60

    def flush(self):
        for layer in sorted(set(self.dns_lat) | set(self.dns_lost)):
            lat = self.dns_lat[layer]
            emit({"kind": "dns-minute", "layer": layer, "queries": len(lat) + self.dns_lost[layer],
                  "lost": self.dns_lost[layer], "p50_ms": pct(lat, 0.5), "p95_ms": pct(lat, 0.95),
                  "max_ms": max(lat, default=None), "rcodes": dict(self.dns_rcode[layer])})
        for peer in sorted(set(self.conn_rtt) | set(self.conn_fail)):
            rtts = self.conn_rtt[peer]
            emit({"kind": "conn-minute", "peer": peer, "conns": len(rtts),
                  "failed": self.conn_fail[peer], "p50_ms": pct(rtts, 0.5),
                  "max_ms": max(rtts, default=None)})
        self.dns_lat.clear()
        self.dns_lost.clear()
        self.dns_rcode.clear()
        self.conn_rtt.clear()
        self.conn_fail.clear()

    def evaluate(self, now):
        window = self.th["passive_window_s"]
        current = {}
        for key, times in self.events.items():
            while times and now - times[0] > window:
                times.popleft()
            need = 1 if key.startswith("svc-dns") else self.th["passive_raise_count"]
            if len(times) >= need:
                current[key] = len(times)
        mins = window // 60
        for key, n in current.items():
            if key in self.flags:
                continue
            what = {
                "dns-loss": f"{n} lookups to this resolver went unanswered in {mins} min",
                "dns-stall": f"{n} lookups stalled >= {self.th['dns_stall_ms']} ms or never returned in {mins} min",
                "tcp-fail": f"{n} TCP connections failed in {mins} min",
                "relayed-handshake": f"{n} handshakes took > {self.th['direct_handshake_ms']} ms in {mins} min: real traffic is relayed, not direct",
                "svc-dns": "a *.svc name resolved away from services-vm",
            }.get(key.split(":")[0], f"{n} events in {mins} min")
            msg = f"{key}: {what} (last: {self.detail.get(key)})"
            self.flags[key] = (now, msg)
            emit({"kind": "flag", "event": "raised", "key": key, "msg": msg}, WARNING)
        for key, (since, msg) in list(self.flags.items()):
            if key not in current:
                emit({"kind": "flag", "event": "cleared", "key": key, "msg": msg,
                      "lasted_s": round(now - since)}, NOTICE)
                del self.flags[key]


def passive(cfg, replay=None):
    pv = Passive(cfg)
    pv.refresh_peers()
    if replay:
        t = 0
        with open(replay, "rb") as f:
            for t, l3 in pcap_records(f):
                pv.packet(t, l3)
                pv.tick(t)
        for later in (15, 75, 135):
            pv.tick(t + later)
        return
    lan = run([cfg["tools"]["ip"], "-o", "route", "get", cfg["resolvers"]["adguard"]]).stdout.split()
    lan_if = lan[lan.index("dev") + 1]
    captures = {
        "tailscale0": "udp port 53 or (tcp[tcpflags] & (tcp-syn|tcp-rst) != 0)",
        lan_if: "udp port 53",
    }
    q = queue.Queue(maxsize=100000)
    procs = []
    for ifc, bpf in captures.items():
        p = subprocess.Popen([cfg["tools"]["tcpdump"], "-i", ifc, "-p", "-n", "-U", "-s", "512",
                              "-w", "-", bpf], stdout=subprocess.PIPE)
        procs.append(p)
        threading.Thread(target=lambda s=p.stdout: [q.put(r) for r in pcap_records(s)],
                         daemon=True).start()
    emit({"kind": "passive-start", "interfaces": list(captures), "svc_ip": pv.svc_ip,
          "local": sorted(pv.local)})
    while True:
        try:
            t, l3 = q.get(timeout=1)
            pv.packet(t, l3)
        except queue.Empty:
            pass
        pv.tick(time.time())
        for p in procs:
            if p.poll() is not None:
                emit({"kind": "passive-exit", "why": f"tcpdump exited {p.returncode}"}, WARNING)
                sys.exit(1)


# --- notify ----------------------------------------------------------------

def notify(cfg):
    cmd = [cfg["tools"]["journalctl"], "-f", "-n", "0", "-o", "json", "-p", "warning",
           "-t", "netwatch-probe", "-t", "netwatch-passive"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(ln) for ln in p.stdout], daemon=True).start()
    last, batch, due = {}, [], None
    while p.poll() is None:
        try:
            m = json.loads(json.loads(lines.get(timeout=1))["MESSAGE"])
            if (m.get("kind") == "flag" and m.get("event") == "raised"
                    and time.time() - last.get(m["key"], 0) > cfg["thresholds"]["notify_repeat_s"]):
                last[m["key"]] = time.time()
                batch.append(m)
                due = due or time.time() + 3
        except (queue.Empty, ValueError, KeyError, TypeError):
            pass
        if batch and time.time() >= due:
            title = batch[0]["key"] if len(batch) == 1 else f"{len(batch)} network issues"
            body = "\n".join(m["msg"] for m in batch) + "\n\nnetwatch report --since -1h"
            run([cfg["tools"]["notify_send"], "-a", "netwatch", "-u", "critical",
                 "-i", "network-error", f"netwatch: {title}", body])
            batch, due = [], None
    sys.exit(1)


# --- report ----------------------------------------------------------------

def report(cfg, since):
    out = run([cfg["tools"]["journalctl"], "-o", "json", "--no-pager", "--since", since,
               "-t", "netwatch-probe", "-t", "netwatch-passive"], timeout=120).stdout
    recs = []
    for line in out.splitlines():
        try:
            e = json.loads(line)
            m = json.loads(e["MESSAGE"])
        except (ValueError, KeyError, TypeError):
            continue
        if isinstance(m, dict):
            recs.append((int(e["__REALTIME_TIMESTAMP"]) / 1e6, e.get("SYSLOG_IDENTIFIER", "?"), m))
    if not recs:
        print(f"no netwatch records since {since}")
        return

    def when(t):
        return time.strftime("%m-%d %H:%M", time.localtime(t))

    def of(kind):
        return [(t, m) for t, _, m in recs if m.get("kind") == kind]

    print(f"netwatch, {when(recs[0][0])} -> {when(recs[-1][0])}, {len(of('run'))} probe runs")

    print("\n== flags")
    flags = [(t, src, m) for t, src, m in recs if m.get("kind") == "flag"]
    for t, src, m in flags:
        dur = f" after {m['lasted_s'] // 60} min" if "lasted_s" in m else ""
        print(f"  {when(t)} {m['event'].upper():7} {m['key']}{dur}  [{src.split('-')[1]}]\n      {m['msg']}")
    if not flags:
        print("  none")

    print("\n== tailnet paths (probe: tailscale ping)")
    by_peer = defaultdict(list)
    for t, m in of("tailnet"):
        by_peer[m["peer"]].append((t, m))
    for peer, rows in by_peer.items():
        pings = [min(m["ping_ms"]) for _, m in rows if m["ping_ms"]]
        paths = Counter(m["path"] for _, m in rows)
        changes, last = [], None
        for t, m in rows:
            if m["path"] != last and last is not None:
                changes.append(f"{when(t)} {last}->{m['path']}")
            last = m["path"]
        rx = sum(m["rx_delta"] or 0 for _, m in rows)
        tx = sum(m["tx_delta"] or 0 for _, m in rows)
        print(f"  {peer:15} paths {dict(paths)}  ping p50 {pct(pings, .5)} max {max(pings, default=None)} ms"
              f"  traffic rx {rx / 1e6:.1f} MB tx {tx / 1e6:.1f} MB")
        for c in changes[-8:]:
            print(f"      {c}")

    print("\n== DNS, probe (paced, straight to each resolver)")
    by_res = defaultdict(list)
    for _, m in of("dns"):
        by_res[m["resolver"]].append(m)
    for res, rows in by_res.items():
        sent, lost = sum(m["sent"] for m in rows), sum(m["lost"] for m in rows)
        p50s = [m["cached_p50_ms"] for m in rows if m["cached_p50_ms"] is not None]
        unc = [m["uncached_max_ms"] for m in rows if m["uncached_max_ms"] is not None]
        print(f"  {res:9} lost {lost}/{sent}  cached p50 {pct(p50s, .5)} ms  uncached p50 {pct(unc, .5)} max {max(unc, default=None)} ms")
    bursts = of("dns-burst")
    if bursts:
        print(f"  bursts: {len(bursts)} x 50 queries at 100 qps, lost {sum(m['lost'] for _, m in bursts)} total")

    print("\n== DNS, real traffic (passive)")
    by_layer = defaultdict(lambda: Counter())
    worst = defaultdict(list)
    for _, m in of("dns-minute"):
        c = by_layer[m["layer"]]
        c["queries"] += m["queries"]
        c["lost"] += m["lost"]
        worst[m["layer"]].append(m["max_ms"] or 0)
    slow = Counter((m["layer"], m["qname"]) for _, m in of("dns-slow"))
    lost = Counter((m["layer"], m["qname"]) for _, m in of("dns-lost"))
    for layer, c in by_layer.items():
        nslow = sum(n for (lay, _), n in slow.items() if lay == layer)
        print(f"  {layer:9} {c['queries']} queries, {c['lost']} lost, {nslow} >= {cfg['thresholds']['dns_slow_ms']} ms, worst {max(worst[layer], default=0):.0f} ms")
    for title, ctr in (("slowest names", slow), ("lost names", lost)):
        if ctr:
            print(f"  {title}: " + ", ".join(f"{q} [{lay}] x{n}" for (lay, q), n in ctr.most_common(6)))

    print("\n== HTTP, probe (server time = TLS done -> first byte: Caddy + forward auth + app)")
    by_host = defaultdict(list)
    for _, m in of("http"):
        if "server_ms" in m:
            by_host[m["host"]].append(m)
    rows = sorted(by_host.items(), key=lambda kv: -statistics.median(m["server_ms"] for m in kv[1]))
    vps = [m["vps_rtt_ms"] for _, m in of("run") if m.get("vps_rtt_ms")]
    fa_rows = [(h, r) for h, r in rows if r[-1]["fwd_auth"]]
    fa_p50 = [pct([m["server_ms"] for m in r], .5) for _, r in fa_rows]
    print(f"  VPS RTT p50 {pct(vps, .5)} ms. {len(fa_rows)} forward-auth hosts pay one VPS RTT per request:"
          f" their server time p50 {pct(fa_p50, .5)}, worst host p50 {max(fa_p50, default=None)} ms")

    def line(host, ms_rows):
        s = [m["server_ms"] for m in ms_rows]
        print(f"    {host:18} p50 {pct(s, .5):7} p95 {pct(s, .95):7} max {max(s):7} ms  (n={len(s)})")
    print("  no forward auth, slowest first (should sit well under one VPS RTT):")
    for host, ms_rows in [(h, r) for h, r in rows if not r[-1]["fwd_auth"]][:15]:
        line(host, ms_rows)
    if fa_rows:
        print("  forward auth, slowest first:")
        for host, ms_rows in fa_rows[:5]:
            line(host, ms_rows)
    fails = Counter(m["host"] for _, m in of("http") if m.get("error"))
    if fails:
        print("  failures: " + ", ".join(f"{h} x{n}" for h, n in fails.most_common()))
    auth = [m["server_ms"] for _, m in of("auth") if not m.get("error")]
    print(f"  auth health: p50 {pct(auth, .5)} p95 {pct(auth, .95)} ms server time")

    print("\n== new connections from this desktop (passive)")
    conns = defaultdict(lambda: [0, 0, []])
    for _, m in of("conn-minute"):
        c = conns[m["peer"]]
        c[0] += m["conns"]
        c[1] += m["failed"]
        c[2].append(m["max_ms"] or 0)
    for peer, (n, failed, mx) in sorted(conns.items()):
        print(f"  {peer:15} {n} conns, {failed} failed, worst handshake {max(mx, default=0):.0f} ms")
    to_vps = Counter(time.strftime("%H:00", time.localtime(t)) for t, m in of("conn"))
    if to_vps:
        print(f"  to {cfg['vps_peer']} by hour: " + ", ".join(f"{h} {n}" for h, n in sorted(to_vps.items())))


def main():
    ap = argparse.ArgumentParser(prog="netwatch", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=CONFIG_PATH)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("probe")
    pp = sub.add_parser("passive")
    pp.add_argument("--replay", help="read packets from a pcap file instead of capturing")
    sub.add_parser("notify")
    rp = sub.add_parser("report")
    rp.add_argument("--since", default="-24h", help="journalctl --since (default -24h)")
    args = ap.parse_args()
    with open(args.config) as f:
        cfg = json.load(f)
    {"probe": lambda: probe(cfg),
     "passive": lambda: passive(cfg, args.replay),
     "notify": lambda: notify(cfg),
     "report": lambda: report(cfg, args.since)}[args.cmd]()


if __name__ == "__main__":
    main()
