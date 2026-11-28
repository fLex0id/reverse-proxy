#!/usr/bin/env python3
"""Compare VPS-2 restart exit status during a real active-transport start failure."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for name in ['lab2', 'client', 'candidate', 'output']:
    p.add_argument('--'+name, required=True)
a = p.parse_args()
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
token = uuid.uuid4().hex[:10]
directory = '/root/rp-lab/restart2-'+token
timer = 'rp-lab-restart2-restore-'+token


def run(host, command, name, input_text=None):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                       input=input_text, capture_output=True, text=True, timeout=90)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    return r


def checked(host, command, name, input_text=None):
    r = run(host, command, name, input_text)
    if r.returncode:
        raise RuntimeError(name+' failed; inspect its log')
    return r


probe = 'ip netns exec rp-lab-client curl -4 -fsS --max-time 8 https://1.1.1.1/cdn-cgi/trace -o /dev/null'
checked(a.lab2, 'test ! -e /var/lib/rp/transaction/pending && systemctl is-active --quiet rp-watch && rp _func', 'preflight')
checked(a.client, probe, 'client-before')
active = checked(a.lab2, 'cat /var/lib/rp/active', 'active-before').stdout.strip()
service = {'hy2-wg': 'rp-hy2.service', 'hy2o-wg': 'rp-hy2o.service',
           'reality-xhttp': 'rp-xray@xhttp.service',
           'reality-xhttp2': 'rp-xray@xhttp2.service'}[active]
dropin = '/run/systemd/system/'+service+'.d/rp-lab-'+token+'.conf'
checked(a.lab2, shlex.join(['install', '-d', '-m', '700', directory]), 'private-dir')
restore = ('#!/bin/bash\nset -e\nrm -f '+shlex.quote(dropin)+
           '\nsystemctl daemon-reload\n/usr/local/bin/rp restart\nsystemctl start rp-watch\n')
checked(a.lab2, 'umask 077; cat >'+shlex.quote(directory+'/restore.sh'), 'write-restore', restore)
checked(a.lab2, shlex.join(['systemd-run', '--quiet', '--unit='+timer, '--on-active=180',
                          '/bin/bash', directory+'/restore.sh']), 'arm-restore')
summary = dict(active=active)
try:
    checked(a.lab2, 'systemctl stop rp-watch', 'stop-watch')
    checked(a.lab2, shlex.join(['install', '-d', '-m', '755', str(Path(dropin).parent)]), 'dropin-dir')
    checked(a.lab2, 'cat >'+shlex.quote(dropin), 'failing-dropin',
            '[Service]\nExecStart=\nExecStart=/usr/bin/false\nRestart=no\n')
    checked(a.lab2, 'systemctl daemon-reload', 'reload-failing-unit')
    baseline = run(a.lab2, 'rp restart', 'baseline-restart')
    old_state = run(a.lab2, 'systemctl show '+service+' -p ExecMainStatus -p ActiveState', 'baseline-failure')
    candidate = run(a.lab2, shlex.join(['bash', a.candidate, 'restart']), 'candidate-restart')
    new_state = run(a.lab2, 'systemctl show '+service+' -p ExecMainStatus -p ActiveState', 'candidate-failure')
    summary.update(baseline_rc=baseline.returncode, candidate_rc=candidate.returncode,
                   baseline_state=old_state.stdout.strip(), candidate_state=new_state.stdout.strip())
    (out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    real_failure = all('ExecMainStatus=1' in r.stdout and 'ActiveState=failed' in r.stdout
                       for r in [old_state, new_state])
    if not real_failure or candidate.returncode == 0:
        summary['result'] = 'FAIL'
        (out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
        raise RuntimeError('Expected actual start failure/candidate rejection unconfirmed')
finally:
    checked(a.lab2, shlex.join(['bash', directory+'/restore.sh']), 'restore-services')
    healthy = False
    for attempt in range(8):
        functional = run(a.lab2, 'rp _func', 'restored-functional-'+str(attempt))
        client = run(a.client, probe, 'client-after-'+str(attempt))
        if functional.returncode == 0 and client.returncode == 0:
            healthy = True
            break
        time.sleep(2)
    if not healthy:
        raise RuntimeError('Tunnel/client not restored; restoration timer remains armed')
    checked(a.lab2, 'systemctl is-active --quiet rp-watch', 'watch-restored')
    checked(a.lab2, 'systemctl stop '+timer+'.timer', 'disarm-restore')
    checked(a.lab2, shlex.join(['rm', '-rf', directory]), 'remove-private-fixture')
summary['result'] = 'PASS'
(out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary), flush=True)
