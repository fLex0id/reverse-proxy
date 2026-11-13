#!/usr/bin/env python3
"""Minimal DNS probe: query type and resolver are explicit, no system fallback."""
import argparse
import json
import secrets
import socket
import struct
p=argparse.ArgumentParser();p.add_argument('server');p.add_argument('domain');p.add_argument('--type',type=int,default=1);p.add_argument('--tcp',action='store_true');p.add_argument('--timeout',type=float,default=10);a=p.parse_args()
ident=secrets.randbelow(65536)
q=struct.pack('!6H',ident,0x100,1,0,0,0)+b''.join(bytes([len(x)])+x.encode('ascii') for x in a.domain.split('.'))+b'\0'+struct.pack('!2H',a.type,1)
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if a.tcp else socket.SOCK_DGRAM);s.settimeout(a.timeout)
s.connect((a.server,53))
if a.tcp:
    s.sendall(struct.pack('!H',len(q))+q)
    def receive(n):
        result=b''
        while len(result)<n:
            chunk=s.recv(n-len(result))
            if not chunk: raise RuntimeError('truncated DNS/TCP response')
            result+=chunk
        return result
    n=struct.unpack('!H',receive(2))[0];r=receive(n)
else:
    s.send(q);r=s.recv(65535)
ri,flags,qd,an,ns,ar=struct.unpack('!6H',r[:12])
assert ri==ident and flags&0x8000,'invalid DNS response'
rcode=flags&15
print(json.dumps(dict(server=a.server,domain=a.domain,type=a.type,tcp=a.tcp,rcode=rcode,answers=an,bytes=len(r))))
raise SystemExit(0 if rcode in (0,3) else 1)
