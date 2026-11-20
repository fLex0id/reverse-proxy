#!/usr/bin/env python3
"""Inject one ACK through inner WG to a closed LAB-1 port; locate its reset.

The synthetic peer address must belong to the authorized lab client. No public
destination is contacted. A reset must return through WG, never LAB-1 underlay.
The probe leaves no persistent network changes.
"""
import argparse
import json
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for arg in ['lab1', 'lab2', 'client-ip', 'output']:
    p.add_argument('--' + arg, required=True)
a = p.parse_args()
socket.inet_aton(a.client_ip)
out = Path(a.output)
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
token = uuid.uuid4().hex[:10]
captures = []
port = 45973

def ssh(host, cmd):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', host, cmd], text=True, capture_output=True, timeout=25)

inject = r'''import socket, struct, sys
src = socket.inet_aton(sys.argv[1]); dst = socket.inet_aton('10.77.0.1')
def checksum(data):
    if len(data)%2: data+=b'\0'
    value=sum(struct.unpack('!%dH'%(len(data)//2),data))
    while value>>16: value=(value&65535)+(value>>16)
    return (~value)&65535
tcp=struct.pack('!HHIIBBHHH',443,45973,100,123,5<<4,16,1024,0,0)
cs=checksum(src+dst+struct.pack('!BBH',0,6,len(tcp))+tcp)
tcp=tcp[:16]+struct.pack('!H',cs)+tcp[18:]
ip=struct.pack('!BBHHHBBH4s4s',0x45,0,40,12345,0,64,6,0,src,dst)
ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
s=socket.socket(socket.AF_INET,socket.SOCK_RAW,socket.IPPROTO_RAW)
s.setsockopt(socket.SOL_SOCKET,socket.SO_BINDTODEVICE,b'rp-wg\0')
s.sendto(ip+tcp,('10.77.0.1',0))
'''

def packets(path):
    data = path.read_bytes()
    endian = '<' if data[:4] == b'\xd4\xc3\xb2\xa1' else '>'
    if data[:4] not in (b'\xd4\xc3\xb2\xa1', b'\xa1\xb2\xc3\xd4'):
        raise RuntimeError('unsupported PCAP header')
    link = struct.unpack(endian + 'I', data[20:24])[0]
    offset = {1: 14, 101: 0}.get(link)
    if offset is None:
        raise RuntimeError('unsupported capture link type ' + str(link))
    pos = 24
    while pos < len(data):
        _, _, length, _ = struct.unpack(endian + '4I', data[pos:pos+16])
        frame = data[pos+16:pos+16+length]
        pos += 16 + length
        ip = frame[offset:]
        if len(ip) < 40 or ip[0] >> 4 != 4 or ip[9] != 6:
            continue
        tcp = ip[(ip[0] & 15)*4:]
        yield dict(source=socket.inet_ntoa(ip[12:16]), target=socket.inet_ntoa(ip[16:20]),
                   sport=int.from_bytes(tcp[:2], 'big'), dport=int.from_bytes(tcp[2:4], 'big'),
                   flags=tcp[13])

try:
    check = ssh(a.lab1, "ss -H -lnt 'sport = :45973'")
    if check.returncode or check.stdout.strip():
        raise RuntimeError('probe destination must be a confirmed closed port')
    for label, host, interface in [('underlay', a.lab1, 'ens18'), ('inner', a.lab1, 'wg-exit')]:
        unit = 'rp-lab-rst-' + token + '-' + label
        cmd = ['systemd-run', '--quiet', '--pipe', '--wait', '--unit=' + unit,
               '--property=RuntimeMaxSec=45', 'tcpdump', '-U', '-i', interface,
               '-nn', '-s', '0', '-w', '-', f'host {a.client_ip} and tcp port {port}']
        data = (out / (label + '.pcap')).open('wb')
        log = (out / (label + '-capture.log')).open('w')
        proc = subprocess.Popen(['ssh', host, shlex.join(cmd)], stdout=data, stderr=log)
        captures.append((label, host, unit, proc, data, log))
    time.sleep(2)
    for label, host, unit, proc, data, log in captures:
        if (out / (label + '.pcap')).stat().st_size < 24 or ssh(host, 'systemctl is-active --quiet ' + unit).returncode:
            raise RuntimeError('capture failed')
    result = ssh(a.lab2, shlex.join(['python3', '-c', inject, a.client_ip]))
    if result.returncode:
        raise RuntimeError(result.stderr)
    time.sleep(2)
finally:
    for label, host, unit, proc, data, log in captures:
        ssh(host, 'systemctl kill --signal=SIGINT ' + unit)
        ssh(host, 'systemctl stop ' + unit)
        proc.wait(timeout=15)
        data.close()
        log.close()

observed = {label: list(packets(out / (label + '.pcap'))) for label in ['underlay', 'inner']}
sent = any(x['source'] == a.client_ip and x['target'] == '10.77.0.1' and x['flags'] == 16 for x in observed['inner'])
leaks = [x for x in observed['underlay'] if x['source'] == '10.77.0.1' and x['flags'] & 4]
returned = [x for x in observed['inner'] if x['source'] == '10.77.0.1' and x['flags'] & 4]
report = dict(result='PASS' if sent and returned and not leaks else 'FAIL',
              injected_ack_seen=sent, underlay_resets=len(leaks), inner_resets=len(returned), packets=observed)
(out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report), flush=True)
raise SystemExit(0 if report['result'] == 'PASS' else 1)
