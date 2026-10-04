#!/usr/bin/env python3
"""A one-name DNS server for the netboot smoke test.

Answers an A query for NAME with ADDR and every other query with NXDOMAIN
(NOERROR with no answer for other types of NAME), on UDP 127.0.0.1:53. Every
question is appended to LOG as "<type> <name>", so the test can show the
guest asked it.

Usage:
    smoke-dns.py serve NAME ADDR LOG
    smoke-dns.py query NAME          exit 0 if 127.0.0.1:53 answers NAME

Stdlib only. Runs inside the smoke test's own network namespace, where
binding port 53 needs no privilege on the host.
"""

import socket
import struct
import sys

TYPE_A = 1


def parse_question(msg):
    """Return (qname, qtype, end offset) of the first question."""
    labels = []
    i = 12
    while True:
        n = msg[i]
        i += 1
        if n == 0:
            break
        if n & 0xC0:
            raise ValueError("compressed question name")
        labels.append(msg[i:i + n].decode("ascii", "replace"))
        i += n
    qtype, _qclass = struct.unpack("!HH", msg[i:i + 4])
    return ".".join(labels).lower(), qtype, i + 4


def answer(msg, name, addr):
    (qid, flags, qdcount) = struct.unpack("!HHH", msg[:6])
    if qdcount != 1:
        return None
    qname, qtype, end = parse_question(msg)
    known = qname == name
    # QR, AA, RA; opcode and RD copied from the query.
    rflags = 0x8000 | (flags & 0x7900) | 0x0400 | 0x0080 | (0 if known else 3)
    ancount = 1 if known and qtype == TYPE_A else 0
    out = struct.pack("!HHHHHH", qid, rflags, 1, ancount, 0, 0) + msg[12:end]
    if ancount:
        out += struct.pack("!HHHIH", 0xC00C, TYPE_A, 1, 60, 4) + socket.inet_aton(addr)
    return qname, qtype, out


def serve(name, addr, log):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 53))
    while True:
        msg, peer = s.recvfrom(4096)
        try:
            res = answer(msg, name, addr)
        except (ValueError, IndexError, struct.error):
            continue
        if res is None:
            continue
        qname, qtype, out = res
        with open(log, "a") as f:
            f.write(f"{qtype} {qname}\n")
        s.sendto(out, peer)


def query(name):
    q = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode("ascii")
    q += b"\0" + struct.pack("!HH", TYPE_A, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1)
    s.sendto(q, ("127.0.0.1", 53))
    reply = s.recv(4096)
    _qid, flags, _qd, ancount = struct.unpack("!HHHH", reply[:8])
    return flags & 0xF == 0 and ancount == 1


def main(argv):
    if len(argv) == 5 and argv[1] == "serve":
        serve(argv[2].lower(), argv[3], argv[4])
        return 0
    if len(argv) == 3 and argv[1] == "query":
        try:
            return 0 if query(argv[2].lower()) else 1
        except OSError:
            return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
