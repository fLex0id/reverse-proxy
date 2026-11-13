#!/usr/bin/env python3
"""Authorized lab-only transport/packet evidence runner. No secrets are printed."""
import argparse
import datetime as dt
import json
from pathlib import Path
import shlex
import subprocess
import time

p=argparse.ArgumentParser()
p.add_argument('--lab1',required=True);p.add_argument('--lab2',required=True);p.add_argument('--client',required=True)
p.add_argument('--output',required=True)
a=p.parse_args(); out=Path(a.output);out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
results=[]
def run(host,cmd,name,timeout=420):
    start=time.monotonic(); ts=dt.datetime.now(dt.timezone.utc).isoformat()
    try:
        r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',host,cmd],capture_output=True,text=True,timeout=timeout)
        rc=r.returncode; text=r.stdout+r.stderr
    except subprocess.TimeoutExpired:
        rc=124; text='TIMEOUT: remote process may still be running; inspect before retrying\n'
    (out/(name+'.log')).write_text(text)
    result=dict(id=name,host=host,started=ts,seconds=round(time.monotonic()-start,3),rc=rc,result='PASS' if rc==0 else 'FAIL',log=name+'.log')

    if name.endswith('-T1-T8') and rc == 0 and ('  - T' in text or '  – T' in text): result['result']='SKIP'; result['reason']='One or more built-in checks skipped; see log'
    results.append(result);(out/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(result),flush=True)
    return rc

for t in ['reality-xhttp2','reality-xhttp','hy2-wg','hy2o-wg']:
    if run(a.lab1,'rp tunnel '+shlex.quote(t),t+'-select'):
        break # a pending transition must be investigated, never overwritten
    run(a.lab1,'rp test',t+'-T1-T8') # inspect SKIP lines separately; rc alone is not full acceptance
    procs=[]
    for label,host in [('lab1',a.lab1),('lab2',a.lab2)]:
        path='/root/rp-lab/'+t+'-'+label+'.pcap'
        cmd='timeout --signal=INT 30 tcpdump -U -i ens18 -nn -s 256 -w '+shlex.quote(path)+' '+shlex.quote('host 1.1.1.1 or port 53')
        f=(out/(t+'-'+label+'-capture.log')).open('w')
        procs.append((subprocess.Popen(['ssh',host,cmd],stdout=f,stderr=f),f,host,path))
    time.sleep(2)
    run(a.client,"ip netns exec rp-lab-client curl -4 -fsS --max-time 20 https://1.1.1.1/cdn-cgi/trace -o /dev/null -w 'HTTP=%{http_code}\\n'",t+'-client-https',30)
    run(a.client,"ip netns exec rp-lab-client getent ahostsv4 example.com",t+'-client-dns',30)
    run(a.lab2,'rp mode status',t+'-state',20)
    for proc,f,host,path in procs:
        try: proc.wait(timeout=40)
        except subprocess.TimeoutExpired: proc.terminate()
        f.close()
        subprocess.run(['scp','-q',host+':'+path,str(out)],check=False)
    for label in ['lab1','lab2']:
        # Evidence only: background observatory/bootstrap must be distinguished during analysis.
        run(a.lab1 if label=='lab1' else a.lab2,
            'tcpdump -nn -r '+shlex.quote('/root/rp-lab/'+t+'-'+label+'.pcap')+' '+shlex.quote('dst host 1.1.1.1 and tcp dst port 443'),t+'-'+label+'-endpoint-packets',20)
else:
    run(a.lab1,'rp tunnel auto','restore-auto')
