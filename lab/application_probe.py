#!/usr/bin/env python3
"""Small real DoT and STUN clients; run inside the isolated WG namespace."""
import argparse
import json
import secrets
import socket
import ssl
import struct

p=argparse.ArgumentParser();p.add_argument('protocol',choices=['dot','stun'])
p.add_argument('--host',default='stun.l.google.com');p.add_argument('--port',type=int,default=19302)
a=p.parse_args()
if a.protocol=='dot':
    ident=secrets.randbelow(65536)
    query=struct.pack('!6H',ident,0x100,1,0,0,0)+b'\x07example\x03com\0'+struct.pack('!HH',1,1)
    with socket.create_connection(('1.1.1.1',853),timeout=10) as raw:
        with ssl.create_default_context().wrap_socket(raw,server_hostname='cloudflare-dns.com') as sock:
            sock.sendall(struct.pack('!H',len(query))+query)
            def receive(n):
                result=b''
                while len(result)<n:
                    part=sock.recv(n-len(result))
                    if not part:raise RuntimeError('truncated DoT response')
                    result+=part
                return result
            body=receive(struct.unpack('!H',receive(2))[0])
            ri,flags,qd,an,ns,ar=struct.unpack('!6H',body[:12])
            assert ri==ident and flags&0x8000 and flags&15==0 and an>0,'bad DNS response'
            print(json.dumps(dict(protocol='DoT',tls=sock.version(),answers=an)))
else:
    tx=secrets.token_bytes(12);cookie=0x2112A442
    request=struct.pack('!HHI',0x0001,0,cookie)+tx
    target=socket.gethostbyname(a.host)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
        sock.settimeout(10);sock.connect((target,a.port));sock.send(request);reply=sock.recv(2048)
    kind,length,magic=struct.unpack('!HHI',reply[:8])
    assert kind==0x0101 and magic==cookie and reply[8:20]==tx and len(reply)>=20+length,'bad STUN reply'
    print(json.dumps(dict(protocol='STUN/UDP',server=target,port=a.port,bytes=len(reply))))
