#!/usr/bin/env python3
"""Real inactive WG/echo and failing WG service, with independent restoration.

Candidate is an uploaded VPS-1 script, executed without installing it. Never
overlap another network mutation or fault test. Management SSH stays independent.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
for name in ['lab1', 'client', 'candidate', 'output']:
    p.add_argument('--' + name, required=True)
a = p.parse_args()
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
out.chmod(0o700)
rows = []
token = uuid.uuid4().hex[:10]
unit = 'rp-lab-restart-restore-' + token
directory = '/root/rp-lab/restart-' + token
dropin = '/run/systemd/system/wg-quick@wg0.service.d/rp-lab-' + token + '.conf'
units = ['rp-net', 'rp-xray', 'rp-echo', 'wg-quick@wg0']
probe = 'ip netns exec rp-lab-client curl -4 -fsS --max-time 8 https://1.1.1.1/cdn-cgi/trace -o /dev/null'


def run(host, command, name, input_text=None):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
                       input=input_text, capture_output=True, text=True, timeout=90)
    (out/(name+'.log')).write_text(r.stdout+r.stderr)
    rows.append(dict(id=name, rc=r.returncode))
    (out/'operations.json').write_text(json.dumps(rows, indent=2)+'\n')
    return r


def checked(host, command, name, input_text=None):
    r = run(host, command, name, input_text)
    if r.returncode:
        raise RuntimeError(name + ' failed; inspect its log')
    return r


def healthy(label):
    for service in units:
        checked(a.lab1, 'systemctl is-active --quiet '+service, label+'-'+service)
    for attempt in range(8):
        if run(a.client, probe, label+'-client-'+str(attempt)).returncode == 0:
            return
        time.sleep(2)
    raise RuntimeError(label + ': client not restored')


healthy('preflight')
checked(a.lab1, shlex.join(['install', '-d', '-m', '700', directory]), 'private-dir')
restore = ('#!/bin/bash\nset -e\nrm -f '+shlex.quote(dropin)+
           '\nsystemctl daemon-reload\nsystemctl start '+shlex.join(units)+'\n')
checked(a.lab1, 'umask 077; cat >'+shlex.quote(directory+'/restore.sh'), 'write-restore', restore)
checked(a.lab1, shlex.join(['systemd-run', '--quiet', '--unit='+unit, '--on-active=180',
                          '/bin/bash', directory+'/restore.sh']), 'arm-restore')
summary = {}
try:
    checked(a.lab1, 'systemctl stop wg-quick@wg0 rp-echo', 'stop-client-and-probe')
    baseline = run(a.lab1, 'rp restart', 'baseline-restart')
    baseline_states = {service: run(a.lab1, 'systemctl is-active '+service,
                                    'baseline-'+service).stdout.strip()
                       for service in ['wg-quick@wg0', 'rp-echo']}
    baseline_client = run(a.client, probe, 'baseline-client')
    summary.update(baseline_rc=baseline.returncode, baseline_states=baseline_states,
                   baseline_client_rc=baseline_client.returncode)
    checked(a.lab1, shlex.join(['bash', a.candidate, 'restart']), 'candidate-restart')
    healthy('candidate-restored')
    checked(a.lab1, 'systemctl stop wg-quick@wg0', 'stop-before-failing-start')
    checked(a.lab1, shlex.join(['install', '-d', '-m', '755', str(Path(dropin).parent)]), 'dropin-dir')
    checked(a.lab1, 'cat >'+shlex.quote(dropin), 'failing-dropin',
            '[Service]\nExecStart=\nExecStart=/usr/bin/false\n')
    checked(a.lab1, 'systemctl daemon-reload', 'reload-failing-unit')
    failed = run(a.lab1, shlex.join(['bash', a.candidate, 'restart']), 'candidate-failed-restart')
    failure = run(a.lab1, 'systemctl show wg-quick@wg0 -p ActiveState -p ExecMainStatus', 'real-service-failure')
    summary.update(candidate_failed_rc=failed.returncode, failure_state=failure.stdout.strip())
    if failed.returncode == 0 or 'ExecMainStatus=1' not in failure.stdout or 'ActiveState=failed' not in failure.stdout:
        raise RuntimeError('Real service failure or candidate rejection not confirmed')
    summary['result'] = 'PASS'
finally:
    checked(a.lab1, shlex.join(['bash', directory+'/restore.sh']), 'restore-services')
    healthy('final-restored')
    checked(a.lab1, 'systemctl stop '+unit+'.timer', 'disarm-restore')
    checked(a.lab1, shlex.join(['rm', '-rf', directory]), 'remove-private-fixture')
    (out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary), flush=True)
