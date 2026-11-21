#!/usr/bin/env python3
"""Authenticated Hysteria SOCKS probes; UDP decisions need server PCAP review."""
import argparse
import ipaddress
import json
import socket
import struct
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--port', type=int, required=True)
p.add_argument('--client-ip', required=True)
a = p.parse_args()
rows = []


def receive(sock, size):
    value = b''
    while len(value) < size:
        part = sock.recv(size-len(value))
        if not part:
            raise RuntimeError('Truncated SOCKS reply')
        value += part
    return value


def address(host, port):
    ip = ipaddress.ip_address(host)
    return bytes([1 if ip.version == 4 else 4])+ip.packed+struct.pack('!H', port)


def socks(command, host, port):
    sock = socket.create_connection(('127.0.0.1', a.port), timeout=5)
    sock.sendall(b'\x05\x01\x00')
    if receive(sock, 2) != b'\x05\x00':
        raise RuntimeError('SOCKS negotiation failed')
    sock.sendall(bytes([5, command, 0])+address(host, port))
    version, reply, reserved, kind = receive(sock, 4)
    if version != 5 or reserved != 0:
        raise RuntimeError('Malformed SOCKS response')
    if kind == 1:
        bound = socket.inet_ntop(socket.AF_INET, receive(sock, 4))
    elif kind == 4:
        bound = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
    elif kind == 3:
        bound = receive(sock, receive(sock, 1)[0]).decode('ascii')
    else:
        raise RuntimeError('Invalid SOCKS address type')
    bound_port = struct.unpack('!H', receive(sock, 2))[0]
    return sock, reply, (bound, bound_port)


for host, port in [('127.0.0.1', 22), ('127.0.0.1', 1080),
                   ('127.0.0.1', 10085), ('127.0.0.1', 7000), (a.client_ip, 22)]:
    sock, reply, _ = socks(1, host, port)
    sock.close()
    rows.append(dict(protocol='tcp', host=host, port=port, socks_reply=reply,
                     result='PASS' if reply != 0 else 'FAIL'))

control, reply, relay = socks(3, '0.0.0.0', 0)
if reply != 0:
    raise RuntimeError('SOCKS UDP association unavailable; denial tests invalid')
if relay[0] == '0.0.0.0':
    relay = ('127.0.0.1', relay[1])
with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.settimeout(3)
    for host, port, allowed in [('127.0.0.1', 51821, True), ('127.0.0.1', 22, False),
                                ('127.0.0.1', 1080, False), ('127.0.0.1', 10085, False),
                                ('127.0.0.2', 51821, False), ('::1', 51821, False),
                                (a.client_ip, 22, False)]:
        token = 'rp-acl-'+uuid.uuid4().hex
        packet = b'\x00\x00\x00'+address(host, port)+token.encode()
        for _ in range(3):
            udp.sendto(packet, relay)
            time.sleep(0.05)
        rows.append(dict(protocol='udp', host=host, port=port, token=token,
                         allowed=allowed, result='UNKNOWN', reason='server capture required'))
    time.sleep(2)
print(json.dumps(rows))
