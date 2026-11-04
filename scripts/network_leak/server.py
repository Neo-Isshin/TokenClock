#!/usr/bin/env python3
"""TokenClock's bounded, in-memory DNS/STUN observations. No recursive DNS or media relay."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import secrets
import socket
import socketserver
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ZONE = "probe.tokenclock.ailyre.com"
NS = "ns.tokenclock.ailyre.com"
ROOT = "/tokenclock/network-check"
COOKIE = 0x2112A442
TOKEN = re.compile(r"^[0-9a-f]{32}$")
# Cloudflare's published proxy ranges. Only a trusted edge may supply the
# original client address; direct-origin visitors cannot spoof this header.
EDGE_RANGES = tuple(ipaddress.ip_network(x) for x in (
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
    "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32"))


def client_ip(peer, edge_client):
    peer = ipaddress.ip_address(peer)
    if edge_client and any(peer in net for net in EDGE_RANGES if net.version == peer.version):
        return str(ipaddress.ip_address(edge_client))
    return str(peer)


class Observations:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.Lock()
        self.sessions = {}
        self.rates = {}

    def allow(self, key, limit, seconds=60):
        now = self.clock()
        with self.lock:
            # Bound source bookkeeping even under random-source traffic.
            if len(self.rates) >= 4096:
                self.rates = {k: v for k, v in self.rates.items() if now - v[0] < seconds}
                if len(self.rates) >= 4096 and key not in self.rates:
                    return False
            since, count = self.rates.get(key, (now, 0))
            if now - since >= seconds:
                since, count = now, 0
            self.rates[key] = (since, count + 1)
            return count < limit

    def create(self, address):
        now = self.clock()
        with self.lock:
            self.sessions = {k: v for k, v in self.sessions.items() if now - v["created"] < 120}
            if len(self.sessions) >= 2048:
                return None
            token = secrets.token_hex(16)
            self.sessions[token] = {"created": now, "ip": address, "resolvers": set(), "queries": set(), "doh": {}}
            return token

    def purge(self):
        now = self.clock()
        with self.lock:
            self.sessions = {k: v for k, v in self.sessions.items() if now - v["created"] < 120}
            self.rates = {k: v for k, v in self.rates.items() if now - v[0] < 60}

    def observe(self, name, resolver):
        labels = name.lower().split(".")
        if len(labels) != len(ZONE.split(".")) + 2 or ".".join(labels[2:]) != ZONE:
            return False
        if labels[0] not in ("p0", "p1", "p2", "d0", "d1") or not TOKEN.fullmatch(labels[1]):
            return False
        with self.lock:
            row = self.sessions.get(labels[1])
            if not row or self.clock() - row["created"] >= 120:
                return False
            if labels[0] in ("d0", "d1"):
                sources = row["doh"].setdefault(labels[0], set())
                if len(sources) < 32: sources.add(str(ipaddress.ip_address(resolver)))
            else:
                if len(row["resolvers"]) < 32:
                    row["resolvers"].add(str(ipaddress.ip_address(resolver)))
                row["queries"].add(labels[0])
            return True

    def result(self, token):
        with self.lock:
            row = self.sessions.get(token)
            if not row or self.clock() - row["created"] >= 120:
                return None
            return {"ip": row["ip"], "resolvers": sorted(row["resolvers"]), "probesObserved": len(row["queries"]), "dohResolvers": {k: sorted(v) for k, v in row["doh"].items()}}


def wire_name(name):
    return b"".join(bytes([len(x)]) + x.encode("ascii") for x in name.split(".")) + b"\0"


def question(data):
    """Only accept one ordinary uncompressed question; never chase untrusted pointers."""
    if len(data) < 17 or len(data) > 1232:
        return None
    _, flags, qd, an, ns, ar = struct.unpack("!6H", data[:12])
    if flags & 0xF800 or qd != 1 or an or ns or ar > 1:
        return None
    pos, labels = 12, []
    while pos < len(data):
        size = data[pos]
        pos += 1
        if size == 0:
            break
        if size > 63 or pos + size > len(data):
            return None
        try:
            labels.append(data[pos:pos + size].decode("ascii").lower())
        except UnicodeDecodeError:
            return None
        pos += size
        if pos > 267:
            return None
    else:
        return None
    if pos + 4 > len(data):
        return None
    qtype, qclass = struct.unpack("!HH", data[pos:pos + 4])
    if qclass != 1:
        return None
    return ".".join(labels), qtype, pos + 4, flags


def dns_reply(data, source, state):
    q = question(data)
    if not q or not state.allow(("dns", source), 240):
        return None
    name, qtype, end, flags = q
    if name != ZONE and not name.endswith("." + ZONE):
        # Refused; this service cannot be used as a recursive resolver.
        return data[:2] + struct.pack("!5H", 0x8005 | (flags & 0x0100), 1, 0, 0, 0) + data[12:end]
    state.observe(name, source)
    code = 0 if name == ZONE else 3
    answers = b""
    if name == ZONE and qtype == 2:
        value = wire_name(NS)
        answers = b"\xc0\x0c" + struct.pack("!HHIH", 2, 1, 60, len(value)) + value
    # A zero-negative-TTL SOA keeps fresh probes from becoming cached positives.
    soa = wire_name(NS) + wire_name("hostmaster.ailyre.com") + struct.pack("!5I", 1, 60, 60, 120, 0)
    authority = wire_name(ZONE) + struct.pack("!HHIH", 6, 1, 0, len(soa)) + soa
    if name == ZONE and qtype == 6:
        answers, authority = authority, b""
    return data[:2] + struct.pack("!5H", 0x8400 | code | (flags & 0x0100), 1,
                                  int(bool(answers)), int(bool(authority)), 0) + data[12:end] + answers + authority


def stun_reply(data, address):
    if not 20 <= len(data) <= 256:
        return None
    kind, size, cookie = struct.unpack("!HHI", data[:8])
    if kind != 1 or size != len(data) - 20 or size % 4 or cookie != COOKIE:
        return None
    pos = 20
    while pos < len(data):
        if pos + 4 > len(data):
            return None
        attribute, length = struct.unpack("!HH", data[pos:pos + 4])
        # Binding-only, unauthenticated discovery. No TURN or arbitrary relay.
        if attribute < 0x8000:
            return None
        pos += 4 + ((length + 3) // 4) * 4
        if pos > len(data):
            return None
    host, port = address[:2]
    ip = ipaddress.ip_address(host)
    mask = struct.pack("!I", COOKIE) + data[8:20]
    value = bytes([0, 1 if ip.version == 4 else 2]) + struct.pack("!H", port ^ (COOKIE >> 16))
    value += bytes(x ^ y for x, y in zip(ip.packed, mask))
    attribute = struct.pack("!HH", 0x0020, len(value)) + value
    return struct.pack("!HHI", 0x0101, len(attribute), COOKIE) + data[8:20] + attribute


class DNSUDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        reply = dns_reply(data, self.client_address[0], self.server.observations)
        if reply:
            sock.sendto(reply, self.client_address)


class DNSTCP(socketserver.BaseRequestHandler):
    def handle(self):
        if not self.server.slots.acquire(blocking=False):
            return
        try:
            self.request.settimeout(2)
            def receive(size):
                result = b""
                while len(result) < size:
                    part = self.request.recv(size - len(result))
                    if not part:
                        return None
                    result += part
                return result
            header = receive(2)
            if not header:
                return
            size = struct.unpack("!H", header)[0]
            if not 17 <= size <= 1232:
                return
            data = receive(size)
            reply = dns_reply(data, self.client_address[0], self.server.observations) if data else None
            if reply:
                self.request.sendall(struct.pack("!H", len(reply)) + reply)
        except (OSError, ValueError):
            pass
        finally:
            self.server.slots.release()


class STUN(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if self.server.observations.allow(("stun", self.client_address[0]), 180):
            reply = stun_reply(data, self.client_address)
            if reply:
                sock.sendto(reply, self.client_address)


class HTTP(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *_):
        pass  # No IP/token/request logging or on-disk measurement history.

    def send(self, code, data, content_type="application/json"):
        if not isinstance(data, bytes):
            data = json.dumps(data, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store, no-transform")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self' https://api.ipify.org https://api6.ipify.org https://api.country.is https://ipwho.is https://*." + ZONE + "; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != ROOT + "/session" or self.headers.get("Content-Length", "0") != "0":
            return self.send(400, {"error": "invalid_request"})
        # The HTTP listener is loopback-only. nginx overwrites this header.
        try:
            ip = client_ip(self.headers.get("X-Real-IP", self.client_address[0]), self.headers.get("X-Edge-Client-IP"))
        except ValueError:
            return self.send(400, {"error": "invalid_address"})
        if not self.server.observations.allow(("session", ip), 12):
            return self.send(429, {"error": "retry_later"})
        token = self.server.observations.create(ip)
        if not token:
            return self.send(503, {"error": "busy"})
        self.send(201, {"token": token, "ip": ip,
                        "hosts": [f"p{i}.{token}.{ZONE}" for i in range(3)],
                        "stun": "stun:" + NS + ":3478"})

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == ROOT + "/health":
            return self.send(200, {"ok": True})
        if path.startswith(ROOT + "/result/"):
            token = path.rsplit("/", 1)[-1]
            result = self.server.observations.result(token) if TOKEN.fullmatch(token) else None
            return self.send(200 if result else 404, result or {"error": "expired"})
        assets = {ROOT + "/": ("index.html", "text/html; charset=utf-8"),
                  ROOT + "/probe.js": ("probe.js", "text/javascript; charset=utf-8"),
                  ROOT + "/diagnostics.js": ("diagnostics.js", "text/javascript; charset=utf-8")}
        if path in assets:
            name, mime = assets[path]
            return self.send(200, (Path(__file__).parent / name).read_bytes(), mime)
        self.send(404, {"error": "not_found"})


def serve(bind, http_port, dns_port, stun_port):
    state = Observations()
    tcp = socketserver.ThreadingTCPServer
    tcp.allow_reuse_address, tcp.daemon_threads = True, True
    servers = [ThreadingHTTPServer(("127.0.0.1", http_port), HTTP),
               socketserver.UDPServer((bind, dns_port), DNSUDP), tcp((bind, dns_port), DNSTCP),
               socketserver.UDPServer((bind, stun_port), STUN)]
    for server in servers:
        server.observations = state
        server.slots = threading.BoundedSemaphore(32)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        while True:
            threading.Event().wait(15)
            state.purge()
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="38.64.59.9")
    parser.add_argument("--http-port", type=int, default=8798)
    parser.add_argument("--dns-port", type=int, default=53)
    parser.add_argument("--stun-port", type=int, default=3478)
    args = parser.parse_args()
    serve(args.bind, args.http_port, args.dns_port, args.stun_port)
