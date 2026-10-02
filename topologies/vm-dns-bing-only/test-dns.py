"""Probe the native resolver policy from inside the topology VM."""

import argparse
import secrets
import socket
import struct
import sys


BLOCK_NAME = "blockpolicy.azuredns.invalid"


def encode_name(name):
    return b"".join(bytes([len(label)]) + label.encode("ascii") for label in name.split(".")) + b"\0"


def read_name(packet, offset):
    labels = []
    visited = set()
    end = None
    while True:
        if offset in visited or offset >= len(packet):
            raise ValueError("Invalid DNS name or compression loop")
        visited.add(offset)
        length = packet[offset]
        if length & 0xC0 == 0xC0:
            pointer = struct.unpack_from("!H", packet, offset)[0] & 0x3FFF
            if end is None:
                end = offset + 2
            offset = pointer
            continue
        if length & 0xC0:
            raise ValueError("Invalid DNS label length")
        offset += 1
        if length == 0:
            return ".".join(labels).lower(), end if end is not None else offset
        if offset + length > len(packet):
            raise ValueError("Truncated DNS label")
        labels.append(packet[offset:offset + length].decode("ascii"))
        offset += length


def parse_response(packet, query_id, domain):
    response_id, flags, questions, answers, _, _ = struct.unpack_from("!6H", packet)
    if response_id != query_id or not flags & 0x8000 or flags & 0x0200 or flags & 0x780F:
        raise ValueError("Unexpected, truncated, or unsuccessful DNS response")
    if questions != 1:
        raise ValueError("Expected one DNS question")
    question, offset = read_name(packet, 12)
    qtype, qclass = struct.unpack_from("!2H", packet, offset)
    if question != domain or (qtype, qclass) != (1, 1):
        raise ValueError("DNS response question does not match the request")
    offset += 4
    addresses = []
    cnames = []
    for _ in range(answers):
        _, offset = read_name(packet, offset)
        rtype, rclass, _, size = struct.unpack_from("!HHIH", packet, offset)
        offset += 10
        end = offset + size
        if end > len(packet):
            raise ValueError("Truncated DNS answer")
        if rclass == 1 and rtype == 1:
            if size != 4:
                raise ValueError("Invalid IPv4 answer length")
            addresses.append(socket.inet_ntoa(packet[offset:end]))
        elif rclass == 1 and rtype == 5:
            cname, cname_end = read_name(packet, offset)
            if cname_end != end:
                raise ValueError("Invalid CNAME answer length")
            cnames.append(cname)
        offset = end
    return addresses, cnames


def query(server, domain):
    query_id = secrets.randbelow(65536)
    packet = struct.pack("!6H", query_id, 0x0100, 1, 0, 0, 0)
    packet += encode_name(domain) + struct.pack("!2H", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        client.connect((server, 53))
        client.send(packet)
        response = client.recv(65535)
    return parse_response(response, query_id, domain)


def verify_response(addresses, cnames, allowed):
    if allowed:
        if not addresses or BLOCK_NAME in cnames:
            raise ValueError("Allowed name did not return an unblocked IPv4 answer")
    elif addresses or BLOCK_NAME not in cnames:
        raise ValueError("Denied name did not return the Azure policy block CNAME")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", action="append", required=True, help="DNS server IPv4 address; repeat for both paths")
    args = parser.parse_args()
    failures = 0
    for server in args.server:
        socket.inet_pton(socket.AF_INET, server)
        for domain in ("www.bing.com", "bing.com", "www.google.com", "www.microsoft.com"):
            allowed = domain == "www.bing.com"
            try:
                addresses, cnames = query(server, domain)
                verify_response(addresses, cnames, allowed)
                print(f"PASS {server} {domain}: {'allowed' if allowed else 'policy blocked'}")
            except (OSError, ValueError, struct.error) as error:
                failures += 1
                print(f"FAIL {server} {domain}: {error}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
