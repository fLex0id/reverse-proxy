#!/usr/bin/env python3
"""Application traffic with three simultaneous PCAPs; no routing mutations."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p=argparse.ArgumentParser()
for name in ['lab1','lab2','client','output']:p.add_argument('--'+name,required=True)
a=p.parse_args();out=Path(a.output);out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
token=uuid.uuid4().hex[:10];captures=[]
def ssh(host,cmd,timeout=40):
    return subprocess.run(['ssh','-o','BatchMode=yes',host,cmd],text=True,capture_output=True,timeout=timeout)
def probe(case):
    name,args,expected=case;start=time.time()
    r=ssh(a.client,shlex.join(['ip','netns','exec','rp-lab-client']+args))
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    ok=r.returncode==0 if expected=='success' else r.returncode==28
    if name=='http3':ok=ok and r.stdout.strip().endswith(' 3')
    return dict(id=name,started=start,seconds=time.time()-start,rc=r.returncode,
                result='PASS' if ok else 'FAIL',expectation=expected,log=name+'.log')

curl=['curl','-4','-f','-sS','--max-time','20','--connect-timeout','8','-o','/dev/null','-w','%{http_code} %{http_version}']
query='https://cloudflare-dns.com/dns-query?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE'
cases=[('http',curl+['http://1.1.1.1/'],'success'),
       ('https',curl+['https://1.1.1.1/cdn-cgi/trace'],'success'),
       ('doh',curl+['--resolve','cloudflare-dns.com:443:1.1.1.1','-H','accept: application/dns-message',query],'success'),
       ('http3',curl+['--http3-only','--resolve','cloudflare-dns.com:443:1.1.1.1','-H','accept: application/dns-message',query],'success'),
       ('dot',['python3','/root/rp-lab/application_probe.py','dot'],'success'),
       ('stun',['python3','/root/rp-lab/application_probe.py','stun'],'success'),
       ('stun-cloudflare',['python3','/root/rp-lab/application_probe.py','stun',
                           '--host','stun.cloudflare.com','--port','3478'],'success'),
       ('ipv6',['curl','-g','-6','-k','-sS','--max-time','10','https://[2606:4700:4700::1111]/','-o','/dev/null'],'blocked')]
try:
    for label,host in [('lab1',a.lab1),('lab2',a.lab2),('client',a.client)]:
        unit='rp-lab-app-'+token;interface='wg0' if label=='client' else 'ens18'
        command=['tcpdump','-U','-i',interface,'-nn','-s','0','-w','-',
                 'host 1.1.1.1 or host 2606:4700:4700::1111 or port 53 or port 853 or udp port 19302 or udp port 3478']
        if label=='client':command=['ip','netns','exec','rp-lab-client']+command
        command=['systemd-run','--quiet','--pipe','--wait','--unit='+unit,'--property=RuntimeMaxSec=120']+command
        data=(out/(label+'.pcap')).open('wb');log=(out/(label+'-capture.log')).open('w')
        proc=subprocess.Popen(['ssh',host,shlex.join(command)],stdout=data,stderr=log)
        captures.append((label,host,unit,proc,data,log))
    time.sleep(2)
    for label,host,unit,proc,data,log in captures:
        if (out/(label+'.pcap')).stat().st_size<24 or ssh(host,'systemctl is-active --quiet '+unit).returncode:
            raise RuntimeError('capture did not start on '+host)
    with ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(probe,cases))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2),flush=True)
finally:
    for label,host,unit,proc,data,log in captures:
        ssh(host,'systemctl kill --signal=SIGINT '+unit)
        ssh(host,'systemctl stop '+unit)
        proc.wait(timeout=20);data.close();log.close()
        remote='/root/rp-lab/app-'+token+'-'+label+'.pcap'
        subprocess.run(['scp','-q',str(out/(label+'.pcap')),a.client+':'+remote],check=True)
        filt='src host 192.168.91.221' if label=='lab1' else 'ip or ip6'
        r=ssh(a.client,shlex.join(['tcpdump','-nn','-r',remote,filt]))
        (out/(label+'-packets.log')).write_text(r.stdout+r.stderr)
