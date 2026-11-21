#!/usr/bin/env python3
"""Run inside the WG namespace: one UDP source port, multiple DNS destinations."""
import argparse
import json
import secrets
import socket
import struct
import time

p = argparse.ArgumentParser()
p.add_argument('--rounds', type=int, default=3)
a = p.parse_args()
results = []
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(('0.0.0.0', 0))
    sock.settimeout(5)
    for repeat in range(a.rounds):
        for target in ['10.66.0.1', '8.8.8.8', '192.0.2.53']:
            ident = secrets.randbelow(65536)
            query = struct.pack('!6H', ident, 0x100, 1, 0, 0, 0)
            query += b'\x07example\x03com\0' + struct.pack('!HH', 1, 1)
            sock.sendto(query, (target, 53))
            try:
                deadline = time.monotonic() + 5
                while True:
                    sock.settimeout(max(0.001, deadline - time.monotonic()))
                    reply, source = sock.recvfrom(65535)
                    ri, flags, qd, an, ns, ar = struct.unpack('!6H', reply[:12])
                    if ri == ident:
                        break
                    if time.monotonic() >= deadline:
                        raise TimeoutError('no matching DNS reply before deadline')
                ok = source == (target, 53) and ri == ident and flags & 0x8000 and flags & 15 == 0 and an > 0
                row = dict(round=repeat, destination=target, source=source,
                           id=ident, reply_id=ri, local_port=sock.getsockname()[1],
                           result='PASS' if ok else 'FAIL')
            except (TimeoutError, OSError, struct.error) as exc:
                row = dict(round=repeat, destination=target, result='FAIL', error=str(exc))
            results.append(row)
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(x['result'] == 'PASS' for x in results) else 1)
