import json, pathlib, struct, sys, time
root = pathlib.Path(sys.argv[1])
stats = sys.argv[3].splitlines()
report = dict(time=time.time(), curl_rc=int(sys.argv[2]), http=stats[0] if stats else '',
              content_type=stats[1] if len(stats)>1 else '', seconds=stats[2] if len(stats)>2 else '',
              result='FAIL', error='')
def require(condition, reason):
    if not condition: raise ValueError(reason)
try:
    require(report['curl_rc']==0, 'curl failed; partial data is not success')
    require(report['http']=='200', 'unexpected HTTP status')
    require(report['content_type'].split(';',1)[0].strip().lower()=='application/dns-message', 'unexpected content type')
    data = (root/'body').read_bytes()
    report['bytes'] = len(data)
    require(12 <= len(data) <= 65535, 'invalid DNS message size')
    ident, flags, qd, an, ns, ar = struct.unpack('!6H', data[:12])
    require(ident==0 and flags&0x8000 and not flags&0x7a4f and qd==1 and an>0, 'invalid DNS header or unsuccessful answer')
    def name(pos):
        seen=set(); labels=[]; end=None
        while True:
            require(pos<len(data) and pos not in seen, 'invalid DNS name pointer')
            seen.add(pos); size=data[pos]; pos+=1
            if size==0: return '.'.join(labels).lower(), end if end is not None else pos
            if size&0xc0==0xc0:
                require(pos<len(data), 'truncated DNS pointer')
                if end is None: end=pos+1
                pos=((size&0x3f)<<8)|data[pos]; continue
            require(size<=63 and pos+size<=len(data), 'invalid DNS label')
            labels.append(data[pos:pos+size].decode('ascii')); pos+=size
    question, pos = name(12)
    qtype, qclass = struct.unpack('!HH', data[pos:pos+4]); pos+=4
    require(question=='example.com' and qtype==1 and qclass==1, 'unexpected DNS question')
    address=False
    for index in range(an+ns+ar):
        _, pos = name(pos)
        kind, cls, ttl, length = struct.unpack('!HHIH', data[pos:pos+10]); pos+=10
        require(pos+length<=len(data), 'truncated DNS record')
        if index<an and kind==1 and cls==1 and length==4: address=True
        pos+=length
    require(pos==len(data) and address, 'incomplete DNS A answer')
    report['result']='PASS'
except (ValueError, OSError, IndexError, struct.error, UnicodeError) as exc:
    report['error']=str(exc)
report['curl_error']=(root/'curl-error').read_text(errors='replace')[:2000]
print(json.dumps(report))
sys.exit(0 if report['result']=='PASS' else 1)
