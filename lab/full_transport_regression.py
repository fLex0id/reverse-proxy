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
import tarfile
import time

p=argparse.ArgumentParser()
for name in ['lab1','lab2','client','output']:p.add_argument('--'+name,required=True)
p.add_argument('--bundle', type=Path, help='Verify every installed file against a modular release archive')
p.add_argument('--continue-from', type=Path, help='Reuse passed checks from the same candidate; retain the original evidence')
a=p.parse_args();out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
root=Path(__file__).resolve().parents[1];records=[]
prior = {}
bundle_hash = None
if a.bundle:
    bundle_hash = hashlib.sha256(a.bundle.read_bytes()).hexdigest()
    with tarfile.open(a.bundle, 'r:gz') as package:
        payload = {item.name: hashlib.sha256(package.extractfile(item).read()).hexdigest()
                   for item in package.getmembers() if item.isfile()}
        dispatcher = package.extractfile('dispatch.sh').read().decode()
    release_id, = [line.split('"')[1] for line in dispatcher.splitlines()
                   if line.startswith('RP_RELEASE_ID=')]
    if len(release_id) != 64 or any(c not in '0123456789abcdef' for c in release_id):
        raise SystemExit('Invalid modular release identity')
    local_hash = payload['dispatch.sh']
else:
    local_hash = hashlib.sha256((root / 'rp.sh').read_bytes()).hexdigest()
if a.continue_from:
    if a.continue_from.resolve() == out:
        raise SystemExit('Continuation must use a new output directory')
    candidate = json.loads((a.continue_from / 'candidate.json').read_text())
    if candidate['rp_sha256'] != local_hash or candidate.get('bundle_sha256') != bundle_hash:
        raise SystemExit('Prior evidence belongs to a different candidate')
    prior = {row['id']: row for row in json.loads((a.continue_from / 'results.json').read_text())}
def record(name,result,detail,started):
    row=dict(id=name,result=result,detail=detail,started=started,seconds=time.time()-started)
    records.append(row);(out/'results.json').write_text(json.dumps(records,indent=2)+'\n')
    print(json.dumps(row),flush=True)
def remote(host,command,name,timeout=600,allow_skips=False,input_text=None):
    started=time.time()
    try:
        r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',host,command],
                         capture_output=True,text=True,timeout=timeout,input=input_text)
    except subprocess.TimeoutExpired:
        record(name,'UNKNOWN','SSH timeout: remote process may still run',started)
        raise RuntimeError('Inspect remote state before continuing')
    text=r.stdout+r.stderr;(out/(name+'.log')).write_text(text)
    result='PASS' if r.returncode==0 else 'FAIL'
    if allow_skips and r.returncode==0 and ('  - T' in text or '  – T' in text):result='SKIP'
    record(name,result,{'rc':r.returncode,'log':name+'.log'},started)
    return r

def checked_remote(host, command, name, **kwargs):
    if prior.get(name, {}).get('result') == 'PASS':
        record(name, 'PASS', {'reused_evidence': str(a.continue_from),
                             'original': prior[name]}, time.time())
        return None
    return remote(host, command, name, **kwargs)

r=remote(a.lab1,'sha256sum /usr/local/bin/rp','candidate-sha')
if r.returncode or r.stdout.split()[0]!=local_hash:raise SystemExit('Local/deployed candidate differ')
if a.bundle:
    checksums = ''.join(f'{value}  {name}\n' for name, value in sorted(payload.items()))
    if remote(a.lab1, f'cd /usr/local/lib/rp/releases/{release_id} && sha256sum -c --strict -',
              'candidate-module-shas', input_text=checksums).returncode:
        raise SystemExit('Local/deployed modules differ')
if remote(a.client, 'ip netns exec rp-lab-client ip link show wg0', 'client-namespace-preflight').returncode:
    raise SystemExit('Client fixture is absent; no transport mutation performed')
(out/'candidate.json').write_text(json.dumps({'rp_sha256':local_hash, 'bundle_sha256':bundle_hash,
    'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()},indent=2))
for transport in ['reality-xhttp2','reality-xhttp','hy2-wg','hy2o-wg']:
    if remote(a.lab1,'rp tunnel '+transport,transport+'-pin').returncode:
        raise SystemExit('Pin failed; leave state for inspection')
    checked_remote(a.lab1, 'rp restart', transport+'-restart-vps1')
    checked_remote(a.lab2, 'rp restart', transport+'-restart-vps2')
    readiness = '''
for ((i=1; i<=6; i++)); do
  if ip netns exec rp-lab-client curl -4 -fsS --max-time 8 https://1.1.1.1/cdn-cgi/trace -o /dev/null; then
    printf 'attempt=%d rc=0 seconds=%d\\n' "$i" "$SECONDS"; exit 0
  else rc=$?; printf 'attempt=%d rc=%d seconds=%d\\n' "$i" "$rc" "$SECONDS"; fi
  ((i==6)) || sleep 2
done
exit 1
'''
    remote(a.client, shlex.join(['bash', '-c', readiness]), transport+'-restart-client-readiness', timeout=90)
    checked_remote(a.lab1,'rp test --restart',transport+'-T1-T8-restart',allow_skips=True)
    checked_remote(a.lab2,'rp test',transport+'-T1-T3')
    script='''
failed=0
for ((i=1; i<=30; i++)); do
  start=$SECONDS
  if rp _fn t3_check "$1"; then rc=0; else rc=$?; failed=$((failed+1)); fi
  printf 'iteration=%d rc=%d seconds=%d\n' "$i" "$rc" "$((SECONDS-start))"
done
((failed==0))
'''
    checked_remote(a.lab2,shlex.join(['bash','-c',script,'bash',transport]),transport+'-T3-repeat30',timeout=7200)
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
    if transport in ['hy2-wg', 'hy2o-wg']:
        # Use the management address of the authorized lab client as the synthetic
        # source; this probe does not contact a public endpoint.
        client_ip = subprocess.check_output(['ssh', '-T', '-G', a.client], text=True)
        client_ip = next(line.split()[1] for line in client_ip.splitlines() if line.startswith('hostname '))
        name = transport + '-kernel-reset'; started = time.time()
        with (out/(name+'.log')).open('w') as log:
            r = subprocess.run([sys.executable, str(root/'lab/wg_reset_probe.py'),
                '--lab1', a.lab1, '--lab2', a.lab2, '--client-ip', client_ip,
                '--output', str(out/name)], stdout=log, stderr=subprocess.STDOUT, timeout=90)
        result_path = out/name/'results.json'
        if not result_path.exists():
            record(name, 'UNKNOWN', 'Reset fixture failed; inspect log', started)
            raise SystemExit('Reset fixture failure')
        reset = json.loads(result_path.read_text())
        record(name, 'PASS' if r.returncode == 0 and reset['result'] == 'PASS' else 'FAIL', reset, started)
remote(a.lab1,'rp tunnel auto','restore-auto')
