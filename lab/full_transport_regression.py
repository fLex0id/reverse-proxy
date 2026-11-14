#!/usr/bin/env python3
"""Sequential live regressions; never overlap another mutation/fault suite.

Runs full T1-T3 and 30 complete T3 repetitions on each pinned transport, VPS-1
checks including the explicit restart, and client DNS/application capture suites.
This is an intermediate existing-install regression, not the final clean soak.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time

p=argparse.ArgumentParser()
for name in ['lab1','lab2','client','output']:p.add_argument('--'+name,required=True)
a=p.parse_args();out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
root=Path(__file__).resolve().parents[1];records=[]
def record(name,result,detail,started):
    row=dict(id=name,result=result,detail=detail,started=started,seconds=time.time()-started)
    records.append(row);(out/'results.json').write_text(json.dumps(records,indent=2)+'\n')
    print(json.dumps(row),flush=True)
def remote(host,command,name,timeout=600,allow_skips=False):
    started=time.time()
    try:
        r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',host,command],
                         capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired:
        record(name,'UNKNOWN','SSH timeout: remote process may still run',started)
        raise RuntimeError('Inspect remote state before continuing')
    text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
    result='PASS' if r.returncode==0 else 'FAIL'
    if allow_skips and r.returncode==0 and ('  - T' in text or '  – T' in text):result='SKIP'
    record(name,result,{'rc':r.returncode,'log':name+'.log'},started)
    return r

local_hash=hashlib.sha256((root/'rp.sh').read_bytes()).hexdigest()
r=remote(a.lab1,'sha256sum /usr/local/bin/rp','candidate-sha')
if r.returncode or r.stdout.split()[0]!=local_hash:raise SystemExit('Local/deployed candidate differ')
(out/'candidate.json').write_text(json.dumps({'rp_sha256':local_hash,
    'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()},indent=2))
for transport in ['reality-xhttp2','reality-xhttp','hy2-wg','hy2o-wg']:
    if remote(a.lab1,'rp tunnel '+transport,transport+'-pin').returncode:
        raise SystemExit('Pin failed; leave state for inspection')
    remote(a.lab1,'rp test --restart',transport+'-T1-T8-restart',allow_skips=True)
    remote(a.lab2,'rp test',transport+'-T1-T3')
    script='''
failed=0
for ((i=1; i<=30; i++)); do
  start=$SECONDS
  if rp _fn t3_check "$1"; then rc=0; else rc=$?; failed=$((failed+1)); fi
  printf 'iteration=%d rc=%d seconds=%d\n' "$i" "$rc" "$((SECONDS-start))"
done
((failed==0))
'''
    remote(a.lab2,shlex.join(['bash','-c',script,'bash',transport]),transport+'-T3-repeat30',timeout=7200)
    for suite in ['dns_matrix.py','application_matrix.py']:
        started=time.time();name=transport+'-'+suite.removesuffix('.py')
        args=[sys.executable,str(root/'lab'/suite),'--lab1',a.lab1,'--lab2',a.lab2,
              '--client',a.client,'--output',str(out/name)]
        with (out/(name+'.log')).open('w') as log:
            r=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=900)
        result_path=out/name/'results.json'
        if r.returncode or not result_path.exists():
            record(name,'UNKNOWN','Harness/capture failure; inspect log',started)
            raise SystemExit('Harness failure')
        items=json.loads(result_path.read_text())
        expected_count=192 if suite=='dns_matrix.py' else 8
        bad=[x['id'] for x in items if x['result']!='PASS']
        good=len(items)==expected_count and not bad
        record(name,'PASS' if good else 'FAIL',{'cases':len(items),'nonpassing':bad,
            'leak_analysis':'UNKNOWN until PCAP attribution reviewed'},started)
        if suite == 'dns_matrix.py':
            remote(a.client, shlex.join(['ip', 'netns', 'exec', 'rp-lab-client', 'python3',
                '/root/rp-lab/dns_source_reuse.py', '--rounds', '30']), transport+'-dns-source-reuse')
remote(a.lab1,'rp tunnel auto','restore-auto')
