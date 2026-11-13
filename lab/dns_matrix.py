#!/usr/bin/env python3
"""Query explicit resolvers from the isolated client, recording both underlays.

No route/configuration mutations. SVCB/HTTPS are intentionally dropped by the
current configuration; their failure is recorded as BLOCKED, never DNS success.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import itertools
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p=argparse.ArgumentParser()
for name in ['lab1','lab2','client','output']: p.add_argument('--'+name,required=True)
a=p.parse_args(); out=Path(a.output);out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
token=uuid.uuid4().hex[:10]
domains=['rutracker.ru','novayagazeta.ru','sberbank.ru','gosuslugi.ru','ozon.ru','example.com','meduza.io',token+'.example.com']
resolvers=['10.66.0.1','8.8.8.8','192.0.2.53']
results=[]; captures=[]
def ssh(host,cmd,timeout=30):
    return subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',host,cmd],
                          capture_output=True,text=True,timeout=timeout)
def query(case):
    resolver,domain,qtype,tcp=case
    case_id='-'.join([resolver,domain,str(qtype),'tcp' if tcp else 'udp'])
    args=['ip','netns','exec','rp-lab-client','python3','/root/rp-lab/dns-probe.py',
          resolver,domain,'--type',str(qtype),'--timeout','5']+(['--tcp'] if tcp else [])
    start=time.time()
    try:
        r=ssh(a.client,shlex.join(args),timeout=15)
        text=r.stdout+r.stderr
        if r.returncode==0:
            result='PASS' if qtype in (1,28) else 'FAIL'
            detail=json.loads(r.stdout)
        elif qtype in (64,65) and 'TimeoutError' in r.stderr:
            result='PASS';detail='BLOCKED as configured; no DNS answer claimed'
        else:
            result='FAIL' if r.returncode!=255 else 'UNKNOWN';detail='see probe log'
        rc=r.returncode
    except subprocess.TimeoutExpired:
        result='UNKNOWN';rc=124;detail='SSH/probe timeout';text=detail
    (out/(case_id+'.log')).write_text(text)
    return dict(id=case_id,started=start,seconds=time.time()-start,result=result,rc=rc,detail=detail)

try:
    for label,host in [('lab1',a.lab1),('lab2',a.lab2),('client',a.client)]:
        unit='rp-lab-dns-'+token
        path='/root/rp-lab/dns-'+token+'.pcap'
        interface='wg0' if label=='client' else 'ens18'
        cmd=['tcpdump','-U','-i',interface,'-nn','-s','0','-w','-','port 53 or port 853']
        if label=='client': cmd=['ip','netns','exec','rp-lab-client']+cmd
        # Stream the capture to the controller. On SELinux-enforcing Rocky,
        # tcpdump cannot write a private admin_home_t file after dropping uid.
        # A pipe preserves enforcement and does not expose the capture in /tmp.
        data=(out/(label+'.pcap')).open('wb'); log=(out/(label+'-capture-stream.log')).open('w')
        cmd=['systemd-run','--quiet','--pipe','--wait','--unit='+unit,'--property=RuntimeMaxSec=600']+cmd
        proc=subprocess.Popen(['ssh','-o','BatchMode=yes',host,shlex.join(cmd)],stdout=data,stderr=log)
        captures.append((label,host,unit,path,proc,data,log))
    time.sleep(2)
    for label,host,unit,path,proc,data,log in captures:
        if ssh(host,'systemctl is-active --quiet '+unit).returncode:
            raise RuntimeError('Capture is not active on '+host)
        if (out/(label+'.pcap')).stat().st_size < 24:
            raise RuntimeError('Capture header has not arrived from '+host)
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures=[pool.submit(query,c) for c in itertools.product(resolvers,domains,[1,28,64,65],[False,True])]
        for f in as_completed(futures):
            row=f.result();results.append(row)
            (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
            if len(results)%24==0:print(json.dumps({'completed':len(results),'failures':sum(r['result']!='PASS' for r in results)}),flush=True)
finally:
    for label,host,unit,path,proc,data,log in captures:
        ssh(host,'systemctl kill --signal=SIGINT '+unit)
        ssh(host,'systemctl stop '+unit)
        try: proc.wait(timeout=20)
        except subprocess.TimeoutExpired: proc.terminate();proc.wait(timeout=10)
        data.close();log.close()
        r=ssh(host,'journalctl -u '+unit+' --no-pager');(out/(label+'-capture.log')).write_text(r.stdout+r.stderr)
        path='/root/rp-lab/dns-'+token+'-'+label+'.pcap'
        r=subprocess.run(['scp','-q',str(out/(label+'.pcap')),a.client+':'+path],capture_output=True,text=True)
        if r.returncode:
            (out/(label+'-capture-error.log')).write_text(r.stderr)
            continue  # Always stop/collect the remaining hosts too.
        filt='src host 192.168.91.221 and dst port 53' if label=='lab1' else 'port 53'
        r=ssh(a.client,shlex.join(['tcpdump','-nn','-vv','-r',path,filt]))
        (out/(label+'-dns-packets.log')).write_text(r.stdout+r.stderr)
print(json.dumps({'cases':len(results),'nonpassing':sum(r['result']!='PASS' for r in results),
                  'leak_verdict':'UNKNOWN: analyze captured queries against geosite policy'}),flush=True)
