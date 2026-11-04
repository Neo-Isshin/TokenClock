import importlib.util
import ipaddress
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("leak_server", Path(__file__).with_name("server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def query(name, kind=1):
    return struct.pack("!6H", 1234, 0x100, 1, 0, 0, 0) + server.wire_name(name) + struct.pack("!HH", kind, 1)


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.state = server.Observations(lambda: self.now)

    def test_proxy_peer_is_not_misreported_as_client_and_direct_headers_are_not_trusted(self):
        self.assertEqual(server.client_ip("104.22.193.46", "8.8.8.8"), "8.8.8.8")
        self.assertEqual(server.client_ip("1.1.1.1", "8.8.8.8"), "1.1.1.1")
        self.assertEqual(server.client_ip("2606:4700::1", "1.1.1.1"), "1.1.1.1")

    def test_only_known_fresh_sessions_collect_queries_and_expire(self):
        token = self.state.create("8.8.8.8")
        host = "p0." + token + "." + server.ZONE
        self.assertTrue(self.state.observe(host, "1.1.1.1"))
        self.assertTrue(self.state.observe(host.upper(), "1.1.1.1"))
        self.assertFalse(self.state.observe("p9." + token + "." + server.ZONE, "9.9.9.9"))
        self.assertFalse(self.state.observe("p0." + "f" * 32 + "." + server.ZONE, "9.9.9.9"))
        self.assertEqual(self.state.result(token), {"ip": "8.8.8.8", "resolvers": ["1.1.1.1"], "probesObserved": 1, "dohResolvers": {}})
        self.now += 120
        self.assertIsNone(self.state.result(token))
        self.assertFalse(self.state.observe(host, "9.9.9.9"))
        self.state.purge()
        self.assertEqual(self.state.sessions, {})

    def test_doh_sources_do_not_pollute_system_dns_results(self):
        token=self.state.create("8.8.8.8")
        self.assertTrue(self.state.observe("d0."+token+"."+server.ZONE,"1.1.1.1"))
        self.assertTrue(self.state.observe("p0."+token+"."+server.ZONE,"9.9.9.9"))
        result=self.state.result(token)
        self.assertEqual(result["resolvers"],["9.9.9.9"])
        self.assertEqual(result["probesObserved"],1)
        self.assertEqual(result["dohResolvers"],{"d0":["1.1.1.1"]})

    def test_sessions_and_source_budgets_are_bounded(self):
        for _ in range(12):
            self.assertTrue(self.state.allow(("session", "a"), 12))
        self.assertFalse(self.state.allow(("session", "a"), 12))
        self.now += 60
        self.assertTrue(self.state.allow(("session", "a"), 12))
        self.state.sessions = {str(i): {"created": self.now} for i in range(2048)}
        self.assertIsNone(self.state.create("1.1.1.1"))

    def test_authority_observes_real_query_source_and_returns_nxdomain(self):
        token = self.state.create("8.8.8.8")
        host = "p1." + token + "." + server.ZONE
        packet = query(host)
        response = server.dns_reply(packet, "1.1.1.1", self.state)
        transaction, flags, qd, an, ns, ar = struct.unpack("!6H", response[:12])
        self.assertEqual(transaction, 1234)
        self.assertEqual(flags & 15, 3)
        self.assertTrue(flags & 0x0400)
        self.assertFalse(flags & 0x0080)  # No recursion available.
        self.assertEqual((qd, an, ns, ar), (1, 0, 1, 0))
        self.assertEqual(self.state.result(token)["resolvers"], ["1.1.1.1"])
        response = server.dns_reply(query("unrelated.example"), "1.1.1.1", self.state)
        self.assertEqual(struct.unpack("!H", response[2:4])[0] & 15, 5)

    def test_malformed_compressed_multiple_and_non_internet_questions_are_rejected(self):
        good = query(server.ZONE)
        bad = [b"", good[:14], good[:12] + b"\xc0\x0c" + good[-4:],
               good[:4] + b"\x00\x02" + good[6:], good[:-2] + b"\x00\x03",
               b"x" * 1500]
        for packet in bad:
            self.assertIsNone(server.dns_reply(packet, "1.1.1.1", self.state))
        for kind in [2, 6, 28, 255]:
            self.assertIsNotNone(server.dns_reply(query(server.ZONE, kind), "1.1.1.1", self.state))

    def test_stun_observation_contains_source_address_and_matches_transaction(self):
        transaction = bytes(range(12))
        packet = struct.pack("!HHI", 1, 0, server.COOKIE) + transaction
        for ip, port in [("1.2.3.4", 40123), ("2001:4860:4860::8888", 23456)]:
            response = server.stun_reply(packet, (ip, port))
            self.assertEqual(response[8:20], transaction)
            self.assertEqual(struct.unpack("!H", response[20:22])[0], 0x20)
            self.assertEqual(struct.unpack("!H", response[26:28])[0] ^ (server.COOKIE >> 16), port)
            mask = struct.pack("!I", server.COOKIE) + transaction
            raw = bytes(x ^ y for x, y in zip(response[28:], mask))
            self.assertEqual(str(ipaddress.ip_address(raw)), ip)
        # Browser Binding requests may include FINGERPRINT (an optional attribute).
        attributed = struct.pack("!HHI", 1, 8, server.COOKIE) + transaction + struct.pack("!HHI", 0x8028, 4, 0)
        self.assertIsNotNone(server.stun_reply(attributed, ("1.1.1.1", 5555)))
        for bad in [b"", packet[:-1], b"\x00\x03" + packet[2:], packet + b"x", packet[:4] + b"bad!" + packet[8:]]:
            self.assertIsNone(server.stun_reply(bad, ("1.1.1.1", 5)))


if __name__ == "__main__":
    unittest.main()
