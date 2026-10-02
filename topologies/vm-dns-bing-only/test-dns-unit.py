"""Local tests for DNS policy probe parsing and pass/fail decisions."""

import importlib.util
from pathlib import Path
import socket
import struct
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("dns_probe", Path(__file__).with_name("test-dns.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def response(domain="www.bing.com", rtype=1, data=None, flags=0x8180, query_id=42):
    if data is None:
        data = socket.inet_aton("1.2.3.4")
    question = probe.encode_name(domain) + struct.pack("!2H", 1, 1)
    answer = b"\xc0\x0c" + struct.pack("!HHIH", rtype, 1, 60, len(data)) + data
    return struct.pack("!6H", query_id, flags, 1, 1, 0, 0) + question + answer


class ProbeTests(unittest.TestCase):
    def test_allowed_address(self):
        addresses, cnames = probe.parse_response(response(), 42, "www.bing.com")
        self.assertEqual(addresses, ["1.2.3.4"])
        probe.verify_response(addresses, cnames, True)

    def test_policy_block_is_noerror_cname(self):
        packet = response("bing.com", 5, probe.encode_name(probe.BLOCK_NAME))
        addresses, cnames = probe.parse_response(packet, 42, "bing.com")
        self.assertEqual(cnames, [probe.BLOCK_NAME])
        probe.verify_response(addresses, cnames, False)

    def test_blocked_allowed_name_fails(self):
        with self.assertRaises(ValueError):
            probe.verify_response([], [probe.BLOCK_NAME], True)

    def test_missing_block_marker_fails(self):
        for addresses, cnames in (([], []), (["1.2.3.4"], []), (["1.2.3.4"], [probe.BLOCK_NAME])):
            with self.subTest(addresses=addresses, cnames=cnames), self.assertRaises(ValueError):
                probe.verify_response(addresses, cnames, False)

    def test_invalid_headers_fail(self):
        for flags in (0x8183, 0x8182, 0x8380, 0x0100, 0x8980):
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                probe.parse_response(response(flags=flags), 42, "www.bing.com")
        with self.assertRaises(ValueError):
            probe.parse_response(response(query_id=43), 42, "www.bing.com")
        with self.assertRaises(ValueError):
            probe.parse_response(response(domain="bing.com"), 42, "www.bing.com")

    def test_malformed_packets_fail(self):
        for packet in (b"", response()[:-1], response(data=b"\x01")):
            with self.subTest(packet=packet), self.assertRaises((ValueError, struct.error)):
                probe.parse_response(packet, 42, "www.bing.com")
        with self.assertRaises(ValueError):
            probe.read_name(b"\xc0\x00", 0)
        with self.assertRaises(ValueError):
            probe.read_name(b"\x05ab", 0)

    def test_main_tests_both_paths(self):
        def successful_query(server, domain):
            return (["1.2.3.4"], []) if domain == "www.bing.com" else ([], [probe.BLOCK_NAME])

        with patch("sys.argv", ["test-dns.py", "--server", "10.50.1.4", "--server", "168.63.129.16"]), \
             patch.object(probe, "query", side_effect=successful_query) as query:
            self.assertEqual(probe.main(), 0)
            self.assertEqual(query.call_count, 8)

    def test_timeouts_fail(self):
        with patch("sys.argv", ["test-dns.py", "--server", "10.50.1.4"]), \
             patch.object(probe, "query", side_effect=socket.timeout("DNS timed out")):
            self.assertEqual(probe.main(), 1)


if __name__ == "__main__":
    unittest.main()
